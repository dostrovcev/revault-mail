import Foundation

struct Account: Codable, Identifiable, Hashable {
    var email: String
    var displayName: String
    var id: String { email }
}

struct MailLabel: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String          // system | user
    var unread: Int = 0
    var total: Int = 0
    var color: String? = nil
}

/// Почтовый ящик в боковой панели. account == nil значит «все аккаунты вместе».
struct Mailbox: Hashable, Codable {
    var account: String?
    var labelID: String
    var title: String

    var key: String { (account ?? "all") + "|" + labelID }

    static func inbox(_ account: String?) -> Mailbox { Mailbox(account: account, labelID: "INBOX", title: "Inbox") }

    static let system: [(id: String, title: String, icon: String)] = [
        ("INBOX", "Inbox", "tray"),
        ("STARRED", "Starred", "star"),
        ("SENT", "Sent", "paperplane"),
        ("DRAFT", "Drafts", "doc"),
        ("ALL", "All mail", "archivebox"),
        ("SPAM", "Spam", "xmark.bin"),
        ("TRASH", "Trash", "trash"),
    ]
}

struct ThreadKey: Hashable, Codable {
    var account: String
    var threadID: String
    var string: String { account + "/" + threadID }
}

struct Person: Codable, Hashable {
    var name: String
    var email: String

    var short: String { name.isEmpty ? email : name }
    var full: String { name.isEmpty ? email : "\(name) <\(email)>" }

    /// Адрес для поля Кому/Копия: имя с запятой или спецсимволом берётся в кавычки,
    /// иначе «Doe, John <j@x.com>» при отправке развалится на два адресата.
    var rfcFull: String {
        if name.isEmpty { return email }
        let special = CharacterSet(charactersIn: ",;<>\"@()[]:\\")
        guard name.rangeOfCharacter(from: special) != nil else { return "\(name) <\(email)>" }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" <\(email)>"
    }

    /// Похож ли адрес на настоящий: есть @, есть что-то до и после.
    var isValidEmail: Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !email.contains(" ")
    }

    /// Адрес для сравнения «это я»: регистр, плюс-хвост, у Gmail точки и googlemail.com.
    static func normalized(_ raw: String) -> String {
        let e = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard let at = e.lastIndex(of: "@") else { return e }
        var local = String(e[..<at])
        var domain = String(e[e.index(after: at)...])
        if let plus = local.firstIndex(of: "+") { local = String(local[..<plus]) }
        if domain == "googlemail.com" { domain = "gmail.com" }
        if domain == "gmail.com" { local = local.replacingOccurrences(of: ".", with: "") }
        return local + "@" + domain
    }

    /// Куски заголовка, разделённые запятой вне кавычек и угловых скобок.
    private static func split(_ header: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var depth = 0
        for ch in header {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\", inQuotes { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle() }
            if !inQuotes, ch == "<" { depth += 1 }
            if !inQuotes, ch == ">" { depth = max(0, depth - 1) }
            if (ch == "," || ch == ";"), !inQuotes, depth == 0 {
                out.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        out.append(current)
        return out
    }

    /// Куски адресов: имя без кавычек с запятой («Doe, John <j@x.com>», так пишет Outlook) склеивается обратно,
    /// кусок без @ перед адресом в угловых скобках считается частью имени. Остальное без @ это мусор.
    private static func entries(_ header: String) -> (good: [String], bad: [String]) {
        var good: [String] = []
        var bad: [String] = []
        var pending = ""
        for seg in split(header) {
            let t = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t.contains("@") {
                if !pending.isEmpty, t.contains("<") {
                    good.append(pending + "," + seg)
                } else {
                    if !pending.isEmpty { bad.append(pending.trimmingCharacters(in: .whitespaces)) }
                    good.append(seg)
                }
                pending = ""
            } else {
                pending = pending.isEmpty ? seg : pending + "," + seg
            }
        }
        if !pending.trimmingCharacters(in: .whitespaces).isEmpty { bad.append(pending.trimmingCharacters(in: .whitespaces)) }
        return (good, bad)
    }

    /// Разбор заголовка вида `"Имя Фамилия" <a@b.c>, другой@d.e`. Записи без @ в итог не попадают.
    static func parseList(_ header: String) -> [Person] {
        entries(header).good.compactMap(parse).filter { $0.email.contains("@") }
    }

    /// Что из введённого руками адресом не является: для понятного отказа до отправки.
    static func invalidEntries(_ header: String) -> [String] {
        let e = entries(header)
        return e.bad + e.good.compactMap(parse).filter { !$0.isValidEmail }.map(\.email)
    }

    static func parse(_ raw: String) -> Person? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
                name = String(name.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return Person(name: name, email: email.lowercased())
        }
        return Person(name: "", email: s.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased())
    }
}

