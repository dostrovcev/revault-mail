import AppKit
import SwiftUI
import UserNotifications

/// Напоминание «нет ответа через N дней» по отправленному письму.
struct FollowUp: Codable, Identifiable, Hashable {
    var id = UUID()
    var account: String
    /// Тред известен у ответа; у нового письма находится позже по теме и адресату.
    var threadID: String?
    var subject: String
    var recipient: String
    var sentAt: Date
    var days: Int

    var key: ThreadKey? { threadID.map { ThreadKey(account: account, threadID: $0) } }
    var dueAt: Date { sentAt.addingTimeInterval(TimeInterval(days) * 86400) }
}

/// Напоминания: reminders.json, проверка раз в час и при запуске.
/// Если последнее письмо треда всё ещё моё, приходит уведомление, а тред становится непрочитанным и возвращается во Входящие.
@Observable
@MainActor
final class FollowUpStore {
    static let shared = FollowUpStore()
    private static let url = AppPaths.file("reminders.json")

    private(set) var items: [FollowUp] = []
    @ObservationIgnored private weak var store: MailStore?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var checking = false

    private init() {
        items = JSONFile.load([FollowUp].self, from: Self.url) ?? []
    }

    func start(store: MailStore) {
        self.store = store
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
    }

    func add(account: String, threadID: String?, subject: String, recipient: String, days: Int = 3) {
        var list = items
        if let threadID { list.removeAll { $0.account == account && $0.threadID == threadID } }
        list.append(FollowUp(account: account, threadID: threadID, subject: subject, recipient: recipient.lowercased(),
                             sentAt: Date(), days: days))
        items = list
        persist()
    }

    func reminder(for key: ThreadKey) -> FollowUp? { items.first { $0.key == key } }

    func remove(_ id: UUID) {
        let list = items.filter { $0.id != id }
        items = list
        persist()
    }

    /// Проверка: только сроки, которые подошли. Новое письмо сначала находит свой тред.
    func check() async {
        guard let store, store.isOnline, !checking else { return }
        checking = true
        defer { checking = false }
        let now = Date()
        var list = items
        // новое письмо: его тред ищется в Отправленных по адресату и теме (сначала в загруженном списке)
        for i in list.indices where list[i].threadID == nil {
            let f = list[i]
            let subj = Self.baseSubject(f.subject)
            let fits: (ThreadSummary) -> Bool = { t in
                t.account == f.account && Self.baseSubject(t.subject) == subj && t.date >= f.sentAt.addingTimeInterval(-300)
            }
            if let t = store.threads.first(where: fits) {
                list[i].threadID = t.id
                continue
            }
            var q = "newer_than:30d"
            if !f.recipient.isEmpty { q += " to:\(f.recipient)" }
            let words = subj.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespaces)
            if !words.isEmpty { q += " subject:\"\(words)\"" }
            if let found = try? await store.client(f.account).listThreads(labelID: "SENT", query: q, pageToken: nil, max: 5).0,
               let t = found.first(where: fits) {
                list[i].threadID = t.id
            }
        }
        // тред так и не нашёлся за две недели: напоминание снимается
        list.removeAll { $0.threadID == nil && now.timeIntervalSince($0.sentAt) > 14 * 86400 }
        let resolved = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        let merged = items.compactMap { old -> FollowUp? in
            // добавленные во время проверки остаются как есть
            if let r = resolved[old.id] { return r }
            return now.timeIntervalSince(old.sentAt) > 14 * 86400 && old.threadID == nil ? nil : old
        }
        items = merged
        persist()
        list = merged

        for f in list where f.dueAt <= now {
            guard let key = f.key else { continue }
            await store.loadDetail(key)
            guard let d = store.details[key], let last = d.sentMessages.last else {
                if now.timeIntervalSince(f.dueAt) > 30 * 86400 { remove(f.id) }
                continue
            }
            if store.isMe(last.from.email) {
                notify(f, detail: d)
                markUnread(key, inInbox: d.labelIDs.contains("INBOX"))
            }
            remove(f.id)
        }
    }

    private func notify(_ f: FollowUp, detail: ThreadDetail) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = "No reply yet"
        c.subtitle = detail.subject.isEmpty ? f.subject : detail.subject
        let who = detail.sentMessages.last?.to.first?.short ?? f.recipient
        c.body = "You wrote to \(who) \(f.days) days ago. Time to follow up?"
        c.sound = .default
        // идентификатор «ящик/тред»: клик по уведомлению открывает тред (AppDelegate)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: detail.key.string, content: c, trigger: nil))
    }

    private func markUnread(_ key: ThreadKey, inInbox: Bool) {
        guard let store else { return }
        if let t = store.threads.first(where: { $0.key == key }), inInbox {
            if !t.unread { store.toggleUnread(key) }
            return
        }
        let c = store.client(key.account)
        Task {
            try? await c.modifyThread(id: key.threadID, add: ["UNREAD", "INBOX"], remove: [])
            await store.loadDetail(key)
            await store.reload()
        }
    }

    static func baseSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let r = t.range(of: "^(re|fwd|fw|aw|wg)\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        return t.lowercased()
    }

    private func persist() {
        let snapshot = items
        JSONFile.save(snapshot, to: Self.url)
    }
}
