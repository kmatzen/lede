import Foundation

/// Upcoming events from the user's primary Google Calendar.
/// Reuses the Google account's OAuth token — the consent screen lists
/// `.../auth/calendar.readonly` alongside `gmail.metadata`.
struct GoogleCalendarSource: NotificationSource {
    let account: Account
    let source: Source = .calendar

    var isConfigured: Bool {
        Keychain.get(Keychain.Key.googleRefresh(account.id)) != nil
    }

    func fetch() async throws -> FetchResult {
        guard let token = await GoogleOAuth.validAccessToken(accountID: account.id) else {
            return FetchResult(items: [])
        }

        let now = Date()
        let in24h = now.addingTimeInterval(24 * 3600)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: iso.string(from: now)),
            .init(name: "timeMax", value: iso.string(from: in24h)),
            .init(name: "maxResults", value: "20"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "singleEvents", value: "true"),
            .init(name: "showDeleted", value: "false"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SourceError(source: source,
                message: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
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

        let parsed = try JSONDecoder().decode(ListResp.self, from: data)
        let acct = account
        let items: [RawItem] = (parsed.items ?? []).compactMap { (ev) -> RawItem? in
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
            let snippet = "\(prefix)\(when)"

            let organizer = ev.organizer?.displayName
                ?? ev.organizer?.email
                ?? "Calendar"

            return RawItem(
                id: "gcal:\(ev.id)",
                source: .calendar,
                accountID: acct.id,
                accountLabel: acct.label,
                title: summary,
                sender: organizer,
                snippet: snippet,
                url: ev.htmlLink.flatMap { URL(string: $0) },
                receivedAt: start,
                isUnread: needsResponse
            )
        }
        return FetchResult(items: items)
    }

    private func parseStart(dateTime: String?, date: String?) -> Date? {
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

    private func describeDelta(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins) min" }
        let hours = mins / 60
        let remMins = mins % 60
        return remMins == 0 ? "\(hours)h" : "\(hours)h\(remMins)m"
    }
}
