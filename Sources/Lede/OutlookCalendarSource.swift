import Foundation

/// Upcoming events from the user's Outlook calendar via Microsoft Graph.
/// Reuses the Microsoft account's OAuth token — the app registration includes
/// `Calendars.Read` delegated permission alongside `Mail.Read`.
struct OutlookCalendarSource: NotificationSource {
    let account: Account
    let source: Source = .calendar

    var isConfigured: Bool {
        Keychain.get(Keychain.Key.microsoftRefresh(account.id)) != nil
    }

    func fetch() async throws -> FetchResult {
        guard let token = await MicrosoftOAuth.validAccessToken(accountID: account.id) else {
            return FetchResult(items: [])
        }

        let now = Date()
        let in24h = now.addingTimeInterval(24 * 3600)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendarview")!
        comps.queryItems = [
            .init(name: "startDateTime", value: iso.string(from: now)),
            .init(name: "endDateTime", value: iso.string(from: in24h)),
            .init(name: "$select", value: "id,subject,start,end,organizer,webLink,responseStatus,isCancelled"),
            .init(name: "$orderby", value: "start/dateTime"),
            .init(name: "$top", value: "20"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                MicrosoftOAuth.logGraphAuthFailure(endpoint: "/me/calendarview",
                                                   response: http, body: data, accessToken: token)
            }
            throw SourceError(source: source,
                message: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
        }

        struct ListResp: Decodable {
            let value: [Event]
            struct Event: Decodable {
                let id: String
                let subject: String?
                let isCancelled: Bool?
                let webLink: String?
                let start: GraphDateTime?
                let organizer: Organizer?
                let responseStatus: ResponseStatus?
                struct GraphDateTime: Decodable { let dateTime: String; let timeZone: String? }
                struct Organizer: Decodable {
                    let emailAddress: EmailAddress?
                    struct EmailAddress: Decodable { let name: String?; let address: String? }
                }
                struct ResponseStatus: Decodable { let response: String? }
            }
        }

        let decoder = JSONDecoder()
        let parsed = try decoder.decode(ListResp.self, from: data)
        let acct = account

        let items: [RawItem] = parsed.value.compactMap { ev in
            if ev.isCancelled == true { return nil }
            guard let subject = ev.subject, !subject.isEmpty else { return nil }
            guard let startStr = ev.start?.dateTime else { return nil }
            guard let start = parseGraphDate(startStr) else { return nil }

            let needsResponse = ev.responseStatus?.response == "notResponded"
            let timeUntil = start.timeIntervalSinceNow
            let when: String
            if timeUntil < -60 {
                when = "in progress"
            } else if timeUntil < 60 {
                when = "starting now"
            } else {
                when = "in \(describeDelta(timeUntil))"
            }
            let prefix = needsResponse ? "Invite needs response · " : "Event "
            let snippet = "\(prefix)\(when)"

            let organizer = ev.organizer?.emailAddress?.name
                ?? ev.organizer?.emailAddress?.address
                ?? "Calendar"

            return RawItem(
                id: "ocal:\(ev.id)",
                source: .calendar,
                accountID: acct.id,
                accountLabel: acct.label,
                title: subject,
                sender: organizer,
                snippet: snippet,
                url: ev.webLink.flatMap { URL(string: $0) },
                receivedAt: start,
                isUnread: needsResponse
            )
        }
        return FetchResult(items: items)
    }

    private func parseGraphDate(_ s: String) -> Date? {
        // Graph returns e.g. "2026-04-24T17:00:00.0000000" without trailing "Z".
        // Since we set Prefer: outlook.timezone=UTC, it's UTC.
        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoWithFrac.date(from: s) { return d }
        if let d = isoWithFrac.date(from: s + "Z") { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s) ?? iso.date(from: s + "Z")
    }

    private func describeDelta(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins) min" }
        let hours = mins / 60
        let remMins = mins % 60
        return remMins == 0 ? "\(hours)h" : "\(hours)h\(remMins)m"
    }
}