struct ThreadSummary: Codable, Identifiable, Hashable {
    var account: String
    var id: String
    var subject: String
    var snippet: String
    var participants: [Person]
    var lastFrom: Person
    var date: Date
    var messageCount: Int
    var unread: Bool
    var starred: Bool
    var hasAttachments: Bool
    var labelIDs: [String]
    /// Рассылка: List-Unsubscribe, List-Id, Precedence bulk или автоответ.
    var bulk: Bool
    /// Последнее входящее письмо адресовано лично ящику (Кому или Копия).
    var toMe: Bool
    /// Отправитель последнего входящего письма (не я).
    var lastIncoming: Person?
    /// В треде лежит неотправленный черновик (в строку, дату и счётчик он не входит).
    var hasDraft: Bool = false
    /// Время и текст самого свежего черновика: по ним строка стоит в папке Drafts.
    var draftDate: Date? = nil
    var draftSnippet: String? = nil

    var key: ThreadKey { ThreadKey(account: account, threadID: id) }
}

extension ThreadSummary {
    private enum CodingKeys: String, CodingKey {
        case account, id, subject, snippet, participants, lastFrom, date, messageCount, unread, starred,
             hasAttachments, labelIDs, bulk, toMe, lastIncoming, hasDraft, draftDate, draftSnippet
    }

    /// Старые кэши без новых полей грузятся с умолчаниями.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(String.self, forKey: .account)
        id = try c.decode(String.self, forKey: .id)
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        participants = try c.decodeIfPresent([Person].self, forKey: .participants) ?? []
        lastFrom = try c.decodeIfPresent(Person.self, forKey: .lastFrom) ?? Person(name: "", email: "")
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 1
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        hasAttachments = try c.decodeIfPresent(Bool.self, forKey: .hasAttachments) ?? false
        labelIDs = try c.decodeIfPresent([String].self, forKey: .labelIDs) ?? []
        bulk = try c.decodeIfPresent(Bool.self, forKey: .bulk) ?? false
        toMe = try c.decodeIfPresent(Bool.self, forKey: .toMe) ?? false
        lastIncoming = try c.decodeIfPresent(Person.self, forKey: .lastIncoming)
        hasDraft = try c.decodeIfPresent(Bool.self, forKey: .hasDraft) ?? false
        draftDate = try c.decodeIfPresent(Date.self, forKey: .draftDate)
        draftSnippet = try c.decodeIfPresent(String.self, forKey: .draftSnippet)
    }
}

struct Attachment: Codable, Hashable, Identifiable {
    var id: String          // attachmentId
    var messageID: String
    var filename: String
    var mimeType: String
    var size: Int
    /// Content-ID без угловых скобок: на него ссылается HTML письма через cid:.
    var contentID: String? = nil
    /// Картинка внутри текста письма (подпись, скриншот): в список вложений не идёт.
    var inline: Bool = false
}

extension Attachment {
    private enum CodingKeys: String, CodingKey { case id, messageID, filename, mimeType, size, contentID, inline }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        messageID = try c.decode(String.self, forKey: .messageID)
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        contentID = try c.decodeIfPresent(String.self, forKey: .contentID)
        inline = try c.decodeIfPresent(Bool.self, forKey: .inline) ?? false
    }
}

struct MailMessage: Codable, Identifiable, Hashable {
    var id: String
    var threadID: String
    var from: Person
    var to: [Person]
    var cc: [Person]
    var replyTo: [Person]
    var subject: String
    var date: Date
    var messageIDHeader: String
    var references: String
    var snippet: String
    var plain: String?
    var html: String?
    var attachments: [Attachment]
    var labelIDs: [String]
    /// Ссылка отписки из List-Unsubscribe: https, если есть, иначе mailto.
    var listUnsubscribe: String? = nil
    /// Есть заголовок List-Unsubscribe-Post: отписка одним POST-запросом (RFC 8058).
    var listUnsubscribePost: Bool = false

