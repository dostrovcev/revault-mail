import Foundation

enum GmailError: LocalizedError {
    case http(Int, String), notSignedIn(String), expired(String), invalidAddress(String), tooLarge(Int)
    var errorDescription: String? {
        switch self {
        case .http(let c, let s): return "Gmail returned \(c): \(s.prefix(300))"
        case .notSignedIn(let a): return "\(a) is not signed in. Click your card at the bottom left and choose Sign in again."
        case .expired(let a): return "Sign-in to \(a) has expired. Click your card at the bottom left and choose Sign in again."
        case .invalidAddress(let s): return "Invalid address: \(s)"
        case .tooLarge(let mb): return "Attachments are \(mb) MB, Gmail accepts up to 25 MB per email."
        }
    }

    /// Ошибка значит «нужен новый вход», а не сбой сети.
    var needsLogin: Bool {
        switch self {
        case .expired, .notSignedIn: return true
        default: return false
        }
    }
}

/// Тонкий клиент Gmail REST API для одного аккаунта. Обновляет access token сам.
actor GmailClient {
    let account: String
    private var tokens: OAuthTokens?
    private let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    private let uploadBase = "https://gmail.googleapis.com/upload/gmail/v1/users/me"

    init(account: String) {
        self.account = account
        self.tokens = Keychain.load(for: account)
        self.myAddresses = [Person.normalized(account)]
    }

    private var refreshTask: Task<OAuthTokens, Error>?
    /// Кэш строк списка по historyId треда: неизменившийся тред не перекачивается. Живёт и на диске,
    /// поэтому запуск стоит один запрос списка, а не сорок запросов строк.
    private var summaryCache: [String: CachedSummary] = [:]
    private var summariesDirty = false
    /// Кэш с диска читается при первом списке, внутри актора, а не при создании клиента на главном потоке.
    private var summariesLoaded = false
    private var summariesSavedAt = Date.distantPast

    struct CachedSummary: Codable { var historyID: String; var summary: ThreadSummary }

    /// Отметка «прочитано» и звезда меняют historyId; после своих действий кэш строки сбрасываем.
    func forget(_ id: String) { summaryCache[id] = nil }
    private var refreshBlockedUntil = Date.distantPast
    private var lastIDTokenAttempt = Date.distantPast
    /// Google отозвал вход (invalid_grant): дальше только новый вход, токен не дёргаем.
    private var revoked = false

    /// Мои адреса этого ящика (основной и псевдонимы Send mail as), нормализованные для сравнения.
    private(set) var myAddresses: Set<String>
    private var sendAsCache: (at: Date, list: [SendAs])?
    private var sendAsTriedAt = Date.distantPast

    /// После повторного входа: перечитать токены из файла, кэши остаются.
    func reloadTokens() {
        tokens = Keychain.load(for: account)
        revoked = false
        refreshBlockedUntil = .distantPast
        lastIDTokenAttempt = .distantPast
    }

    private func mapRefreshError(_ error: Error, _ t: OAuthTokens, force: Bool) throws -> String {
        if let e = error as? OAuthError, case .invalidGrant = e {
            revoked = true
            AppLog.write("refresh \(account): invalid_grant, нужен новый вход")
            throw GmailError.expired(account)
        }
        if error is URLError {
            // нет сети это не истёкший вход: тихо ждём связь
            refreshBlockedUntil = Date().addingTimeInterval(15)
            if !force, t.expiry > Date() { return t.accessToken }
            throw error
        }
        AppLog.write("refresh \(account) failed: \(error.localizedDescription)")
        // прочий отказ Google не повторяем чаще раза в минуту, иначе упрёмся в его лимит
        refreshBlockedUntil = Date().addingTimeInterval(60)
        if !force, t.expiry > Date() { return t.accessToken }
        throw error
    }

    /// Один refresh на всех: параллельные запросы ждут его, а не запускают свои.
    private func accessToken(force: Bool = false) async throws -> String {
        guard let t = tokens else { throw GmailError.notSignedIn(account) }
        if revoked { throw GmailError.expired(account) }
        if !force, t.expiry > Date() { return t.accessToken }
        if let running = refreshTask {
            do { return try await running.value.accessToken } catch { return try mapRefreshError(error, t, force: force) }
        }
        if Date() < refreshBlockedUntil {
            if !force, t.expiry > Date() { return t.accessToken }
            throw URLError(.notConnectedToInternet)
        }
        guard let cfg = GoogleClientConfig.load() else { throw OAuthError.noClient }
        let task = Task { try await GoogleOAuth.refresh(t, config: cfg) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            Keychain.save(fresh, for: account)
            return fresh.accessToken
        } catch {
            return try mapRefreshError(error, t, force: force)
        }
    }

    /// id_token для хаба. Обновляется вместе с access token; без него хаб просто молчит, почту это не трогает.
    func idToken() async throws -> String {
        if let id = tokens?.idToken, let exp = Self.jwtExpiry(id), exp > Date().addingTimeInterval(60) { return id }
        guard Date().timeIntervalSince(lastIDTokenAttempt) > 300 else { throw GmailError.notSignedIn(account) }
        lastIDTokenAttempt = Date()
        _ = try await accessToken(force: true)
        guard let id = tokens?.idToken else { throw GmailError.notSignedIn(account) }
        return id
    }

    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1, let data = Data(base64URL: String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Общий цикл запроса: 401 один раз обновляет токен, лимиты и 5xx повторяются с растущей паузой
    /// и с учётом Retry-After. retry=false для того, что нельзя повторять (отправка письма, создание черновика).
    private func perform(retry: Bool, label: String, _ make: (String) throws -> URLRequest) async throws -> Data {
        var attempt = 0
        var authRetried = false
        while true {
            let req = try make(try await accessToken())
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 {
                if !authRetried {
                    authRetried = true
                    _ = try await accessToken(force: true)
                    continue
                }
                AppLog.write("gmail \(account) \(label) -> 401 after refresh")
                throw GmailError.expired(account)
            }
            let rateLimited = (code == 403 || code == 429) && (String(data: data, encoding: .utf8) ?? "").range(of: "ateLimitExceeded|RATE_LIMIT|quota", options: .regularExpression) != nil
            if retry, attempt < 4, code == 429 || code >= 500 || rateLimited {
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let pause = min(30, retryAfter ?? (pow(2, Double(attempt)) + Double.random(in: 0..<1)))
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(code) else {
                AppLog.write("gmail \(account) \(label) -> \(code)")
                if code == 429 || rateLimited { throw GmailError.http(429, "Too many requests to Gmail, try again in a minute.") }
                throw GmailError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        }
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Any? = nil,
                         retry: Bool = true) async throws -> Data {
        // полный адрес (Calendar API) идёт как есть, остальное это пути Gmail
        var comps = URLComponents(string: path.hasPrefix("https://") ? path : base + path)!
        if !query.isEmpty { comps.queryItems = query }
        let url = comps.url!
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await perform(retry: retry, label: "\(method) \(path)") { token in
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let bodyData {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = bodyData
            }
            return req
        }
    }

    /// Большое письмо (вложения) идёт через upload-эндпоинт: обычный JSON-запрос Gmail режет около 5 МБ.
    private func upload(_ path: String, method: String, metadata: [String: Any], raw: Data, retry: Bool) async throws -> Data {
        let boundary = "rvm-up-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(raw)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var comps = URLComponents(string: uploadBase + path)!
        comps.queryItems = [.init(name: "uploadType", value: "multipart")]
        let url = comps.url!
        return try await perform(retry: retry, label: "upload \(method) \(path)") { token in
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = 300
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            return req
        }
    }

    private static let uploadThreshold = 3_500_000

    private func json(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Any? = nil,
                      retry: Bool = true) async throws -> [String: Any] {
        let data = try await request(path, method: method, query: query, body: body, retry: retry)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Календарь: ответ на приглашение

    enum RSVP: String { case accepted, tentative, declined, needsAction }

    enum CalendarError: LocalizedError {
        case noScope, apiOff, notFound, notInvited
        var errorDescription: String? {
            switch self {
            case .noScope: return "To answer invitations here, sign in to this inbox again and allow Calendar."
            case .apiOff: return "Google Calendar API is off for the app. Opened the invitation in Calendar instead."
            case .notFound: return "This event is not in your calendar. Opened it in Google Calendar."
            case .notInvited: return "You are not on the guest list of this event. Opened it in Google Calendar."
            }
        }
    }

    private static let calendarEvents = "https://www.googleapis.com/calendar/v3/calendars/primary/events/"

    /// Мой ответ на событие: nil, если меня нет среди гостей (я организатор или событие чужое).
    func inviteStatus(eventID: String) async throws -> RSVP? {
        let ev = try await calendarJSON(eventID, method: "GET")
        return (Self.selfAttendee(ev, mine: myAddresses)?["responseStatus"] as? String).flatMap(RSVP.init)
    }

    /// Ответ на приглашение: меняется только мой статус в списке гостей, организатор получает уведомление.
    func respond(eventID: String, status: RSVP) async throws -> RSVP {
        let ev = try await calendarJSON(eventID, method: "GET")
        guard var attendees = ev["attendees"] as? [[String: Any]],
              let i = attendees.firstIndex(where: { Self.isSelf($0, mine: myAddresses) }) else { throw CalendarError.notInvited }
        attendees[i]["responseStatus"] = status.rawValue
        let out = try await calendarJSON(eventID, method: "PATCH", query: [.init(name: "sendUpdates", value: "all")],
                                         body: ["attendees": attendees])
        return (Self.selfAttendee(out, mine: myAddresses)?["responseStatus"] as? String).flatMap(RSVP.init) ?? status
    }

    private func calendarJSON(_ eventID: String, method: String, query: [URLQueryItem] = [], body: Any? = nil) async throws -> [String: Any] {
        let id = eventID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? eventID
        do {
            return try await json(Self.calendarEvents + id, method: method, query: query, body: body, retry: method == "GET")
        } catch GmailError.http(let code, let text) {
            if code == 404 || code == 410 { throw CalendarError.notFound }
            if code == 403, text.range(of: "SCOPE_INSUFFICIENT|insufficient", options: [.regularExpression, .caseInsensitive]) != nil { throw CalendarError.noScope }
            if code == 403, text.range(of: "accessNotConfigured|SERVICE_DISABLED|has not been used", options: .regularExpression) != nil { throw CalendarError.apiOff }
            throw GmailError.http(code, text)
        }
    }

    private static func isSelf(_ a: [String: Any], mine: Set<String>) -> Bool {
        (a["self"] as? Bool) == true || mine.contains(Person.normalized(a["email"] as? String ?? ""))
    }

    private static func selfAttendee(_ ev: [String: Any], mine: Set<String>) -> [String: Any]? {
        (ev["attendees"] as? [[String: Any]])?.first { isSelf($0, mine: mine) }
    }

    // MARK: Send mail as: псевдонимы, имя, подпись

    /// Адреса отправки из настроек Gmail. Кэш на час; при сбое отдаётся прошлый список.
    func sendAs(force: Bool = false) async -> [SendAs] {
        if !force, let c = sendAsCache, Date().timeIntervalSince(c.at) < 3600 { return c.list }
        sendAsTriedAt = Date()
        guard let j = try? await json("/settings/sendAs"),
              let raw = j["sendAs"] as? [[String: Any]] else { return sendAsCache?.list ?? [] }
        let list = raw.compactMap { r -> SendAs? in
            guard let e = r["sendAsEmail"] as? String else { return nil }
            return SendAs(email: e.lowercased(), displayName: (r["displayName"] as? String) ?? "",
                          signature: (r["signature"] as? String) ?? "",
                          isPrimary: (r["isPrimary"] as? Bool) ?? false, isDefault: (r["isDefault"] as? Bool) ?? false)
        }
        sendAsCache = (Date(), list)
        let mine = Set(list.map { Person.normalized($0.email) }).union([Person.normalized(account)])
        if mine != myAddresses {
            myAddresses = mine
            // строки, где псевдоним мог что-то поменять («мне лично», последний входящий), пересчитываются
            summaryCache = summaryCache.filter { _, c in
                c.summary.toMe && !(c.summary.lastIncoming.map { mine.contains(Person.normalized($0.email)) } ?? false)
            }
        }
        return list
    }

    private func isMine(_ email: String) -> Bool { myAddresses.contains(Person.normalized(email)) }

    /// Имя отправителя из настроек Gmail (Send mail as).
    func senderName() async -> String {
        let list = await sendAs()
        let primary = list.first { $0.isPrimary } ?? list.first
        if let n = primary?.displayName, !n.isEmpty { return n }
        // запасной путь: имя из поля «От» последнего отправленного письма
        guard let sent = try? await json("/messages", query: [.init(name: "labelIds", value: "SENT"), .init(name: "maxResults", value: "5")]),
              let ids = (sent["messages"] as? [[String: Any]])?.compactMap({ $0["id"] as? String }) else { return "" }
        for id in ids {
            guard let m = try? await json("/messages/\(id)", query: [.init(name: "format", value: "metadata"), .init(name: "metadataHeaders", value: "From")]),
                  let from = Self.headers(m["payload"] as? [String: Any] ?? [:])["from"].flatMap(Person.parse) else { continue }
            if from.email == account, !from.name.isEmpty { return from.name }
        }
        return ""
    }

    /// Текущий historyId ящика: дешёвая точка отсчёта для проверки изменений.
    func historyID() async throws -> String {
        let j = try await json("/profile")
        return (j["historyId"] as? String) ?? String(describing: j["historyId"] ?? "")
    }

    /// Было ли что-то в ящике после historyId. Один лёгкий запрос вместо перекачки списка.
    func hasChanges(since id: String) async throws -> (Bool, String) {
        let j = try await json("/history", query: [.init(name: "startHistoryId", value: id), .init(name: "maxResults", value: "1")])
        let newID = (j["historyId"] as? String) ?? id
        let changed = !((j["history"] as? [Any]) ?? []).isEmpty || newID != id
        return (changed, newID)
    }

    /// Адреса, которым этот ящик писал (Кому и Копия в отправленных). since: только новее даты.
    func sentRecipients(since: Date?, limit: Int = 300) async -> Set<String> {
        var q = "in:sent"
        if let since {
            let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"
            q += " after:" + f.string(from: since.addingTimeInterval(-86400))
        }
        var ids: [String] = []
        var page: String?
        repeat {
            var items: [URLQueryItem] = [.init(name: "q", value: q), .init(name: "maxResults", value: "200")]
            if let page { items.append(.init(name: "pageToken", value: page)) }
            guard let j = try? await json("/messages", query: items) else { break }
            ids += ((j["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            page = j["nextPageToken"] as? String
        } while page != nil && ids.count < limit
        var out = Set<String>()
        await withTaskGroup(of: [String].self) { group in
            var it = ids.prefix(limit).makeIterator()
            func next() {
                guard let id = it.next() else { return }
                group.addTask {
                    let q: [URLQueryItem] = [.init(name: "format", value: "metadata"),
                                             .init(name: "metadataHeaders", value: "To"), .init(name: "metadataHeaders", value: "Cc")]
                    guard let m = try? await self.json("/messages/\(id)", query: q) else { return [] }
                    let h = Self.headers(m["payload"] as? [String: Any] ?? [:])
                    return Person.parseList((h["to"] ?? "") + "," + (h["cc"] ?? "")).map(\.email)
                }
            }
            for _ in 0..<3 { next() }   // медленно: сбор фоновый, лимит Gmail важнее скорости
            while let r = await group.next() { r.forEach { out.insert($0) }; next() }
        }
        let mine = myAddresses
        return out.filter { !mine.contains(Person.normalized($0)) }
    }

    /// Отправители и адресаты писем, где встречается текст: подсказки в поиске для тех, кого нет в локальной книге.
    func peopleMatching(_ text: String, limit: Int = 12) async -> [Person] {
        let t = text.replacingOccurrences(of: "\"", with: "")
        let q = "{from:\"\(t)\" to:\"\(t)\" cc:\"\(t)\" bcc:\"\(t)\"}"
        let items: [URLQueryItem] = [.init(name: "q", value: q), .init(name: "maxResults", value: String(limit))]
        guard let j = try? await json("/messages", query: items) else { return [] }
        let ids = ((j["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        var out: [Person] = []
        await withTaskGroup(of: [Person].self) { group in
            for id in ids {
                group.addTask {
                    let q: [URLQueryItem] = [.init(name: "format", value: "metadata"),
                                             .init(name: "metadataHeaders", value: "From"), .init(name: "metadataHeaders", value: "To"),
                                             .init(name: "metadataHeaders", value: "Cc"), .init(name: "metadataHeaders", value: "Bcc")]
                    guard let m = try? await self.json("/messages/\(id)", query: q) else { return [] }
                    let h = Self.headers(m["payload"] as? [String: Any] ?? [:])
                    return Person.parseList(["from", "to", "cc", "bcc"].map { h[$0] ?? "" }.joined(separator: ","))
                }
            }
            for await r in group { out += r }
        }
        let mine = myAddresses
        return out.filter { !mine.contains(Person.normalized($0.email)) }
    }

    // MARK: Метки

    func labels() async throws -> [MailLabel] {
        let j = try await json("/labels")
        let raw = (j["labels"] as? [[String: Any]]) ?? []
        var result = raw.compactMap { l -> MailLabel? in
            guard let id = l["id"] as? String, let name = l["name"] as? String else { return nil }
            let color = (l["color"] as? [String: Any])?["backgroundColor"] as? String
            return MailLabel(id: id, name: name, type: (l["type"] as? String) ?? "user", color: color)
        }
        if let inbox = try? await json("/labels/INBOX"), let idx = result.firstIndex(where: { $0.id == "INBOX" }) {
            result[idx].unread = (inbox["threadsUnread"] as? Int) ?? 0
            result[idx].total = (inbox["threadsTotal"] as? Int) ?? 0
        }
        return result
    }

    // MARK: Треды

    func listThreads(labelID: String, query: String, pageToken: String?, max: Int = 40) async throws -> ([ThreadSummary], String?) {
        if !summariesLoaded {
            summariesLoaded = true
            let disk = Self.loadSummaries(account)
            for (k, v) in disk where summaryCache[k] == nil { summaryCache[k] = v }
        }
        // псевдонимы нужны до разбора строк: от них зависит «мне лично»
        if sendAsCache == nil, Date().timeIntervalSince(sendAsTriedAt) > 300 { _ = await sendAs() }
        var q: [URLQueryItem] = [.init(name: "maxResults", value: String(Swift.min(500, Swift.max(1, max))))]
        if labelID != "ALL" { q.append(.init(name: "labelIds", value: labelID)) }
        if !query.isEmpty { q.append(.init(name: "q", value: query)) }
        if labelID == "SPAM" || labelID == "TRASH" { q.append(.init(name: "includeSpamTrash", value: "true")) }
        if let pageToken { q.append(.init(name: "pageToken", value: pageToken)) }
        let j = try await json("/threads", query: q)
        let rows = (j["threads"] as? [[String: Any]]) ?? []
        let ids = rows.compactMap { $0["id"] as? String }
        let next = j["nextPageToken"] as? String

        var out = [String: ThreadSummary]()
        var stale: [String] = []
        for r in rows {
            guard let id = r["id"] as? String else { continue }
            let hid = (r["historyId"] as? String) ?? ""
            if let c = summaryCache[id], c.historyID == hid, !hid.isEmpty { out[id] = c.summary } else { stale.append(id) }
        }
        let historyOf = Dictionary(rows.compactMap { r -> (String, String)? in
            guard let id = r["id"] as? String else { return nil }
            return (id, (r["historyId"] as? String) ?? "")
        }, uniquingKeysWith: { a, _ in a })
        var missing = 0
        var gone = Set<String>()
        var lastError: Error?
        await withTaskGroup(of: (String, Result<ThreadSummary, Error>).self) { group in
            var it = stale.makeIterator()
            func addNext() {
                if let id = it.next() {
                    group.addTask {
                        do { return (id, .success(try await self.threadSummary(id: id))) } catch { return (id, .failure(error)) }
                    }
                }
            }
            for _ in 0..<8 { addNext() }
            while let (id, r) = await group.next() {
                switch r {
                case .success(let s):
                    out[id] = s
                    summaryCache[id] = CachedSummary(historyID: historyOf[id] ?? "", summary: s)
                    summariesDirty = true
                case .failure(let e):
                    if case GmailError.http(404, _) = e {
                        gone.insert(id)   // тред удалили между списком и запросом: просто пропускаем
                    } else if let old = summaryCache[id]?.summary {
                        out[id] = old     // лимит или сбой: старая строка лучше пропавшей, в кэш как свежую не пишем
                    } else {
                        missing += 1
                        lastError = e
                    }
                }
                addNext()
            }
        }
        // строка пропала бы из списка: пусть список целиком останется прежним до следующего опроса
        if missing > 0, let lastError { throw lastError }
        if summaryCache.count > 3000 {
            let keep = Set(ids)
            summaryCache = summaryCache.filter { keep.contains($0.key) }
        }
        saveSummariesIfNeeded()
        return (ids.filter { !gone.contains($0) }.compactMap { out[$0] }, next)
    }

    private static func summariesURL(_ account: String) -> URL {
        let safe = account.replacingOccurrences(of: "[^A-Za-z0-9@._-]", with: "_", options: .regularExpression)
        return AppPaths.cacheDir.appendingPathComponent("summaries2_\(safe).json")  // 2: у строк появилось время черновика
    }

    private static func loadSummaries(_ account: String) -> [String: CachedSummary] {
        JSONFile.load([String: CachedSummary].self, from: summariesURL(account)) ?? [:]
    }

    /// Кэш строк на диск не чаще раза в 30 секунд и не из главного потока.
    private func saveSummariesIfNeeded() {
        guard summariesDirty, Date().timeIntervalSince(summariesSavedAt) > 30 else { return }
        summariesDirty = false
        summariesSavedAt = Date()
        let copy = summaryCache
        let url = Self.summariesURL(account)
        DiskQueue.write { JSONFile.save(copy, to: url) }
    }

    func threadSummary(id: String) async throws -> ThreadSummary {
        let q: [URLQueryItem] = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "To"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "metadataHeaders", value: "Cc"),
            .init(name: "metadataHeaders", value: "List-Unsubscribe"),
            .init(name: "metadataHeaders", value: "List-Id"),
            .init(name: "metadataHeaders", value: "Precedence"),
            .init(name: "metadataHeaders", value: "Auto-Submitted"),
        ]
        let j = try await json("/threads/\(id)", query: q)
        let msgs = (j["messages"] as? [[String: Any]]) ?? []
        var participants: [Person] = []
        var labels = Set<String>()
        var subject = ""
        var lastFrom = Person(name: "", email: "")
        var date = Date.distantPast
        var hasAttach = false
        var bulk = false
        var toMe = false
        var lastIncoming: Person?
        var hasDraft = false
        var snippetSource: [String: Any]?
        var count = 0
        // черновик это не письмо треда: он не двигает дату, не подменяет строку и не делает тред «моей перепиской»
        let real = msgs.filter { !(($0["labelIds"] as? [String]) ?? []).contains("DRAFT") }
        hasDraft = real.count != msgs.count
        // тред из одних черновиков (папка Drafts) показываем как есть
        for m in (real.isEmpty ? msgs : real) {
            ((m["labelIds"] as? [String]) ?? []).forEach { labels.insert($0) }
            count += 1
            let payload = m["payload"] as? [String: Any] ?? [:]
            let headers = Self.headers(payload)
            let prec = (headers["precedence"] ?? "").lowercased()
            let auto = (headers["auto-submitted"] ?? "no").lowercased()
            if headers["list-unsubscribe"] != nil || headers["list-id"] != nil
                || ["bulk", "list", "junk"].contains(prec) || (auto != "no" && !auto.isEmpty) { bulk = true }
            if let f = headers["from"].flatMap(Person.parse), !isMine(f.email) {
                lastIncoming = f
                let rcpt = Person.parseList((headers["to"] ?? "") + "," + (headers["cc"] ?? "")).map(\.email)
                toMe = rcpt.contains { isMine($0) }
            }
            if subject.isEmpty { subject = headers["subject"] ?? "" }
            if let f = headers["from"].flatMap(Person.parse) {
                lastFrom = f
                if !participants.contains(where: { $0.email == f.email }) { participants.append(f) }
            }
            if let ms = Double((m["internalDate"] as? String) ?? "") { date = max(date, Date(timeIntervalSince1970: ms / 1000)) }
            if (payload["mimeType"] as? String)?.hasPrefix("multipart/mixed") == true { hasAttach = true }
            snippetSource = m
        }
        let lastSnippet = HTMLText.decodeEntities((snippetSource?["snippet"] as? String) ?? "")
        // свежий черновик отдельно: в папке Drafts строка показывает его время и его текст
        let drafts = msgs.filter { (($0["labelIds"] as? [String]) ?? []).contains("DRAFT") }
        let newestDraft = drafts.max { (Double(($0["internalDate"] as? String) ?? "") ?? 0) < (Double(($1["internalDate"] as? String) ?? "") ?? 0) }
        let draftDate = (newestDraft?["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        let draftSnippet = (newestDraft?["snippet"] as? String).map(HTMLText.decodeEntities)
        var summary = ThreadSummary(
            account: account, id: id, subject: subject.isEmpty ? "(no subject)" : subject, snippet: lastSnippet,
            participants: participants, lastFrom: lastFrom, date: date, messageCount: count,
            unread: labels.contains("UNREAD"), starred: labels.contains("STARRED"), hasAttachments: hasAttach,
            labelIDs: Array(labels), bulk: bulk, toMe: toMe, lastIncoming: lastIncoming, hasDraft: hasDraft)
        summary.draftDate = draftDate
        summary.draftSnippet = draftSnippet
        return summary
    }

    func thread(id: String) async throws -> ThreadDetail {
        let j = try await json("/threads/\(id)", query: [.init(name: "format", value: "full")])
        let msgs = ((j["messages"] as? [[String: Any]]) ?? []).map(Self.parseMessage)
        var labels = Set<String>()
        msgs.forEach { $0.labelIDs.forEach { labels.insert($0) } }
        return ThreadDetail(account: account, id: id, subject: msgs.first?.subject ?? "(no subject)", messages: msgs, labelIDs: Array(labels))
    }

    func modifyThread(id: String, add: [String] = [], remove: [String] = []) async throws {
        // кэш строки сбрасываем после запроса: иначе параллельный список успеет закэшировать старое состояние
        defer { summaryCache[id] = nil }
        _ = try await request("/threads/\(id)/modify", method: "POST", body: ["addLabelIds": add, "removeLabelIds": remove])
    }

    func trashThread(id: String) async throws {
        defer { summaryCache[id] = nil }
        _ = try await request("/threads/\(id)/trash", method: "POST")
    }

    func untrashThread(id: String) async throws {
        defer { summaryCache[id] = nil }
        _ = try await request("/threads/\(id)/untrash", method: "POST")
    }

    /// Письмо в формате raw: байты RFC 822.
    func rawMessage(messageID: String) async throws -> Data {
        let j = try await json("/messages/\(messageID)", query: [.init(name: "format", value: "raw")])
        guard let raw = j["raw"] as? String, let data = Data(base64URL: raw) else {
            throw GmailError.http(0, "Gmail did not return the original message")
        }
        return data
    }

    // MARK: Пакетные действия и метки

    /// Новая метка пользователя. Возвращает её с id из Gmail.
    func createLabel(name: String) async throws -> MailLabel {
        let j = try await json("/labels", method: "POST",
                               body: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"], retry: false)
        guard let id = j["id"] as? String else { throw GmailError.http(0, "Gmail did not return a label id") }
        return MailLabel(id: id, name: (j["name"] as? String) ?? name, type: "user")
    }

    /// id писем по ярлыку и запросу, постранично, не больше limit.
    func messageIDs(labelID: String?, query: String, limit: Int = 5000) async throws -> [String] {
        var ids: [String] = []
        var page: String?
        repeat {
            var q: [URLQueryItem] = [.init(name: "maxResults", value: "500")]
            if let labelID, labelID != "ALL" { q.append(.init(name: "labelIds", value: labelID)) }
            if !query.isEmpty { q.append(.init(name: "q", value: query)) }
            if labelID == "SPAM" || labelID == "TRASH" { q.append(.init(name: "includeSpamTrash", value: "true")) }
            if let page { q.append(.init(name: "pageToken", value: page)) }
            let j = try await json("/messages", query: q)
            ids += ((j["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            page = j["nextPageToken"] as? String
        } while page != nil && ids.count < limit
        return Array(ids.prefix(limit))
    }

    /// messages.batchModify: до 1000 писем за запрос, поэтому режем на куски.
    func batchModifyMessages(ids: [String], add: [String] = [], remove: [String] = []) async throws {
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(ids.count, i + 1000)])
            _ = try await request("/messages/batchModify", method: "POST",
                                  body: ["ids": chunk, "addLabelIds": add, "removeLabelIds": remove])
            i += 1000
        }
        // строки списка поменялись у неизвестного набора тредов: кэш строк перечитаем
        summaryCache.removeAll()
        summariesDirty = true
    }

    func attachment(messageID: String, id: String) async throws -> Data {
        let j = try await json("/messages/\(messageID)/attachments/\(id)")
        return Data(base64URL: (j["data"] as? String) ?? "") ?? Data()
    }

    /// Отправка. Никогда не повторяется: Gmail может ответить 5xx, уже приняв письмо, и человек получит два.
    /// Возвращает id отправленного письма.
    @discardableResult
    func send(raw: Data, threadID: String?) async throws -> String {
        if let threadID { summaryCache[threadID] = nil }
        if raw.count > Self.uploadThreshold {
            var meta: [String: Any] = [:]
            if let threadID { meta["threadId"] = threadID }
            let data = try await upload("/messages/send", method: "POST", metadata: meta, raw: raw, retry: false)
            return ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String) ?? ""
        }
        var body: [String: Any] = ["raw": raw.base64URL]
        if let threadID { body["threadId"] = threadID }
        let j = try await json("/messages/send", method: "POST", body: body, retry: false)
        return (j["id"] as? String) ?? ""
    }

    /// Черновик: с draftID обновляет тот же черновик (PUT), без него создаёт новый. Возвращает id черновика.
    /// Черновик, удалённый в Gmail руками, создаётся заново.
    func saveDraft(raw: Data, threadID: String?, draftID: String? = nil) async throws -> String {
        if let threadID { summaryCache[threadID] = nil }
        let big = raw.count > Self.uploadThreshold
        var msg: [String: Any] = big ? [:] : ["raw": raw.base64URL]
        if let threadID { msg["threadId"] = threadID }
        if let draftID, !draftID.isEmpty {
            do {
                let data: Data
                if big {
                    data = try await upload("/drafts/\(draftID)", method: "PUT", metadata: ["id": draftID, "message": msg], raw: raw, retry: true)
                } else {
                    data = try await request("/drafts/\(draftID)", method: "PUT", body: ["id": draftID, "message": msg])
                }
                return ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String) ?? draftID
            } catch GmailError.http(let code, _) where code == 404 || code == 400 {
                // черновика больше нет (отправлен или удалён в другом месте): создаём новый
            }
        }
        let data: Data
        if big {
            data = try await upload("/drafts", method: "POST", metadata: ["message": msg], raw: raw, retry: false)
        } else {
            data = try await request("/drafts", method: "POST", body: ["message": msg], retry: false)
        }
        guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw GmailError.http(0, "Gmail did not return a draft id")
        }
        return id
    }

    /// Удалить черновик. Уже удалённый (404) это не ошибка.
    func deleteDraft(id: String) async throws {
        do {
            _ = try await request("/drafts/\(id)", method: "DELETE")
        } catch GmailError.http(404, _) {
        }
    }

    /// id черновика по id его письма: чтобы открыть черновик из треда и дальше обновлять именно его.
    func draftID(forMessage messageID: String) async -> String? {
        var page: String?
        repeat {
            var q: [URLQueryItem] = [.init(name: "maxResults", value: "500")]
            if let page { q.append(.init(name: "pageToken", value: page)) }
            guard let j = try? await json("/drafts", query: q) else { return nil }
            for d in (j["drafts"] as? [[String: Any]]) ?? [] {
                if ((d["message"] as? [String: Any])?["id"] as? String) == messageID { return d["id"] as? String }
            }
            page = j["nextPageToken"] as? String
        } while page != nil
        return nil
    }

    // MARK: Разбор MIME

    static func headers(_ payload: [String: Any]) -> [String: String] {
        var h = [String: String]()
        for item in (payload["headers"] as? [[String: Any]]) ?? [] {
            if let n = item["name"] as? String, let v = item["value"] as? String { h[n.lowercased()] = v }
        }
        return h
    }

    /// Кодировка части по её Content-Type. Без charset остаётся старая цепочка UTF-8, затем CP1251.
    static func decodeText(_ data: Data, contentType: String?) -> String {
        if let ct = contentType,
           let r = ct.range(of: "charset\\s*=\\s*\"?([^\";\\s]+)", options: [.regularExpression, .caseInsensitive]) {
            let name = ct[r].replacingOccurrences(of: "charset\\s*=\\s*\"?", with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
            if let enc = encoding(named: name), let s = String(data: data, encoding: enc) { return s }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? String(decoding: data, as: UTF8.self)
    }

    static func encoding(named raw: String) -> String.Encoding? {
        switch raw {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .utf8
        // как браузеры: Latin-1 на деле почти всегда Windows-1252 (кавычки, евро)
        case "iso-8859-1", "latin1", "latin-1", "iso8859-1": return .windowsCP1252
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(raw as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func parseMessage(_ m: [String: Any]) -> MailMessage {
        let payload = m["payload"] as? [String: Any] ?? [:]
        let h = headers(payload)
        var plain: String?
        var html: String?
        var attachments: [Attachment] = []
        var inlineData: [String: String] = [:]   // cid → data: URL для мелких картинок, пришедших прямо в теле
        let mid = (m["id"] as? String) ?? ""

        func walk(_ part: [String: Any]) {
            let mime = ((part["mimeType"] as? String) ?? "").lowercased()
            let body = part["body"] as? [String: Any] ?? [:]
            let filename = (part["filename"] as? String) ?? ""
            if let parts = part["parts"] as? [[String: Any]] {
                parts.forEach(walk)
                return
            }
            let ph = headers(part)
            let cid = ph["content-id"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")) }.flatMap { $0.isEmpty ? nil : $0 }
            let disposition = (ph["content-disposition"] ?? "").lowercased()
            let isText = mime == "text/plain" || mime == "text/html"
            if let aid = body["attachmentId"] as? String, !filename.isEmpty || cid != nil || !isText {
                let name = filename.isEmpty ? Self.fallbackName(mime: mime, cid: cid) : filename
                attachments.append(Attachment(id: aid, messageID: mid, filename: name, mimeType: mime,
                                              size: (body["size"] as? Int) ?? 0, contentID: cid, inline: false))
                return
            }
            guard let data = (body["data"] as? String).flatMap({ Data(base64URL: $0) }) else { return }
            if !isText || disposition.hasPrefix("attachment") || !filename.isEmpty {
                if let cid, mime.hasPrefix("image/") {
                    inlineData[cid] = "data:\(mime);base64,\(data.base64EncodedString())"
                }
                return
            }
            let text = decodeText(data, contentType: ph["content-type"])
            if mime == "text/plain", plain == nil { plain = text }
            if mime == "text/html", html == nil { html = text }
        }
        walk(payload)

        // картинка внутри текста (на неё ссылается HTML через cid:) не вложение, а часть письма
        if let body = html {
            let lower = body.lowercased()
            for i in attachments.indices {
                if let cid = attachments[i].contentID, lower.contains("cid:" + cid.lowercased()) { attachments[i].inline = true }
            }
            if !inlineData.isEmpty {
                var out = body
                for (cid, url) in inlineData {
                    out = out.replacingOccurrences(of: "cid:" + cid, with: url, options: .caseInsensitive)
                }
                html = out
            }
        }

        let date = Double((m["internalDate"] as? String) ?? "").map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        return MailMessage(
            id: mid, threadID: (m["threadId"] as? String) ?? "",
            from: h["from"].flatMap(Person.parse) ?? Person(name: "", email: ""),
            to: Person.parseList(h["to"] ?? ""), cc: Person.parseList(h["cc"] ?? ""),
            replyTo: Person.parseList(h["reply-to"] ?? ""),
            subject: h["subject"] ?? "", date: date, messageIDHeader: h["message-id"] ?? "",
            references: h["references"] ?? "", snippet: HTMLText.decodeEntities((m["snippet"] as? String) ?? ""),
            plain: plain, html: html, attachments: attachments, labelIDs: (m["labelIds"] as? [String]) ?? [],
            listUnsubscribe: h["list-unsubscribe"].flatMap(unsubscribeLink),
            listUnsubscribePost: h["list-unsubscribe-post"] != nil)
    }

    /// Ссылка из List-Unsubscribe: «<mailto:...>, <https://...>». Берём https (или http), иначе mailto.
    static func unsubscribeLink(_ header: String) -> String? {
        var links: [String] = []
        var rest = Substring(header)
        while let lt = rest.firstIndex(of: "<"), let gt = rest[lt...].firstIndex(of: ">") {
            let v = rest[rest.index(after: lt)..<gt].trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { links.append(v) }
            rest = rest[rest.index(after: gt)...]
        }
        // без угловых скобок (так пишут не все, но бывает) делим по запятой
        if links.isEmpty {
            links = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let web = links.first(where: { $0.lowercased().hasPrefix("https://") }) { return web }
        if let web = links.first(where: { $0.lowercased().hasPrefix("http://") }) { return web }
        return links.first { $0.lowercased().hasPrefix("mailto:") }
    }

    static func fallbackName(mime: String, cid: String?) -> String {
        let ext = mime.split(separator: "/").last.map(String.init) ?? "bin"
        let base = (cid?.split(separator: "@").first).map(String.init) ?? "attachment"
        return base.contains(".") ? base : base + "." + ext
    }
}

extension GmailClient {
    /// Исходник письма целиком (RFC 822), как «Show original» в Gmail.
    func rawSource(messageID: String) async throws -> String {
        let data = try await rawMessage(messageID: messageID)
        return GmailClient.decodeText(data, contentType: nil)
    }
}

/// Последовательная запись на диск вне главного потока: порядок записей сохраняется.
enum DiskQueue {
    private static let queue = DispatchQueue(label: "io.revault.mail.disk", qos: .utility)
    static func write(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}

/// Файл для письма: имя, тип и содержимое.
struct MIMEAttachment: Sendable {
    var filename: String
    var mimeType: String
    var data: Data
    var contentID: String? = nil
    var inline: Bool = false
}

/// Сборка письма RFC 822 для отправки: две версии (текст и HTML с абзацами), ответ в треде,
/// подпись из Gmail, пересылка с оригиналом и вложения (multipart/mixed).
enum MIMEBuilder {
    static func build(from: Person, to: [Person], cc: [Person], bcc: [Person], subject: String, body: String,
                      bodyHTML: String? = nil, inReplyTo: MailMessage?, quoteOriginal: Bool, signatureHTML: String? = nil,
                      attachments: [MIMEAttachment] = [], forwardOf: MailMessage? = nil) -> Data {
        let alt = "rvm-alt-" + UUID().uuidString
        let mix = "rvm-mix-" + UUID().uuidString
        var lines: [String] = []
        lines.append("From: \(encodeAddress(from))")
        if !to.isEmpty { lines.append("To: \(to.map(encodeAddress).joined(separator: ", "))") }
        if !cc.isEmpty { lines.append("Cc: \(cc.map(encodeAddress).joined(separator: ", "))") }
        if !bcc.isEmpty { lines.append("Bcc: \(bcc.map(encodeAddress).joined(separator: ", "))") }
        lines.append("Subject: \(encodeHeader(subject))")
        lines.append("Date: \(rfc2822Date(Date()))")
        let domain = from.email.split(separator: "@").last.map(String.init) ?? "revault-mail"
        lines.append("Message-ID: <\(UUID().uuidString)@\(domain)>")
        if let orig = inReplyTo, !orig.messageIDHeader.isEmpty {
            lines.append("In-Reply-To: \(orig.messageIDHeader)")
            let refs = (orig.references.isEmpty ? "" : orig.references + " ") + orig.messageIDHeader
            lines.append("References: \(refs)")
        }
        lines.append("MIME-Version: 1.0")

        var plain = body
        var html = "<div dir=\"ltr\">\(bodyHTML ?? HTMLText.paragraphs(body))</div>"
        if let sig = signatureHTML?.trimmingCharacters(in: .whitespacesAndNewlines), !sig.isEmpty {
            plain += "\n\n" + (ComposeSignature.block(sig) ?? "")
            html += "<br><div dir=\"ltr\" class=\"gmail_signature\" data-smartmail=\"gmail_signature\">\(sig)</div>"
        }
        if quoteOriginal, let orig = inReplyTo {
            let header = "\(Fmt.fullDate(orig.date)), \(orig.from.full):"
            let quotedPlain = orig.readableText.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            plain += "\n\n\(header)\n\(quotedPlain)"
            let origHTML = orig.html.map { HTMLText.stripQuoted(html: bodyInner($0)) } ?? HTMLText.paragraphs(orig.readableText)
            html += "<br><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">\(HTMLText.escape(header))<br></div>"
                + "<blockquote class=\"gmail_quote\" style=\"margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex\">"
                + origHTML + "</blockquote></div>"
        }
        if let f = forwardOf {
            var head = ["---------- Forwarded message ---------", "From: \(f.from.full)", "Date: \(Fmt.fullDate(f.date))",
                        "Subject: \(f.subject)", "To: \(f.to.map(\.full).joined(separator: ", "))"]
            if !f.cc.isEmpty { head.append("Cc: \(f.cc.map(\.full).joined(separator: ", "))") }
            plain += "\n\n" + head.joined(separator: "\n") + "\n\n" + f.readableText
            let origHTML = f.html.map(bodyInner) ?? HTMLText.paragraphs(f.readableText)
            html += "<br><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">"
                + head.map(HTMLText.escape).joined(separator: "<br>") + "<br></div><br>" + origHTML + "</div>"
        }

        var altLines: [String] = []
        altLines.append("--\(alt)")
        altLines.append("Content-Type: text/plain; charset=UTF-8")
        altLines.append("Content-Transfer-Encoding: base64")
        altLines.append("")
        altLines.append(wrap64(Data(plain.utf8).base64EncodedString()))
        altLines.append("--\(alt)")
        altLines.append("Content-Type: text/html; charset=UTF-8")
        altLines.append("Content-Transfer-Encoding: base64")
        altLines.append("")
        altLines.append(wrap64(Data(html.utf8).base64EncodedString()))
        altLines.append("--\(alt)--")

        if attachments.isEmpty {
            lines.append("Content-Type: multipart/alternative; boundary=\"\(alt)\"")
            lines.append("")
            lines += altLines
        } else {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(mix)\"")
            lines.append("")
            lines.append("--\(mix)")
            lines.append("Content-Type: multipart/alternative; boundary=\"\(alt)\"")
            lines.append("")
            lines += altLines
            for a in attachments {
                let name = a.filename.isEmpty ? "attachment" : a.filename
                lines.append("--\(mix)")
                lines.append("Content-Type: \(a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType); name=\(paramValue(name))")
                lines.append("Content-Disposition: \(a.inline ? "inline" : "attachment"); filename=\(paramValue(name)); filename*=UTF-8''\(pctEncode(name))")
                if let cid = a.contentID, !cid.isEmpty { lines.append("Content-ID: <\(cid)>") }
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("")
                lines.append(wrap64(a.data.base64EncodedString()))
            }
            lines.append("--\(mix)--")
        }
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// Значение параметра name/filename: ASCII в кавычках, иначе encoded-word (его понимают Gmail и Outlook).
    static func paramValue(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if clean.allSatisfy({ $0.isASCII }) {
            return "\"" + clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "\"" + encodeHeader(clean) + "\""
    }

    static func pctEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func bodyInner(_ html: String) -> String {
        guard let start = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]),
              let end = html.range(of: "</body>", options: .caseInsensitive) else { return html }
        return String(html[start.upperBound..<end.lowerBound])
    }

    static func encodeHeader(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII }) { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    /// Имя всегда в кавычках (запятая в «Doe, John» иначе делит адрес надвое), кавычки внутри экранируются.
    static func encodeAddress(_ p: Person) -> String {
        let n = p.name.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return p.email }
        let name: String
        if n.allSatisfy({ $0.isASCII }) {
            name = "\"" + n.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        } else {
            name = encodeHeader(n)
        }
        return "\(name) <\(p.email)>"
    }

    static func wrap64(_ s: String) -> String {
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 76, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[i..<j]))
            i = j
        }
        return out.joined(separator: "\r\n")
    }

    static func rfc2822Date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }
}
