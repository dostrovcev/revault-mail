import Foundation
import Observation

/// «Важное»: письма лично мне или по работе.
/// Порядок: моё ручное решение по отправителю, бесплатные правила, и только для спорных Jev на сервере.
@Observable
@MainActor
final class Importance {
    struct Verdict: Codable, Hashable { var important: Bool; var reason: String }

    private(set) var contacts: Set<String> = [] {
        didSet { contactDomains = Set(contacts.compactMap { $0.split(separator: "@").last.map(String.init) }); invalidate() }
    }
    private var contactDomains: Set<String> = []
    private(set) var overrides: [String: Bool] = [:] { didSet { invalidate() } }    // отправитель → всегда / никогда
    /// Ключ треда плюс число писем → вероятность «важно». Новое письмо в треде даёт новый ключ,
    /// и Jev смотрит тред заново: ранний «холодный» ответ не прячет живое продолжение.
    private(set) var jev: [String: Double] = [:] { didSet { invalidate() } }
    @ObservationIgnored private var jevOrder: [String] = []
    private var inFlight: Set<String> = []
    /// Решения по строкам, чтобы список и счётчик не гоняли регулярки на каждом кадре.
    @ObservationIgnored private var verdictCache: [ThreadSummary: Verdict?] = [:]
    @ObservationIgnored private var lastReport = Date.distantPast
    weak var hub: HubStore?

    private static let contactsURL = AppPaths.file("contacts.json")
    private static let overridesURL = AppPaths.file("importance_overrides.json")
    private static let jevURL = AppPaths.cacheDir.appendingPathComponent("jev2.json")
    private static let reportURL = AppPaths.file("importance_report.txt")

    struct ContactsFile: Codable { var emails: [String]; var updated: [String: Date] }
    struct JevFile: Codable { var scores: [String: Double]; var order: [String] }

    /// Ключ Jev: тред и число писем в нём.
    static func jevKey(_ t: ThreadSummary) -> String { t.key.string + "|" + String(t.messageCount) }

    /// Сбросить кэш решений: поменялись контакты, ручные отметки, ответы Jev или мои адреса.
    func invalidate() {
        verdictCache.removeAll(keepingCapacity: true)
        version &+= 1
    }
    /// Наблюдаемая метка версии правил: экран, взявший решение из кэша, всё равно перерисуется при их смене.
    private(set) var version = 0
    private var contactsUpdated: [String: Date] = [:]

    init() {
        if let c = JSONFile.load(ContactsFile.self, from: Self.contactsURL) {
            contacts = Set(c.emails); contactsUpdated = c.updated
            contactDomains = Set(contacts.compactMap { $0.split(separator: "@").last.map(String.init) })
        }
        overrides = JSONFile.load([String: Bool].self, from: Self.overridesURL) ?? [:]
        if let j = JSONFile.load(JevFile.self, from: Self.jevURL) {
            jev = j.scores
            jevOrder = j.order.filter { j.scores[$0] != nil }
        }
    }

    // MARK: Правила

    private static let money = try! NSRegularExpression(pattern:
        "(invoice|payment (received|failed|due)|you (got|received) (a )?payment|paid you|contract|docusign|pandadoc|signature request|transferencia|impuesto|factura|recibo|pago|оплат|сч[её]т на|договор|подпис)",
        options: .caseInsensitive)
    private static let personal = try! NSRegularExpression(pattern:
        "(messaged you|sent you a message|new message from|replied to (you|your)|mentioned you|написал(а)? вам|новое сообщение|invitation:|accepted:|declined:|tentatively accepted|updated invitation|приглашение:|cita confirmada|appointment confirmed)",
        options: .caseInsensitive)
    private static let booking = try! NSRegularExpression(pattern:
        "(confirmed|new event|between|rescheduled|cancel)", options: .caseInsensitive)
    private static let robot = try! NSRegularExpression(pattern:
        "^(no-?reply|do-?not-?reply|notifications?|notify|alerts?|mailer|news(letter)?|marketing|promo|updates?|digest|info|hello|team|support|billing|receipts?|account|accounts|security|feedback|survey|calendar-notification|bounce|postmaster)([._+-]|$)",
        options: .caseInsensitive)

