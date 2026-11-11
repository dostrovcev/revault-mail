import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// OAuth-клиент Google типа «Desktop app». У настольных приложений client_secret не секрет
/// (Google сам так пишет), поэтому лежит файлом в Application Support. Токены живут в Keychain.
struct GoogleClientConfig: Codable, Equatable {
    var clientID: String
    var clientSecret: String

    static let url = AppPaths.file("google_client.json")

    /// Сначала свой клиент из настроек, иначе встроенный в приложение (Resources/google_client.json).
    static func load() -> GoogleClientConfig? {
        if let own = JSONFile.load(GoogleClientConfig.self, from: url) { return own }
        return bundled
    }

    static let bundled: GoogleClientConfig? = {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("google_client.json")) }
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Resources/google_client.json").standardized)
        for c in candidates {
            if let data = try? Data(contentsOf: c), let cfg = parse(downloaded: data) { return cfg }
        }
        return nil
    }()
    func save() { JSONFile.save(self, to: Self.url) }

    /// Принимает файл client_secret_*.json, который отдаёт Google Cloud Console.
    static func isWebClient(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["web"] != nil
    }

    static func parse(downloaded data: Data) -> GoogleClientConfig? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Нужен клиент типа Desktop app («installed»): у Web-клиента редирект на 127.0.0.1 не разрешён.
        if obj["web"] != nil { return nil }
        let inner = (obj["installed"] as? [String: Any]) ?? obj
        if let id = inner["client_id"] as? String, let secret = inner["client_secret"] as? String {
            return GoogleClientConfig(clientID: id, clientSecret: secret)
        }
        if let id = inner["clientID"] as? String, let secret = inner["clientSecret"] as? String {
            return GoogleClientConfig(clientID: id, clientSecret: secret)
        }
        return nil
    }
}

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    /// Google id_token: им приложение входит в общий хаб обсуждений.
    var idToken: String? = nil
}

/// Где живёт вход в Google. Файл в Application Support с правами 0600: у самоподписанной сборки
/// Связка ключей переспрашивает разрешение после каждого обновления, и без ответа почта молча не грузится.
/// Старые записи из Связки ключей забираются один раз и переезжают в файл.
enum Keychain {
    static let service = "io.revault.mail.oss.google"
    private static let url = AppPaths.file("tokens.json")
    private static let lock = NSLock()

    private static func readAll() -> [String: OAuthTokens] { JSONFile.load([String: OAuthTokens].self, from: url) ?? [:] }

    static func save(_ tokens: OAuthTokens, for account: String) {
        lock.lock(); defer { lock.unlock() }
        var all = readAll()
        all[account] = tokens
        JSONFile.save(all, to: url)
    }

    static func load(for account: String) -> OAuthTokens? {
        lock.lock()
        let hit = readAll()[account]
        lock.unlock()
        if let hit { return hit }
        guard let legacy = legacyLoad(account) else { return nil }
        save(legacy, for: account)
        return legacy
    }

    static func delete(for account: String) {
        lock.lock(); defer { lock.unlock() }
        var all = readAll()
        all[account] = nil
        JSONFile.save(all, to: url)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    private static func legacyLoad(_ account: String) -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }
}

enum OAuthError: LocalizedError {
    case noClient, denied(String), badResponse(String), timeout, cancelled
    /// Google отозвал refresh token (invalid_grant): нужен новый вход, повтор не поможет.
    case invalidGrant(String)
    var errorDescription: String? {
        switch self {
        case .noClient: return "Google OAuth client is not set up. Open Settings → Google."
        case .denied(let s):
            if s == "access_denied" { return "Sign-in was cancelled in Google." }
            return "Google refused the sign-in: \(s)"
        case .badResponse(let s): return "Unexpected response from Google: \(s)"
        case .timeout: return "Sign-in was not completed within 3 minutes. Try again."
        case .cancelled: return "Sign-in cancelled."
        case .invalidGrant(let s): return "Google sign-in expired: \(s)"
        }
    }
}