    var unread: Bool { labelIDs.contains("UNREAD") }
    var isDraft: Bool { labelIDs.contains("DRAFT") }

    /// Текст письма для чтения человеком: обычная версия, иначе выжатый HTML.
    var readableText: String {
        if let p = plain, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return p }
        if let h = html { return HTMLText.toPlain(h) }
        return snippet
    }

    /// Только то, что написал отправитель, без цитаты прошлых писем.
    var ownText: String {
        if let h = html, (plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HTMLText.toPlain(HTMLText.stripQuoted(html: h))
        }
        let stripped = HTMLText.stripQuoted(plain: readableText)
        return stripped.isEmpty ? readableText : stripped
    }
}

extension MailMessage {
    private enum CodingKeys: String, CodingKey {
        case id, threadID, from, to, cc, replyTo, subject, date, messageIDHeader, references, snippet, plain, html,
             attachments, labelIDs, listUnsubscribe, listUnsubscribePost
    }

    /// Старые кэши тредов без новых полей грузятся с умолчаниями.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID) ?? ""
        from = try c.decodeIfPresent(Person.self, forKey: .from) ?? Person(name: "", email: "")
        to = try c.decodeIfPresent([Person].self, forKey: .to) ?? []
        cc = try c.decodeIfPresent([Person].self, forKey: .cc) ?? []
        replyTo = try c.decodeIfPresent([Person].self, forKey: .replyTo) ?? []
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
        messageIDHeader = try c.decodeIfPresent(String.self, forKey: .messageIDHeader) ?? ""
        references = try c.decodeIfPresent(String.self, forKey: .references) ?? ""
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        plain = try c.decodeIfPresent(String.self, forKey: .plain)
        html = try c.decodeIfPresent(String.self, forKey: .html)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        labelIDs = try c.decodeIfPresent([String].self, forKey: .labelIDs) ?? []
        listUnsubscribe = try c.decodeIfPresent(String.self, forKey: .listUnsubscribe)
        listUnsubscribePost = try c.decodeIfPresent(Bool.self, forKey: .listUnsubscribePost) ?? false
    }
}

struct ThreadDetail: Codable, Hashable {
    var account: String
    var id: String
    var subject: String
    var messages: [MailMessage]
    var labelIDs: [String]

    var key: ThreadKey { ThreadKey(account: account, threadID: id) }

    /// Письма без черновиков: то, что показывается лентой и сравнивается со счётчиком строки.
    var sentMessages: [MailMessage] { messages.filter { !$0.isDraft } }
    /// Последний неотправленный черновик треда, если есть.
    var latestDraft: MailMessage? { messages.last { $0.isDraft } }
}

/// Недописанный ответ в треде: живёт на диске и в Gmail, переживает переход между тредами и перезапуск.
struct ReplyDraft: Codable, Hashable {
    var mode: String
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var text: String
    var gmailDraftID: String?
    var replyToMessageID: String?
}

/// Адрес отправки из настроек Gmail (Send mail as): основной и псевдонимы.
struct SendAs: Codable, Hashable {
    var email: String
    var displayName: String
    var signature: String
    var isPrimary: Bool
    var isDefault: Bool

    var person: Person { Person(name: displayName, email: email) }
}

// MARK: Локальные правила списка: отложенные, заглушённые, заблокированные

/// Отложенный тред (Snooze). У Gmail API своего отложения нет: тред уходит из входящих
/// с ярлыком «Snoozed», а в срок возвращается таймером приложения.
struct SnoozeEntry: Codable, Hashable, Identifiable {
    var key: ThreadKey
    var until: Date
    var snoozedAt: Date
    /// Строка треда на момент отложения: папка Snoozed показывается без запросов к Gmail.
    var summary: ThreadSummary
    var id: String { key.string }
}

/// Заблокированный отправитель: будущие письма от него сами уходят в корзину.
struct BlockedSender: Codable, Hashable, Identifiable {
    var email: String
    /// Ящик, в котором заблокирован; nil значит во всех.
    var account: String?
    var since: Date
    var id: String { (account ?? "*") + "|" + email }
}

/// Всплывающее окно над списком: метки, перенос, отложение. Ключи заданы заранее (выделение или строка меню).
struct ListPopover: Identifiable {
    enum Kind { case labels, move, snooze }
    let id = UUID()
    var kind: Kind
    var keys: [ThreadKey]
}