    private func match(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// nil значит «спорное»: решает Jev.
    func verdict(_ t: ThreadSummary, isMe: (String) -> Bool) -> Verdict? {
        let sender = t.lastIncoming ?? t.lastFrom
        let email = sender.email.lowercased()
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        if let o = overrides[email] { return Verdict(important: o, reason: o ? "ты отметил отправителя" : "ты убрал отправителя") }
        if let o = overrides["@" + domain] { return Verdict(important: o, reason: "ты отметил домен") }
        if t.starred { return Verdict(important: true, reason: "звезда") }
        if t.lastIncoming == nil || isMe(t.lastFrom.email) { return Verdict(important: true, reason: "твоя переписка") }
        if contacts.contains(email) { return Verdict(important: true, reason: "ты писал этому человеку") }
        if !SenderAvatar.personal.contains(domain), contactDomains.contains(domain) {
            return Verdict(important: true, reason: "ты писал в эту компанию")
        }
        if match(Self.personal, t.subject) { return Verdict(important: true, reason: "тебе написал человек или встреча") }
        if ["cal.com", "calendly.com"].contains(where: { domain.hasSuffix($0) }), match(Self.booking, t.subject) {
            return Verdict(important: true, reason: "бронь встречи")
        }
        if !t.bulk, match(Self.money, t.subject) { return Verdict(important: true, reason: "деньги или договор") }
        let cats = Set(t.labelIDs)
        if !cats.isDisjoint(with: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS", "SPAM"]) {
            return Verdict(important: false, reason: "промо, соцсети или форумы по разметке Gmail")
        }
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        if t.bulk { return Verdict(important: false, reason: "рассылка") }
        if match(Self.robot, local) { return Verdict(important: false, reason: "служебный отправитель") }
        // письмо на группу, на псевдоним, который Gmail не знает, или в скрытой копии: если Gmail счёл его личным,
        // решает Jev, а не правило «ты не в адресатах»
        if !t.toMe, !cats.contains("CATEGORY_PERSONAL") { return Verdict(important: false, reason: "ты не в адресатах") }
        // сюда доходят только живые люди: важно всё, кроме уверенного «нет» от Jev
        if let p = jev[Self.jevKey(t)] { return Verdict(important: p >= 0.25, reason: String(format: "Jev %.0f%%", p * 100)) }
        return nil
    }

    /// То же решение, но из кэша: строка не менялась, правила не менялись, значит и ответ тот же.
    func cachedVerdict(_ t: ThreadSummary, isMe: (String) -> Bool) -> Verdict? {
        _ = version
        if let hit = verdictCache[t] { return hit }
        let v = verdict(t, isMe: isMe)
        if verdictCache.count > 5000 { verdictCache.removeAll(keepingCapacity: true) }
        verdictCache[t] = v
        return v
    }

    func isImportant(_ t: ThreadSummary, isMe: (String) -> Bool) -> Bool {
        // спорное до ответа Jev показываем: живой человек лично тебе скорее важен
        cachedVerdict(t, isMe: isMe)?.important ?? true
    }

    // MARK: Обучение

    func set(_ sender: String, important: Bool?) {
        let e = sender.lowercased()
        overrides[e] = important
        let copy = overrides
        let url = Self.overridesURL
        DiskQueue.write { JSONFile.save(copy, to: url) }
    }

    // MARK: Jev и контакты

    /// Отправить спорные треды в Jev (через сервер, ключ там). Ответ кэшируется навсегда.
    func evaluate(_ threads: [ThreadSummary], isMe: @escaping (String) -> Bool) {
        guard let hub, hub.online, hub.isOwner else { return }
        let undecided = threads.filter { cachedVerdict($0, isMe: isMe) == nil && !inFlight.contains(Self.jevKey($0)) }
        guard !undecided.isEmpty else { return }
        undecided.forEach { inFlight.insert(Self.jevKey($0)) }
        Task {
            for chunk in stride(from: 0, to: undecided.count, by: 40).map({ Array(undecided[$0..<min($0 + 40, undecided.count)]) }) {
                let items = chunk.map { t in
                    HubStore.ClassifyItem(id: Self.jevKey(t), from: (t.lastIncoming ?? t.lastFrom).full,
                                          to: t.account, subject: t.subject, snippet: t.snippet)
                }
                let res = await hub.classify(items)
                var next = jev
                for (k, v) in res {
                    if next[k] == nil { jevOrder.append(k) }
                    next[k] = v
                }
                jev = next
            }
            undecided.forEach { inFlight.remove(Self.jevKey($0)) }
            // память не копим, но и не стираем всё разом: уходит старшая половина
            if jevOrder.count > 5000 {
                let drop = jevOrder.prefix(jevOrder.count / 2)
                var next = jev
                drop.forEach { next[$0] = nil }
                jevOrder.removeFirst(drop.count)
                jev = next
            }
            let file = JevFile(scores: jev, order: jevOrder)
            let url = Self.jevURL
            DiskQueue.write { JSONFile.save(file, to: url) }
            writeReport(threads, isMe: isMe, force: true)
        }
    }

    /// Раз в сутки дополнить список людей, которым ты писал.
    func refreshContacts(_ clients: [GmailClient]) {
        Task {
            var changed = false
            for c in clients {
                let acc = c.account
                let last = contactsUpdated[acc]
                if let last, Date().timeIntervalSince(last) < 86400 { continue }
                let found = await c.sentRecipients(since: last)
                let before = contacts.count
                contacts.formUnion(found)
                // пустой ответ при первом сборе это сбой Gmail, а не «никому не писал»: повторим позже
                if !(found.isEmpty && last == nil) { contactsUpdated[acc] = Date() }
                changed = changed || contacts.count != before || last == nil
            }
            if changed || !contactsUpdated.isEmpty {
                let file = ContactsFile(emails: Array(contacts), updated: contactsUpdated)
                let url = Self.contactsURL
                DiskQueue.write { JSONFile.save(file, to: url) }
            }
        }
    }

    /// Отчёт для проверки качества: решение и причина по каждому треду. Не чаще раза в минуту, запись вне главного потока.
    func writeReport(_ threads: [ThreadSummary], isMe: (String) -> Bool, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastReport) > 60 else { return }
        lastReport = Date()
        var lines = ["\(Date())  threads=\(threads.count) contacts=\(contacts.count) jev=\(jev.count)"]
        for t in threads {
            let v = cachedVerdict(t, isMe: isMe)
            let mark = v.map { $0.important ? "+" : "-" } ?? "?"
            lines.append("\(mark) [\(v?.reason ?? "ждёт Jev")] \((t.lastIncoming ?? t.lastFrom).email) | \(t.subject.prefix(70))")
        }
        let text = lines.joined(separator: "\n")
        let url = Self.reportURL
        DiskQueue.write { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}
