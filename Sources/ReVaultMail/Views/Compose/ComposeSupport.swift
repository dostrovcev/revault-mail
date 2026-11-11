import AppKit
import SwiftUI

// MARK: Подпись

/// Подпись Gmail в обычном тексте: переносы строк из <br>, <div>, <p> сохраняются, разделитель «-- » ровно один.
enum ComposeSignature {
    /// HTML подписи в текст. Блочный тег начинает новую строку, только если на текущей уже есть текст:
    /// так «Имя<div>+7 ...</div>» даёт две строки, а «<div><br></div>» остаётся пустой строкой.
    static func plain(_ html: String) -> String {
        let soft: Character = "\u{1}"
        var s = html.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        for p in ["<head[\\s\\S]*?</head>", "<style[\\s\\S]*?</style>", "<script[\\s\\S]*?</script>", "<!--[\\s\\S]*?-->"] {
            s = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</?(div|p|tr|table|tbody|li|ul|ol|h[1-6]|blockquote)\\b[^>]*>", with: String(soft),
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</t[dh]>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = HTMLText.decodeEntities(s)
        var out = ""
        for ch in s {
            if ch == soft {
                if let last = out.last, last != "\n" { out.append("\n") }
            } else {
                out.append(ch)
            }
        }
        let lines = out.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Подпись с разделителем: «-- » добавляется, только если подпись не начинается с него сама.
    static func block(_ html: String?) -> String? {
        guard let html else { return nil }
        let p = plain(html)
        guard !p.isEmpty else { return nil }
        var lines = p.components(separatedBy: "\n")
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "--" || first == "\u{2014}" || first == "-- " {
            lines[0] = "-- "
            return lines.joined(separator: "\n")
        }
        return "-- \n" + p
    }

    /// Подпись, попавшая в текст черновика (черновик из Gmail web или с телефона), срезается: её добавит отправка.
    static func strip(_ text: String, signatureHTML: String?) -> String {
        guard let html = signatureHTML else { return text }
        let p = plain(html)
        guard !p.isEmpty else { return text }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sigLines = p.components(separatedBy: "\n").filter { !["--", "-- "].contains($0.trimmingCharacters(in: .whitespaces)) }
        let sig = sigLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sig.isEmpty else { return text }
        let squash: (String) -> String = { $0.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression) }
        // сравниваем без пробелов: подпись могла склеиться в одну строку
        if squash(body).hasSuffix(squash(sig)) {
            var cut = body
            var need = squash(sig).count
            while need > 0, let last = cut.last {
                if !last.isWhitespace { need -= 1 }
                cut.removeLast()
            }
            body = cut.trimmingCharacters(in: .whitespacesAndNewlines)
            for sep in ["--", "\u{2014}"] where body.hasSuffix(sep) {
                body = String(body.dropLast(sep.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return body
        }
        return text
    }
}

// MARK: Цитата

/// Цитата прошлого письма в тексте редактора не живёт: её добавляет отправка (MIMEBuilder, quoteOriginal).
enum ComposeQuote {
    /// Делит текст на то, что написал я, и хвостовую цитату («On ... wrote:» и строки «>»).
    static func split(_ text: String) -> (body: String, quote: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return (text, nil) }
        let b = HTMLText.stripQuoted(plain: t)
        guard b != t, t.hasPrefix(b) else { return (text, nil) }
        let q = String(t.dropFirst(b.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (b, q.isEmpty ? nil : q)
    }

    /// Как цитата будет выглядеть в отправленном письме (то же, что пишет MIMEBuilder).
    static func preview(of m: MailMessage) -> String {
        let header = "\(Fmt.fullDate(m.date)), \(m.from.full):"
        let body = m.readableText.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        return header + "\n" + body
    }
}

/// Свёрнутая цитата под ответом: «•••», по клику показывает, что уйдёт вместе с ответом.
struct QuotedTextToggle: View {
    let quote: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                Text("•••").font(.g(12, .semibold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).frame(height: 16)
                    .background(Capsule().fill(Theme.chip))
            }
            .buttonStyle(.plain)
            .help(open ? "Hide quoted text" : "Show quoted text (it is added below your reply when sent)")
            if open {
                ScrollView {
                    Text(quote).font(.g(12)).foregroundStyle(Theme.faint).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
            }
        }
    }
}

// MARK: Отправка с оформлением

/// Что уходит в письмо из редактора: обычная версия и HTML (если есть оформление).
struct ComposeBody {
    var plain: String
    var html: String?
}

/// Единая точка отправки для редакторов и очереди «Send later».
/// INTEGRATION: когда MailStore.send/sendWithUndo получат параметр bodyHTML, передать сюда body.html.
@MainActor
extension MailStore {
    @discardableResult
    func composeSend(account: String, to: [Person], cc: [Person], bcc: [Person], subject: String, body: ComposeBody,
                     replyTo: MailMessage?, threadID: String?, draftOnly: Bool = false,
                     attachments: [URL] = [], forwardFrom: MailMessage? = nil,
                     from: Person? = nil, draftID: String? = nil) async throws -> String? {
        try await send(account: account, to: to, cc: cc, bcc: bcc, subject: subject, body: body.plain, bodyHTML: body.html,
                       replyTo: replyTo, threadID: threadID, draftOnly: draftOnly, attachments: attachments,
                       forwardFrom: forwardFrom, from: from, draftID: draftID)
    }

    func composeSendWithUndo(account: String, to: [Person], cc: [Person], bcc: [Person], subject: String, body: ComposeBody,
                             replyTo: MailMessage?, threadID: String?,
                             attachments: [URL] = [], forwardFrom: MailMessage? = nil,
                             from: Person? = nil, draftID: String? = nil, minDelay: Double = 0) throws {
        try sendWithUndo(account: account, to: to, cc: cc, bcc: bcc, subject: subject, body: body.plain, bodyHTML: body.html,
                         replyTo: replyTo, threadID: threadID, attachments: attachments,
                         forwardFrom: forwardFrom, from: from, draftID: draftID, delay: max(5, minDelay))
    }
}

// MARK: Мелочи

/// Простой вопрос с полем ввода листом над окном (имя шаблона).
@MainActor
enum ComposePrompt {
    static func ask(title: String, info: String = "", placeholder: String = "", initial: String = "",
                    button: String = "Save", completion: @escaping (String) -> Void) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let done: (NSApplication.ModalResponse) -> Void = { r in
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if r == .alertFirstButtonReturn, !v.isEmpty { completion(v) }
        }
        if let w = NSApp.keyWindow { alert.beginSheetModal(for: w, completionHandler: done) } else { done(alert.runModal()) }
    }
}

/// Раскладка «в строку с переносом»: плашки адресатов и поле ввода.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let rows = arrange(width: width, subviews: subviews)
        let h = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y + (row.height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row { var y: CGFloat; var height: CGFloat; var items: [(index: Int, x: CGFloat, size: CGSize)] }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var cur = Row(y: 0, height: 0, items: [])
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            var size = v.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            // последний (поле ввода) занимает остаток строки
            if i == subviews.count - 1, x + size.width <= width { size.width = max(size.width, width - x) }
            if x > 0, x + size.width > width {
                rows.append(cur)
                cur = Row(y: cur.y + cur.height + lineSpacing, height: 0, items: [])
                x = 0
            }
            cur.items.append((i, x, size))
            cur.height = max(cur.height, size.height)
            x += size.width + spacing
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}
