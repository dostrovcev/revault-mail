import Foundation
import SwiftUI

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ReVaultMailOSS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    static let cacheDir: URL = {
        let dir = support.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard DevTools.writesAllowed else { return }   // демо и снимки не трогают настоящие данные
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension Data {
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let pad = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: pad)
        self.init(base64Encoded: s)
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum HTMLText {
    /// Грубое, но быстрое превращение HTML письма в обычный текст для чат-вида, перевода и агента.
    /// keepLinks: ссылки уходят меткой «текст ⟦url⟧» (CleanText делает из неё кликабельный чип),
    /// а картинки оставляют свой alt. По умолчанию выключено: агенту и переводу ссылки только шумят.
    static func toPlain(_ html: String, keepLinks: Bool = false) -> String {
        var s = html
        let dropBlocks = ["<head[\\s\\S]*?</head>", "<style[\\s\\S]*?</style>", "<script[\\s\\S]*?</script>", "<!--[\\s\\S]*?-->"]
        for p in dropBlocks { s = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
        if keepLinks {
            s = rewriteAnchors(s)
            s = s.replacingOccurrences(of: "<img[^>]*\\salt\\s*=\\s*\"([^\"]{2,120})\"[^>]*>", with: " $1 ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|tr|h[1-6]|li|blockquote|table)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        // ячейки таблицы не склеиваются: «Amount $1,200 Due Oct 30», а не «Amount$1,200Due Oct 30»
        s = s.replacingOccurrences(of: "</t[dh]>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "• ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// <a href="https://...">текст</a> → «текст ⟦https://...⟧»; ссылка-картинка без текста пропадает.
    private static func rewriteAnchors(_ html: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: "<a\\s[^>]*?href\\s*=\\s*[\"'](https?://[^\"']+)[\"'][^>]*>([\\s\\S]*?)</a\\s*>",
            options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let href = decodeEntities(ns.substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespaces)
            let inner = ns.substring(with: m.range(at: 2))
            let text = decodeEntities(inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                // логотип или баннер ссылкой: чип без подписи только мусорит
            } else if text.hasPrefix("http") || (!text.contains(" ") && text.contains(".") && href.contains(text)) {
                out += "⟦\(href)⟧"
            } else {
                // текст ссылки оставляем как был (с переносами внутри), ссылка следом чипом
                out += inner + " ⟦\(href)⟧"
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Цитата

    /// Срезает цитату предыдущих писем, оставляя то, что человек написал сам.
    /// Режется только ХВОСТОВАЯ цитата ответа: пересланное письмо, ответы внутри цитаты и
    /// цитаты-отзывы в рассылках остаются на месте.
    static func stripQuoted(html: String) -> String {
        var best: String.Index?
        // Gmail: div.gmail_quote, но не пересылка (gmail_attr с «Forwarded message»)
        for r in ranges(of: "<div[^>]*class\\s*=\\s*[\"'][^\"']*gmail_quote[^\"']*[\"'][^>]*>", in: html) {
            let window = String(html[r.lowerBound..<(html.index(r.lowerBound, offsetBy: 1200, limitedBy: html.endIndex) ?? html.endIndex)])
            if isForwardMarker(window) || window.range(of: "gmail_forward", options: .caseInsensitive) != nil { continue }
            if tailIsQuote(html, from: r.lowerBound, tag: "div") { best = r.lowerBound; break }
        }
        // Apple Mail и Thunderbird: blockquote type=cite, вместе со строкой «On ... wrote:» над ней
        if best == nil {
            for r in ranges(of: "<blockquote[^>]*type\\s*=\\s*[\"']?cite[^>]*>", in: html) {
                if tailIsQuote(html, from: r.lowerBound, tag: "blockquote") { best = attributionStart(html, before: r.lowerBound) ?? r.lowerBound; break }
            }
        }
        // голый blockquote режем только если над ним стоит атрибуция «... wrote:», иначе это вёрстка письма
        if best == nil {
            for r in ranges(of: "<blockquote[^>]*>", in: html) {
                guard let a = attributionStart(html, before: r.lowerBound) else { continue }
                if tailIsQuote(html, from: r.lowerBound, tag: "blockquote") { best = a; break }
            }
        }
        // Outlook: divRplyFwdMsg / appendonsend, кроме пересылки (Subject: FW: / Fwd:)
        if best == nil {
            for r in ranges(of: "<div[^>]*id\\s*=\\s*[\"']?(divRplyFwdMsg|appendonsend)[^>]*>", in: html) {
                let window = String(html[r.lowerBound..<(html.index(r.lowerBound, offsetBy: 2500, limitedBy: html.endIndex) ?? html.endIndex)])
                let plainWindow = toPlain(window)
                if isForwardMarker(plainWindow)
                    || plainWindow.range(of: "(Subject|Тема|Betreff|Asunto|Objet)\\s*:\\s*(FW|Fwd|WG|RV|TR|ENC|Пересл)", options: [.regularExpression, .caseInsensitive]) != nil {
                    continue
                }
                best = r.lowerBound
                break
            }
        }
        // Outlook без id: блок с серой чертой сверху (border-top:solid #E1E1E1 или #B5C4DF), внутри шапка From/De/Von
        if best == nil {
            for r in ranges(of: "<div[^>]*style\\s*=\\s*[\"'][^\"']*border-top\\s*:\\s*solid\\s*#(E1E1E1|B5C4DF)[^>]*>", in: html) {
                let window = String(html[r.lowerBound..<(html.index(r.lowerBound, offsetBy: 2500, limitedBy: html.endIndex) ?? html.endIndex)])
                let plainWindow = toPlain(window)
                guard plainWindow.range(of: "(From|От|Von|De|Da|Van)\\s?:", options: .regularExpression) != nil else { continue }
                if plainWindow.range(of: "(Subject|Тема|Betreff|Asunto|Objet|Oggetto)\\s*:\\s*(FW|Fwd|WG|RV|TR|ENC|I|Пересл)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                    continue
                }
                // свой текст над шапкой обязателен: письмо из одной пересылки остаётся целиком
                if toPlain(String(html[..<r.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                best = r.lowerBound
                break
            }
        }
        guard let cut = best else { return html }
        return String(html[..<cut])
    }

    private static func ranges(of pattern: String, in s: String) -> [Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s) }
    }

    private static func isForwardMarker(_ s: String) -> Bool {
        let low = s.lowercased()
        return ["forwarded message", "пересылаемое сообщение", "пересланное сообщение", "weitergeleitete nachricht",
                "mensaje reenviado", "message transféré", "begin forwarded message"].contains { low.contains($0) }
    }

    /// После закрытия блока цитаты нет своего текста: значит это хвостовая цитата, а не ответы внутри неё.
    private static func tailIsQuote(_ s: String, from start: String.Index, tag: String) -> Bool {
        guard let end = blockEnd(s, from: start, tag: tag) else { return true }
        let rest = toPlain(String(s[end...]))
        return rest.range(of: "[\\p{L}\\p{N}]", options: .regularExpression) == nil
    }

    /// Конец блока <tag ...> с учётом вложенных таких же тегов.
    private static func blockEnd(_ s: String, from start: String.Index, tag: String) -> String.Index? {
        guard let re = try? NSRegularExpression(pattern: "<(/?)\(tag)\\b[^>]*>", options: [.caseInsensitive]) else { return nil }
        var depth = 0
        for m in re.matches(in: s, range: NSRange(start..., in: s)) {
            guard let r = Range(m.range, in: s), let slash = Range(m.range(at: 1), in: s) else { continue }
            depth += s[slash].isEmpty ? 1 : -1
            if depth == 0 { return r.upperBound }
        }
        return nil
    }

    /// Строка «On ..., X wrote:» прямо над цитатой (в пределах ~800 знаков): режем вместе с ней.
    private static func attributionStart(_ s: String, before idx: String.Index) -> String.Index? {
        let from = s.index(idx, offsetBy: -800, limitedBy: s.startIndex) ?? s.startIndex
        let window = String(s[from..<idx])
        let pattern = "(?:\\b(?:On|Am|El|Le)\\s(?:[^<]|<(?!/?(?:div|p|br|tr|td|table|li|blockquote)\\b)[^>]*>){0,400}?(?:wrote|schrieb|escribió|a écrit)\\s*:|[^<>]{0,200}(?:пишет|написал|написала)\\s*:)(?:\\s|<[^>]*>)*$"
        guard let r = window.range(of: pattern, options: .regularExpression) else { return nil }
        let offset = window.distance(from: window.startIndex, to: r.lowerBound)
        return s.index(from, offsetBy: offset)
    }

    private static let attributionSuffixes = ["wrote:", "schrieb:", "escribió:", "a écrit :", "a écrit:", "пишет:", "написал:", "написала:"]
    private static let attributionPrefixes = ["On ", "Am ", "El ", "Le "]

    /// Обычный текст: срезается только хвостовой блок «> ...» вместе с атрибуцией над ним
    /// (в том числе перенесённой на две строки), и всё ниже «-----Original Message-----».
    /// Пересылка («Forwarded message») цитатой не считается, ответы внутри цитаты остаются.
    static func stripQuoted(plain: String) -> String {
        let lines = plain.components(separatedBy: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        var end = lines.count
        for (i, t) in trimmed.enumerated() {
            if t.hasPrefix("-----Original Message-----") || t.hasPrefix("-----Исходное сообщение-----")
                || t.hasPrefix("-----Ursprüngliche Nachricht-----") {
                end = i; break
            }
            // Outlook: черта, под ней From:/Sent:. Пересылку (Subject: FW:) не трогаем.
            if t.hasPrefix("________________________________") {
                let next = trimmed[(i + 1)..<min(trimmed.count, i + 8)].joined(separator: "\n")
                let isReply = next.range(of: "^(From|От|Von|De):", options: [.regularExpression, .anchored]) != nil
                    || next.contains("\nFrom:") || next.contains("\nОт:")
                let isForward = next.range(of: "(Subject|Тема|Betreff|Asunto|Objet)\\s*:\\s*(FW|Fwd|WG|RV|TR|Пересл)",
                                           options: [.regularExpression, .caseInsensitive]) != nil
                if isReply && !isForward { end = i; break }
            }
        }
        // нецитируемые хвосты: «--- original message ---», «On ... wrote:», шапка From:/Sent:, «Begin forwarded message».
        // Режем, только если выше есть свой текст: письмо, целиком состоящее из пересылки, остаётся как есть.
        if let m = firstReplyMarker(trimmed, upTo: end),
           trimmed[..<m].contains(where: { !$0.isEmpty }) {
            end = m
        }
        // хвостовой блок цитаты: с конца только строки «>» и пустые
        var j = end - 1
        var quoteStart: Int?
        while j >= 0 {
            let t = trimmed[j]
            if t.hasPrefix(">") { quoteStart = j } else if !t.isEmpty { break }
            j -= 1
        }
        if let q = quoteStart {
            end = q
            var k = end - 1
            while k >= 0, trimmed[k].isEmpty { k -= 1 }
            if k >= 0, isAttributionEnd(trimmed[k]) {
                end = k
                // атрибуция Gmail переносится: «On Mon ... John Doe <» и «john@x.com> wrote:»
                if !attributionPrefixes.contains(where: { trimmed[k].hasPrefix($0) }), k > 0,
                   attributionPrefixes.contains(where: { trimmed[k - 1].hasPrefix($0) }) {
                    end = k - 1
                }
            }
        }
        return lines[..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Индекс строки, с которой начинается цитата или пересылка без «>» (первая подходящая выше `upTo`).
    private static func firstReplyMarker(_ t: [String], upTo end: Int) -> Int? {
        let dashed = try? NSRegularExpression(
            pattern: "^[-_=\\s]{2,}(original message|forwarded message|исходное сообщение|ursprüngliche nachricht|пересылаемое сообщение|weitergeleitete nachricht|mensaje original)[-_=\\s:]*$",
            options: [.caseInsensitive])
        for i in 0..<end {
            let line = t[i]
            if line.isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            if dashed?.firstMatch(in: line, range: range) != nil { return i }
            if line.lowercased().hasPrefix("begin forwarded message") { return i }
            // «On Mon, Oct 27, 2026 at 10:38 AM John <j@x.com> wrote:» одной строкой или с переносом
            if attributionPrefixes.contains(where: { line.hasPrefix($0) }), line.count < 300 {
                if isAttributionEnd(line) { return i }
                if i + 1 < end, isAttributionEnd(t[i + 1]), t[i + 1].count < 200 { return i }
            }
            // шапка Outlook без черты: From: / Sent: (или Date:) / To: подряд
            // испанский Outlook пишет «Enviado el:», французский «Envoyé :», поэтому слова до двоеточия гибкие
            if line.range(of: "^\\*?(From|От|Von|De|Da|Van|Od|Från|Fra)\\*?\\s?:", options: .regularExpression) != nil {
                let next = t[(i + 1)..<min(end, i + 6)].joined(separator: "\n")
                if next.range(of: "(^|\\n)\\*?(Sent|Date|Отправлено|Дата|Gesendet|Enviado|Enviado el|Envoyé|Inviato|Data|Verzonden|Wysłano|Skickat|Sendt)\\*?\\s?:", options: .regularExpression) != nil,
                   next.range(of: "(^|\\n)\\*?(To|Кому|An|Para|À|A|Aan|Do|Till|Til)\\*?\\s?:", options: .regularExpression) != nil { return i }
            }
        }
        return nil
    }

    private static func isAttributionEnd(_ t: String) -> Bool {
        attributionSuffixes.contains { t.hasSuffix($0) }
    }

    static func decodeEntities(_ input: String) -> String {
        var s = input
        let map: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
            "&apos;": "'", "&mdash;": "-", "&ndash;": "-", "&laquo;": "«", "&raquo;": "»", "&hellip;": "...",
            "&rsquo;": "'", "&lsquo;": "'", "&rdquo;": "\"", "&ldquo;": "\"", "&zwnj;": "", "&#8203;": "",
        ]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        // числовые сущности
        let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);")
        if let regex {
            let ns = s as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let code = ns.substring(with: m.range(at: 1))
                let value = code.hasPrefix("x") || code.hasPrefix("X")
                    ? UInt32(code.dropFirst(), radix: 16) : UInt32(code, radix: 10)
                if let value, let scalar = Unicode.Scalar(value) { result += String(Character(scalar)) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            s = result
        }
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Обычный текст в HTML с абзацами: пустая строка это новый абзац, перевод строки это <br>.
    static func paragraphs(_ plain: String) -> String {
        plain.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p style=\"margin:0 0 1em 0\">" + escape($0).replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
            .joined(separator: "\n")
    }
}

enum Fmt {
    static func listDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { let t = DateFormatter(); t.dateFormat = "HH:mm"; return t.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }

    static func fullDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d, HH:mm" : "MMM d yyyy, HH:mm"
        return f.string(from: d)
    }

    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}

extension Color {
    static func avatar(for key: String) -> Color {
        let palette: [Color] = [
            Color(hex: 0x5B6CE0), Color(hex: 0xE0795B), Color(hex: 0x3FA37A), Color(hex: 0xA466D6),
            Color(hex: 0xE3A13B), Color(hex: 0x3D9BC7), Color(hex: 0xD45D8C), Color(hex: 0x6E7885),
        ]
        var h: UInt32 = 5381
        for b in key.lowercased().utf8 { h = (h &* 33) &+ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }
}

func initials(_ name: String) -> String {
    let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
    let s = parts.compactMap { $0.first }.map { String($0).uppercased() }.joined()
    return s.isEmpty ? "?" : s
}

/// Журнал ошибок приложения: ~/Library/Application Support/ReVaultMail/app.log (последние ~200 КБ).
enum AppLog {
    private static let url = AppPaths.file("app.log")
    private static let q = DispatchQueue(label: "applog")
    static func write(_ msg: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + msg.replacingOccurrences(of: "\n", with: " ") + "\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 400_000,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(200_000).write(to: url)
            }
        }
    }
}
