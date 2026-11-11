import AppKit
import Foundation
import WebKit

// Логика чтения письма: исходник, отписка, приглашения, печать, «скачать все».
// Отдельно от вьюх, чтобы её можно было вызвать и из меню, и из карточки.

// MARK: Запросы к Gmail мимо приватных помощников клиента

extension GmailClient {
    /// Токен для своих запросов: свежий из файла входа, иначе обычный вызов клиента сам обновит вход
    /// и запишет его на диск, после чего читаем снова.
    fileprivate func readerToken(force: Bool) async throws -> String {
        if !force, let t = Keychain.load(for: account), t.expiry > Date().addingTimeInterval(30) { return t.accessToken }
        _ = try await historyID()
        guard let t = Keychain.load(for: account) else { throw GmailError.notSignedIn(account) }
        return t.accessToken
    }

    fileprivate func readerGET(_ path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        var forced = false
        while true {
            let token = try await readerToken(force: forced)
            var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me" + path)!
            if !query.isEmpty { comps.queryItems = query }
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 90
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401, !forced { forced = true; continue }
            guard (200..<300).contains(code) else {
                AppLog.write("gmail \(account) reader \(path) -> \(code)")
                throw GmailError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
    }

    /// Исходник письма целиком (RFC 822), как «Show Original» в Gmail.
    func rawSource(id: String) async throws -> String {
        let j = try await readerGET("/messages/\(id)", query: [.init(name: "format", value: "raw")])
        guard let data = Data(base64URL: (j["raw"] as? String) ?? "") else { return "" }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Заголовки отписки: List-Unsubscribe и List-Unsubscribe-Post (RFC 8058, отписка в один клик).
    func unsubscribeHeaders(id: String) async throws -> (list: String?, post: String?) {
        let j = try await readerGET("/messages/\(id)", query: [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "List-Unsubscribe"),
            .init(name: "metadataHeaders", value: "List-Unsubscribe-Post"),
        ])
        let h = Self.headers((j["payload"] as? [String: Any]) ?? [:])
        return (h["list-unsubscribe"], h["list-unsubscribe-post"])
    }
}

// MARK: Отписка

struct UnsubscribeInfo: Hashable {
    var https: URL?
    var mailto: URL?
    /// Отправитель поддерживает отписку POST-запросом без перехода на сайт.
    var oneClick: Bool
    /// Ссылка найдена в тексте письма, а не в заголовке.
    var fromBody: Bool

    var isEmpty: Bool { https == nil && mailto == nil }

    /// Разбор заголовка `<mailto:a@b?subject=x>, <https://...>`.
    static func parse(header: String?, post: String?) -> UnsubscribeInfo? {
        guard let header, !header.isEmpty else { return nil }
        var info = UnsubscribeInfo(https: nil, mailto: nil, oneClick: false, fromBody: false)
        let pattern = try! NSRegularExpression(pattern: "<([^>]+)>")
        let ns = header as NSString
        for m in pattern.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: raw) else { continue }
            switch url.scheme?.lowercased() {
            case "https", "http": if info.https == nil { info.https = url }
            case "mailto": if info.mailto == nil { info.mailto = url }
            default: break
            }
        }
        info.oneClick = info.https != nil && (post ?? "").range(of: "one-click", options: .caseInsensitive) != nil
        return info.isEmpty ? nil : info
    }

    /// Запасной путь без заголовка: ссылка в HTML, у которой в адресе или тексте есть «unsubscribe».
    static func fromHTML(_ html: String?) -> UnsubscribeInfo? {
        guard let html, html.range(of: "unsubscribe|opt[- ]?out|отписаться|abbestellen|désinscri", options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        let words = "unsubscribe|opt[- ]?out|optout|отписаться|отписка|abbestellen|abmelden|désinscri|desuscrib|darse de baja"
        let rx = try! NSRegularExpression(pattern: "<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
                                          options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = HTMLText.decodeEntities(ns.substring(with: m.range(at: 1)))
            let text = ns.substring(with: m.range(at: 2))
            let hit = href.range(of: words, options: [.regularExpression, .caseInsensitive]) != nil
                || text.range(of: words, options: [.regularExpression, .caseInsensitive]) != nil
            guard hit, let url = URL(string: href.trimmingCharacters(in: .whitespaces)) else { continue }
            switch url.scheme?.lowercased() {
            case "https", "http": return UnsubscribeInfo(https: url, mailto: nil, oneClick: false, fromBody: true)
            case "mailto": return UnsubscribeInfo(https: nil, mailto: url, oneClick: false, fromBody: true)
            default: continue
            }
        }
        return nil
    }

    /// Разбор mailto: адрес, тема, текст.
    static func mailtoParts(_ url: URL) -> (to: String, subject: String, body: String) {
        let s = url.absoluteString
        let rest = s.dropFirst("mailto:".count)
        let parts = rest.split(separator: "?", maxSplits: 1).map(String.init)
        let to = (parts.first ?? "").removingPercentEncoding ?? (parts.first ?? "")
        var subject = "unsubscribe", body = "unsubscribe"
        if parts.count > 1, let comps = URLComponents(string: "x:?" + parts[1]) {
            for q in comps.queryItems ?? [] {
                if q.name.lowercased() == "subject", let v = q.value { subject = v }
                if q.name.lowercased() == "body", let v = q.value { body = v }
            }
        }
        return (to, subject, body)
    }

    /// Отписка в один клик по RFC 8058: POST с телом List-Unsubscribe=One-Click.
    static func oneClick(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        req.timeoutInterval = 30
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (200..<400).contains(code)
    }
}

/// Кэш найденного про отписку по письму: заголовок спрашиваем у Gmail один раз.
@MainActor
enum UnsubscribeCache {
    static var info: [String: UnsubscribeInfo?] = [:]
    static var done: Set<String> = []

