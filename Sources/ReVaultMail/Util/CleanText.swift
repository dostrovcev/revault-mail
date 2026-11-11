import Foundation
import NaturalLanguage
import SwiftUI

/// Чистое тело письма: ссылки свёрнуты в «домен ↗», трекинг и мусор убран,
/// подвал рассылки (отписка, политика, ©) отделён и прячется под «Show more».
enum CleanText {
    struct Result {
        var body: AttributedString
        var footer: AttributedString?
        var plainBody: String
        /// Текст на иврите или арабском: абзацы выравниваются справа.
        var rtl: Bool = false
    }

    private static let footerMarkers = [
        "unsubscribe", "отписаться", "manage preferences", "manage your preferences", "update your preferences",
        "email preferences", "view in browser", "view this email in", "you are receiving", "you received this",
        "this email was sent", "this message was sent", "no longer wish", "privacy policy", "all rights reserved",
        "©", "(c) 20", "terms of service", "sent from my iphone", "отправлено с iphone", "confidentiality notice",
        "this e-mail and any attachments", "if you no longer want",
    ]

    /// Юридический подвал (дисклеймер о конфиденциальности, защита данных): длинный, поэтому правило
    /// «короткий хвост» его не ловит. Строка, начинающаяся с такого маркера, уводит всё ниже в «Show more».
    private static let legalMarkers = [
        "aviso legal", "protección de datos", "proteccion de datos", "confidentiality notice", "confidential notice",
        "disclaimer", "legal notice", "this email and any", "this e-mail and any", "this message and any",
        "this message is intended", "this email is intended", "this e-mail is intended", "the information contained in this",
        "este mensaje y sus", "este correo y sus", "este correo electrónico", "avís legal", "avis legal",
        "ce message et toutes", "ce courriel", "diese e-mail enthält", "diese nachricht enthält", "questo messaggio",
        "конфиденциальн", "данное сообщение и", "это сообщение и",
    ]

