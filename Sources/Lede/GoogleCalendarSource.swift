import Foundation

/// Upcoming events from every Google Calendar the user has selected for
/// display. Reuses the Google account's OAuth token — the consent screen
/// lists `.../auth/calendar.readonly` alongside `gmail.metadata`.
///
/// The previous implementation queried only `calendars/primary/events`,
/// missing shared work calendars, team calendars, and subscribed
/// calendars. Now we enumerate `calendarList.list`, filter to entries
/// the user has actively chosen to display (`selected: true`) or that
/// are the primary calendar, and fan out one events query per calendar
/// in parallel.
struct GoogleCalendarSource: NotificationSource {
    let account: Account
    let source: Source = .calendar

    var isConfigured: Bool {
        Keychain.get(Keychain.Key.googleRefresh(account.id)) != nil
    }

    /// Result of the per-calendar enumeration. `id` is what we pass to
    /// the events endpoint (URL-encoded — calendar ids are typically
    /// emails or `<id>@group.calendar.google.com` and contain `@` etc.).
    /// `summary` is the human-readable label and `primary` controls
    /// whether we tag the snippet with the calendar name (only useful
    /// for secondary / shared calendars).
    struct CalendarEntry: Decodable {
        let id: String
        let summary: String?
        let selected: Bool?
        let primary: Bool?
        let accessRole: String?
    }

    func fetch() async throws -> FetchResult {
        guard let token = await GoogleOAuth.validAccessToken(accountID: account.id) else {
            return FetchResult(items: [])
        }

        let now = Date()
        let in24h = now.addingTimeInterval(24 * 3600)

        let listed = await Self.userCalendars(token: token)
        let chosen = Self.calendarsToQuery(listed)
        Log.info("gcal[\(account.label)]: querying \(chosen.count) calendar(s) (\(listed.count) total in calendarList)")

        let acct = account
        let items: [RawItem] = await withTaskGroup(of: [RawItem].self) { group -> [RawItem] in
            var out: [RawItem] = []
            var next = 0
            let cap = 8
            for c in chosen.prefix(cap) {
                group.addTask {
                    await Self.eventsAsItems(calendar: c, account: acct,
                                             timeMin: now, timeMax: in24h, token: token)
                }
                next += 1
            }
            while let batch = await group.next() {
                if next < chosen.count {
                    let c = chosen[next]
                    group.addTask {
                        await Self.eventsAsItems(calendar: c, account: acct,
                                                 timeMin: now, timeMax: in24h, token: token)
                    }
                    next += 1
                }
                out.append(contentsOf: batch)
            }
            return out
        }

        // Merge: an event invited to a shared calendar can appear under
        // both that calendar and the user's primary; dedupe by event id.
        var seen = Set<String>()
        let unique = items.filter { item in
            // RawItem.id is `gcal:<calID>:<eventID>` — extract eventID
            // for the dedupe key.
            let eventID = item.id.split(separator: ":").last.map(String.init) ?? item.id
            return seen.insert(eventID).inserted
        }
        return FetchResult(items: unique)
    }

    /// Choose which calendars to fetch events from. Always include the
    /// primary calendar (`primary: true`) — even when the user hasn't
    /// flagged it `selected` it's still the canonical place for invites.
    /// Beyond that we trust the user's Google Calendar UI selection:
    /// `selected: true` means "I actively chose to see this calendar".
    /// Falls back to a single "primary" entry when the calendarList
    /// lookup returned empty (auth scope problem, network blip, etc.)
    /// so we never regress to "no calendars at all".
    static func calendarsToQuery(_ listed: [CalendarEntry]) -> [CalendarEntry] {
        let chosen = listed.filter { c in
            // `selected` defaults to true on primary even when the
            // server omits it; covering both forms.
            return c.primary == true || c.selected == true
        }
        if !chosen.isEmpty { return chosen }
        return [CalendarEntry(id: "primary", summary: nil, selected: true, primary: true, accessRole: "owner")]
    }