    /// Письмо похоже на рассылку: только тогда тратим запрос на заголовки.
    static func worthAsking(_ m: MailMessage) -> Bool {
        if m.labelIDs.contains(where: { ["CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"].contains($0) }) { return true }
        return m.html?.range(of: "unsubscribe", options: .caseInsensitive) != nil
    }

    static func load(_ m: MailMessage, account: String, store: MailStore) async -> UnsubscribeInfo? {
        if let hit = info[m.id] { return hit }
        var found: UnsubscribeInfo?
        if worthAsking(m), let h = try? await store.client(account).unsubscribeHeaders(id: m.id) {
            found = UnsubscribeInfo.parse(header: h.list, post: h.post)
        }
        if found == nil { found = UnsubscribeInfo.fromHTML(m.html) }
        info[m.id] = found
        return found
    }
}

// MARK: Приглашения в календарь

struct InviteInfo: Hashable {
    var yes: URL?
    var maybe: URL?
    var no: URL?
    var view: URL?
    var ics: Attachment?

    var canRSVP: Bool { yes != nil || maybe != nil || no != nil }

    /// id события Google: параметр eid в ссылках письма это base64 от «<id события> <адрес гостя>».
    var eventID: String? {
        for url in [yes, maybe, no, view].compactMap({ $0 }) {
            guard let eid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "eid" })?.value
            else { continue }
            var b = eid.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            if let d = Data(base64Encoded: b), let str = String(data: d, encoding: .utf8),
               let id = str.split(separator: " ").first, !id.isEmpty { return String(id) }
        }
        return nil
    }

    /// Приглашение: вложение text/calendar или .ics, либо тема «Invitation:».
    static func of(_ m: MailMessage) -> InviteInfo? {
        let ics = m.attachments.first {
            let t = $0.mimeType.lowercased()
            return t == "text/calendar" || t == "application/ics" || $0.filename.lowercased().hasSuffix(".ics")
        }
        let subj = m.subject.lowercased()
        let bySubject = subj.hasPrefix("invitation:") || subj.hasPrefix("updated invitation:")
        guard ics != nil || bySubject else { return nil }
        var info = InviteInfo(ics: ics)
        // у Google ссылки ответа вида calendar/event?action=RESPOND&eid=..&rst=1 (1 да, 2 нет, 3 может быть)
        for url in links(m.html) {
            guard let host = url.host?.lowercased(), host.hasSuffix("google.com"),
                  url.absoluteString.lowercased().contains("calendar") else { continue }
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let action = q.first { $0.name == "action" }?.value?.uppercased()
            let rst = q.first { $0.name == "rst" }?.value
            if action == "RESPOND" {
                switch rst {
                case "1": if info.yes == nil { info.yes = url }
                case "2": if info.no == nil { info.no = url }
                case "3": if info.maybe == nil { info.maybe = url }
                default: if info.view == nil { info.view = url }
                }
            } else if q.contains(where: { $0.name == "eid" }), info.view == nil {
                info.view = url
            }
        }
        return info
    }

    static func links(_ html: String?) -> [URL] {
        guard let html else { return [] }
        let rx = try! NSRegularExpression(pattern: "href\\s*=\\s*[\"']([^\"']+)[\"']", options: .caseInsensitive)
        let ns = html as NSString
        return rx.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap {
            URL(string: HTMLText.decodeEntities(ns.substring(with: $0.range(at: 1))).trimmingCharacters(in: .whitespaces))
        }
    }
}

// MARK: Скачать все вложения

extension AttachmentFiles {
    /// Все файлы письма в папку ~/Downloads/<тема>, папка открывается в Finder.
    @MainActor
    static func downloadAll(_ files: [Attachment], subject: String, account: String, store: MailStore) async -> URL? {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var name = sanitized(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        if name == "attachment" || name.isEmpty { name = "Attachments" }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        var dir = downloads.appendingPathComponent(name, isDirectory: true)
        var n = 1
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = downloads.appendingPathComponent("\(name) (\(n))", isDirectory: true)
            n += 1
        }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            store.error = error.localizedDescription
            return nil
        }
        var saved = 0
        for a in files {
            guard let src = await file(a, account: account, store: store) else { continue }
            let base = (src.lastPathComponent as NSString).deletingPathExtension
            let ext = src.pathExtension
            var dst = dir.appendingPathComponent(src.lastPathComponent)
            var k = 1
            while FileManager.default.fileExists(atPath: dst.path) {
                dst = dir.appendingPathComponent("\(base) (\(k))" + (ext.isEmpty ? "" : ".\(ext)"))
                k += 1
            }
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil { saved += 1 }
        }
        if saved == 0 { try? FileManager.default.removeItem(at: dir); return nil }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        return dir
    }
}