    /// bulk: письмо из рассылки (категории Gmail Promotions/Updates/Social/Forums). Только там подвал
    /// режется по первому служебному слову; в личной переписке под «Show more» уходит лишь короткий хвост.
    static func make(_ raw: String, bulk: Bool = false) -> Result {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // невидимые символы, которыми рассылки набивают прехедер
        for ch in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{00AD}", "\u{034F}", "\u{FEFF}", "\u{2007}"] {
            s = s.replacingOccurrences(of: ch, with: "")
        }
        // «текст ( https://... )» и «<https://...>»: ссылка уезжает в подпись, текст остаётся
        s = s.replacingOccurrences(of: "\\s*\\(\\s*(https?://[^\\s)]+)\\s*\\)", with: " ⟦$1⟧", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(https?://[^>\\s]+)>", with: "⟦$1⟧", options: .regularExpression)
        // «rgpd@secod.com<mailto:rgpd@secod.com>»: адрес уже написан, повтор в скобках убираем
        s = s.replacingOccurrences(of: "([^\\s<]+)<mailto:\\1>", with: "$1", options: [.regularExpression, .caseInsensitive])
        // [image: ...], [cid:...]
        s = s.replacingOccurrences(of: "\\[(image|cid|img)[^\\]]*\\]", with: "", options: [.regularExpression, .caseInsensitive])

        var lines: [String] = []
        var signature: Int?
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            // «-- » это стандартный разделитель подписи: запоминаем, а не выбрасываем
            if t == "--" || t == "—" || t == "–" || t == "__", signature == nil, !lines.isEmpty { signature = lines.count; continue }
            // выбрасываются только декоративные линейки («-----», «=====», «* * *»); эмодзи и «?» остаются
            if t.range(of: "^[\\s\\-_=*~.•·|#+]{3,}$", options: .regularExpression) != nil { continue }
            lines.append(line.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression))
        }
        // подвал: служебная строка после начала письма
        var cut: Int?
        if lines.count > 4 {
            for (i, line) in lines.enumerated() where i >= 3 {
                let low = line.lowercased()
                // «[Cast] AVISO LEGAL: ...», «DISCLAIMER: ...»: маркер в самом начале строки, где бы она ни стояла
                let head = String(low.replacingOccurrences(of: "^[\\s\\[\\]a-z]{0,8}\\]\\s*", with: "", options: .regularExpression).prefix(60))
                if legalMarkers.contains(where: { head.hasPrefix($0) }) { cut = i; break }
                guard footerMarkers.contains(where: { low.contains($0) }) else { continue }
                // в личной переписке «privacy policy» посреди текста это слова человека, а не подвал
                let tailShort = lines.count - i <= 12 && Double(i) >= Double(lines.count) * 0.6
                if bulk || tailShort { cut = i; break }
            }
        }
        if let sig = signature, sig >= 1, sig < lines.count { cut = min(cut ?? sig, sig) }
        let bodyLines = cut.map { Array(lines[..<$0]) } ?? lines
        let footerLines = cut.map { Array(lines[$0...]) } ?? []
        var body = squeeze(bodyLines.joined(separator: "\n"))
        var footer = squeeze(footerLines.joined(separator: "\n"))
        if body.isEmpty {
            // ответ из одного «👍» или «?» не превращается в пустую карточку
            body = footer.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : footer
            if !footer.isEmpty { footer = "" }
        }
        let plain = body.replacingOccurrences(of: "⟦[^⟧]*⟧", with: "", options: .regularExpression)
        return Result(body: linkify(body), footer: footer.isEmpty ? nil : linkify(footer),
                      plainBody: plain, rtl: isRTL(plain))
    }

    /// Направление текста по распознанному языку (иврит, арабский, фарси, урду).
    static func isRTL(_ text: String) -> Bool {
        let sample = String(text.prefix(600))
        guard sample.range(of: "[\\u0590-\\u08FF\\uFB1D-\\uFDFF\\uFE70-\\uFEFF]", options: .regularExpression) != nil else { return false }
        let r = NLLanguageRecognizer()
        r.processString(sample)
        guard let lang = r.dominantLanguage else { return false }
        return Locale.Language(identifier: lang.rawValue).characterDirection == .rightToLeft
    }

    // MARK: Кэш разбора

    private final class Box { let result: Result; init(_ r: Result) { result = r } }
    private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 400; return c }()

    /// Разбор письма считается один раз на ключ (id письма + вариант показа), а не на каждую перерисовку.
    static func cached(_ key: String, _ build: () -> Result) -> Result {
        if let b = cache.object(forKey: key as NSString) { return b.result }
        let r = build()
        cache.setObject(Box(r), forKey: key as NSString)
        return r
    }

    private static func squeeze(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ссылки в виде «домен ↗», голые адреса тоже.
    static func linkify(_ s: String) -> AttributedString {
        var out = AttributedString()
        let ns = s as NSString
        guard let re = try? NSRegularExpression(pattern: "⟦(https?://[^⟧]+)⟧|(https?://[^\\s<>\"⟦]+)") else { return AttributedString(s) }
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            var pre = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let urlString = ns.substring(with: r).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)"))
            // Outlook пишет «www.secod.com<http://www.secod.com/>»: текст ссылки сам становится ссылкой, без второго адреса
            var label: String?
            if m.range(at: 1).location != NSNotFound, let url = URL(string: urlString),
               let word = pre.split(whereSeparator: { $0.isWhitespace }).last.map(String.init), pre.hasSuffix(word),
               Self.sameAddress(word, url) {
                pre.removeLast(word.count)
                label = word
            }
            out += AttributedString(pre)
            if let url = URL(string: urlString) {
                var host = url.host ?? "link"
                if host.hasPrefix("www.") { host.removeFirst(4) }
                var chip = AttributedString((label ?? host) + " ↗")
                chip.link = url
                chip.foregroundColor = Theme.blueText
                out += chip
            }
            last = m.range.location + m.range.length
        }
        out += AttributedString(ns.substring(from: last))
        return out
    }

    /// «www.secod.com», «secod.com/», «rgpd@secod.com» рядом с тем же адресом в скобках: одна и та же ссылка.
    static func sameAddress(_ word: String, _ url: URL) -> Bool {
        func norm(_ x: String) -> String {
            var t = x.lowercased()
            for p in ["https://", "http://", "mailto:", "www."] where t.hasPrefix(p) { t.removeFirst(p.count) }
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        return !word.isEmpty && norm(word) == norm(url.absoluteString)
    }

    /// Рассылка с вёрсткой (таблицы, картинки): её честнее показать как задумано.
    static func isRich(html: String?) -> Bool {
        guard let h = html?.lowercased() else { return false }
        // пиксели трекинга (1x1) не считаются: у живого письма из Gong или HubSpot их по два-три
        let imgs = h.components(separatedBy: "<img").count - 1 - trackingPixels(h)
        let tables = h.components(separatedBy: "<table").count - 1
        return imgs >= 3 || tables >= 4
    }

    /// Регулярка картинки-пикселя: ширина или высота 0-2 px атрибутом или стилем.
    static let pixelPattern = "<img\\b[^>]*(?:\\b(?:width|height)\\s*=\\s*[\"']?[0-2](?:px)?[\"'\\s/>]|(?:width|height)\\s*:\\s*[0-2]px)[^>]*>"

    static func trackingPixels(_ h: String) -> Int {
        (try? NSRegularExpression(pattern: pixelPattern, options: [.caseInsensitive]))?
            .numberOfMatches(in: h, range: NSRange(h.startIndex..., in: h)) ?? 0
    }

    /// Встроенные картинки (cid:) и скриншоты с googleusercontent: в чистом тексте они пропадут молча.
    static func hasEmbeddedImages(html: String?) -> Bool {
        guard let h = html?.lowercased() else { return false }
        return h.range(of: "<img[^>]+src\\s*=\\s*[\"']?(cid:|https?://[^\"' >]*googleusercontent\\.com)", options: .regularExpression) != nil
    }
}