enum GoogleOAuth {
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        // ответ Yes / Maybe / No на приглашение прямо из письма, без перехода в Google Calendar
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "openid",
    ]

    /// Сколько ждём возврата из браузера. Закрытая вкладка или ошибка Google без редиректа иначе вешают вход навсегда.
    static let signInTimeout: TimeInterval = 180

    /// Полный вход: браузер, редирект на локальный порт, обмен кода на токены. Возвращает email и токены.
    /// Отменяется отменой задачи (кнопка Cancel), сам сдаётся через 3 минуты. loginHint подставляет нужный ящик при повторном входе.
    static func signIn(config: GoogleClientConfig, loginHint: String? = nil) async throws -> (String, OAuthTokens) {
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }
        let port = try await receiver.start()
        try Task.checkCancellation()

        let verifier = Data((0..<48).map { _ in UInt8.random(in: 0...255) }).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = UUID().uuidString
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        if let loginHint, !loginHint.isEmpty { comps.queryItems?.append(.init(name: "login_hint", value: loginHint)) }
        let authURL = comps.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let path = try await receiver.waitForRequest(timeout: signInTimeout)
        try Task.checkCancellation()
        let q = URLComponents(string: "http://x" + path)?.queryItems ?? []
        if let err = q.first(where: { $0.name == "error" })?.value { throw OAuthError.denied(err) }
        guard q.first(where: { $0.name == "state" })?.value == state,
              let code = q.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.badResponse("нет кода авторизации")
        }

        let json = try await tokenRequest([
            "code": code,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw OAuthError.badResponse(String(describing: json))
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let tokens = OAuthTokens(accessToken: access, refreshToken: refresh, expiry: Date().addingTimeInterval(expiresIn - 60),
                                 idToken: json["id_token"] as? String)

        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let profile = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let email = profile["emailAddress"] as? String else {
            throw OAuthError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        return (email.lowercased(), tokens)
    }

    static func refresh(_ tokens: OAuthTokens, config: GoogleClientConfig) async throws -> OAuthTokens {
        let json = try await tokenRequest([
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token",
        ])
        guard let access = json["access_token"] as? String else {
            let code = (json["error"] as? String) ?? ""
            let msg = (json["error_description"] as? String) ?? (code.isEmpty ? "refresh failed" : code)
            // только invalid_grant значит «вход отозван»; остальное (сбой Google, странный ответ) не повод перелогиниваться
            if code == "invalid_grant" { throw OAuthError.invalidGrant(msg) }
            throw OAuthError.denied(msg)
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return OAuthTokens(accessToken: access, refreshToken: (json["refresh_token"] as? String) ?? tokens.refreshToken,
                           expiry: Date().addingTimeInterval(expiresIn - 60), idToken: (json["id_token"] as? String) ?? tokens.idToken)
    }

    private static func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = params.map { k, v in "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 5xx, портал Wi-Fi или не JSON: это сеть, а не отказ во входе
        if code >= 500 || code == 0 { throw URLError(.badServerResponse) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return obj
    }
}

/// Одноразовый HTTP-приёмник на 127.0.0.1 для редиректа OAuth.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var pending: String?
    private var failure: Error?
    private var waiter: CheckedContinuation<String, Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume(returning: self?.listener.port?.rawValue ?? 0) }
                case .failed(let e):
                    if once.fire() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() {
        listener.cancel()
        finish(throwing: OAuthError.cancelled)
    }

    /// Ждёт редирект. Таймаут и отмена задачи будят ожидание сами: continuation не остаётся висеть.
    func waitForRequest(timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                lock.lock()
                if let p = pending { pending = nil; lock.unlock(); c.resume(returning: p); return }
                if let e = failure { lock.unlock(); c.resume(throwing: e); return }
                waiter = c
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(throwing: OAuthError.timeout)
                }
            }
        } onCancel: {
            self.finish(throwing: OAuthError.cancelled)
        }
    }

    /// Разбудить ожидание ошибкой ровно один раз; если ещё никто не ждёт, ошибка дождётся его.
    private func finish(throwing error: Error) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(throwing: error)
        } else {
            if pending == nil, failure == nil { failure = error }
            lock.unlock()
        }
    }

    static let donePage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Re:Vault Mail</title><style>
    body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#FAFAF8;
    font-family:Geist,-apple-system,BlinkMacSystemFont,sans-serif;color:#14282B}
    .card{background:#fff;border:1px solid #E9EAE7;border-radius:12px;padding:36px 44px;text-align:center;max-width:380px}
    .logo{font-weight:600;font-size:22px;letter-spacing:-.02em;margin-bottom:18px}.logo i{font-style:normal;color:#EE5B32}
    .logo span{color:#7C8686}.ok{width:40px;height:40px;border-radius:50%;background:#E8F2EC;color:#2E7A55;
    display:flex;align-items:center;justify-content:center;margin:0 auto 14px;font-size:20px}
    h1{font-size:18px;font-weight:600;margin:0 0 6px}p{margin:0;color:#7C8686;font-size:14px;line-height:1.45}
    </style></head><body><div class="card"><div class="logo">Re<i>:</i>Vault <span>Mail</span></div>
    <div class="ok">✓</div><h1>Почта подключена</h1><p>Вкладку можно закрыть и вернуться в приложение.</p></div>
    <script>setTimeout(function(){window.close()},1500)</script></body></html>
    """

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            let isAuth = path.contains("code=") || path.contains("error=")
            let body = isAuth ? Self.donePage : ""
            let resp = "HTTP/1.1 \(isAuth ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            guard isAuth else { return }
            self.lock.lock()
            if let w = self.waiter { self.waiter = nil; self.lock.unlock(); w.resume(returning: path) }
            else { self.pending = path; self.lock.unlock() }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