// MARK: Печать

/// Печать письма: HTML кладётся в невидимое окно с WKWebView (без окна WebKit печатает пустые листы).
@MainActor
final class MessagePrinter: NSObject, WKNavigationDelegate {
    private static var active: [MessagePrinter] = []
    private let web: WKWebView
    private let window: NSWindow
    private let title: String

    private init(title: String) {
        self.title = title
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = MessageWebView.dataStore
        let frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        web = WKWebView(frame: frame, configuration: config)
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        super.init()
        web.navigationDelegate = self
    }

    /// Печать одного или нескольких писем треда.
    static func print(_ messages: [MailMessage], subject: String, account: String, store: MailStore) async {
        guard !messages.isEmpty else { return }
        var parts: [String] = []
        for m in messages {
            var html = m.html
            if let h = html, h.range(of: "cid:", options: .caseInsensitive) != nil {
                let inline = await store.inlineImages(for: m, account: account)
                var out = h
                for (cid, data) in inline {
                    let id = cid.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                    if !id.isEmpty { out = out.replacingOccurrences(of: "cid:" + id, with: data, options: .caseInsensitive) }
                }
                html = out
            }
            parts.append(section(m, html: html))
        }
        let doc = document(subject: subject, sections: parts)
        let p = MessagePrinter(title: subject.isEmpty ? "Email" : subject)
        active.append(p)
        p.web.loadHTMLString(doc, baseURL: nil)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func people(_ list: [Person]) -> String { esc(list.map(\.full).joined(separator: ", ")) }

    private static func section(_ m: MailMessage, html: String?) -> String {
        var rows = "<tr><th>From</th><td>\(esc(m.from.full))</td></tr>"
        if !m.to.isEmpty { rows += "<tr><th>To</th><td>\(people(m.to))</td></tr>" }
        if !m.cc.isEmpty { rows += "<tr><th>Cc</th><td>\(people(m.cc))</td></tr>" }
        rows += "<tr><th>Date</th><td>\(esc(MessageDetailsFormat.long(m.date)))</td></tr>"
        rows += "<tr><th>Subject</th><td>\(esc(m.subject))</td></tr>"
        var body: String
        if let html, !html.isEmpty {
            body = html.replacingOccurrences(of: "<script\\b[^>]*>.*?</script>", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        } else {
            body = "<pre>\(esc(m.readableText))</pre>"
        }
        let files = m.attachments.filter { !$0.inline }
        if !files.isEmpty {
            body += "<p class=\"att\">Attachments: " + esc(files.map(\.filename).joined(separator: ", ")) + "</p>"
        }
        return "<section><table class=\"hdr\">\(rows)</table><div class=\"body\">\(body)</div></section>"
    }

    private static func document(subject: String, sections: [String]) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(MessageWebView.csp)">
        <title>\(esc(subject))</title>
        <style>
        body{font:12px -apple-system,BlinkMacSystemFont,sans-serif;color:#1d1d1f;margin:0}
        h1{font-size:17px;margin:0 0 12px}
        section{margin-bottom:22px;page-break-inside:auto}
        section + section{border-top:1px solid #ccc;padding-top:14px}
        table.hdr{border-collapse:collapse;margin-bottom:10px;font-size:11.5px}
        table.hdr th{text-align:left;color:#666;font-weight:600;padding:1px 10px 1px 0;vertical-align:top}
        table.hdr td{padding:1px 0}
        img{max-width:100%;height:auto}
        pre{white-space:pre-wrap;font:12px -apple-system,sans-serif}
        .att{color:#666;font-size:11px}
        </style></head><body><h1>\(esc(subject))</h1>\(sections.joined())</body></html>
        """
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // картинкам даём немного догрузиться
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.run() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    private func run() {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        let op = web.printOperation(with: info)
        op.jobTitle = title
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.view?.frame = web.bounds
        if let host = NSApp.keyWindow ?? Shortcuts.mainWindow {
            op.runModal(for: host, delegate: self, didRun: #selector(printDone(_:success:contextInfo:)), contextInfo: nil)
        } else {
            op.run()
            finish()
        }
    }

    @objc private func printDone(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finish()
    }

    private func finish() {
        window.close()
        Self.active.removeAll { $0 === self }
    }
}

enum MessageDetailsFormat {
    static func long(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMM d, yyyy 'at' HH:mm"
        return f.string(from: d)
    }
}