    /// Paginated enumeration of every calendar in the user's
    /// calendarList. `minAccessRole=reader` excludes free/busy-only
    /// calendars where event details aren't readable anyway. Returns
    /// an empty array on any failure — the caller falls back to
    /// "primary" so we never regress to silence.
    private static func userCalendars(token: String) async -> [CalendarEntry] {
        var all: [CalendarEntry] = []
        var pageToken: String? = nil
        repeat {
            var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
            var items: [URLQueryItem] = [
                .init(name: "minAccessRole", value: "reader"),
                .init(name: "maxResults", value: "100"),
            ]
            if let t = pageToken { items.append(.init(name: "pageToken", value: t)) }
            comps.queryItems = items

            guard let url = comps.url else { return all }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                Log.warn("gcal: calendarList lookup failed; falling back to primary calendar only")
                return all
            }
            struct Resp: Decodable {
                let items: [CalendarEntry]?
                let nextPageToken: String?
            }
            guard let parsed = try? JSONDecoder().decode(Resp.self, from: data) else { return all }
            all.append(contentsOf: parsed.items ?? [])
            let next = parsed.nextPageToken ?? ""
            pageToken = next.isEmpty ? nil : next
        } while pageToken != nil && all.count < 200
        return all
    }

    private static func eventsAsItems(calendar: CalendarEntry,
                                       account: Account,
                                       timeMin: Date, timeMax: Date,
                                       token: String) async -> [RawItem] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        // Calendar IDs are typically emails or
        // `<id>@group.calendar.google.com`; URL-encode the path component
        // so the `@` and `.` don't break the request.
        let encodedID = calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendar.id
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedID)/events")
        comps?.queryItems = [
            .init(name: "timeMin", value: iso.string(from: timeMin)),
            .init(name: "timeMax", value: iso.string(from: timeMax)),
            .init(name: "maxResults", value: "20"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "singleEvents", value: "true"),
            .init(name: "showDeleted", value: "false"),
        ]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            Log.warn("gcal[\(account.label)]: events lookup failed for calendar \(calendar.id)")
            return []
        }

        struct ListResp: Decodable {
            let items: [Event]?
            struct Event: Decodable {
                let id: String
                let summary: String?
                let status: String?
                let htmlLink: String?
                let start: Time?
                let organizer: Person?
                let attendees: [Attendee]?
                struct Time: Decodable { let dateTime: String?; let date: String? }
                struct Person: Decodable { let email: String?; let displayName: String? }
                struct Attendee: Decodable {
                    let email: String?
                    let displayName: String?
                    let responseStatus: String?
                    let isSelf: Bool?
                    enum CodingKeys: String, CodingKey {
                        case email, displayName, responseStatus, isSelf = "self"
                    }
                }
            }
        }
        guard let parsed = try? JSONDecoder().decode(ListResp.self, from: data) else {
            return []
        }
        let calLabel: String? = (calendar.primary == true) ? nil : calendar.summary?.nilIfEmptyTrimmed

        return (parsed.items ?? []).compactMap { ev -> RawItem? in
            guard ev.status != "cancelled" else { return nil }
            guard let summary = ev.summary, !summary.isEmpty else { return nil }
            guard let start = parseStart(dateTime: ev.start?.dateTime, date: ev.start?.date) else { return nil }

            let me = ev.attendees?.first(where: { $0.isSelf == true })
            let needsResponse = me?.responseStatus == "needsAction"

            let timeUntil = start.timeIntervalSinceNow
            let when: String
            if timeUntil < -60 {
                when = "in progress (started \(describeDelta(-timeUntil)) ago)"
            } else if timeUntil < 60 {
                when = "starting now"
            } else {
                when = "in \(describeDelta(timeUntil))"
            }
            let prefix = needsResponse ? "Invite needs response · " : "Event "
            // Tag non-primary events with their calendar so a row
            // arriving from "Team Standup" doesn't look like it came
            // from the user's personal feed.
            let snippet = calLabel.map { "\(prefix)\(when) · \($0)" } ?? "\(prefix)\(when)"

            let organizer = ev.organizer?.displayName
                ?? ev.organizer?.email
                ?? calLabel
                ?? "Calendar"

            return RawItem(
                id: "gcal:\(calendar.id):\(ev.id)",
                source: .calendar,
                accountID: account.id,
                accountLabel: account.label,
                title: summary,
                sender: organizer,
                snippet: snippet,
                url: ev.htmlLink.flatMap { URL(string: $0) },
                receivedAt: start,
                isUnread: needsResponse
            )
        }
    }

    private static func parseStart(dateTime: String?, date: String?) -> Date? {
        if let dt = dateTime {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: dt) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: dt)
        }
        if let d = date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone.current
            return f.date(from: d)
        }
        return nil
    }

    private static func describeDelta(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins) min" }
        let hours = mins / 60
        let remMins = mins % 60
        return remMins == 0 ? "\(hours)h" : "\(hours)h\(remMins)m"
    }
}

private extension String {
    var nilIfEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
