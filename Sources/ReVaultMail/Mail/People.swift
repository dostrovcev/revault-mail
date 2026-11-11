import Foundation
import Observation

/// Адресная книга из самой почты: все, кто встречался в списках тредов, плюс найденные в Gmail.
/// Кормит подсказки в поиске («from: Team Wirex»).
@MainActor @Observable
final class PeopleIndex {
    struct Entry: Codable { var name: String; var email: String; var count: Int; var last: Date }

    @ObservationIgnored private var book: [String: Entry] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Совпадения из Gmail по последнему запросу.
    private(set) var remote: (query: String, people: [Person]) = ("", [])
    @ObservationIgnored private var remoteTask: Task<Void, Never>?

    private static let url = AppPaths.cacheDir.appendingPathComponent("people.json")

    init() {
        let list = JSONFile.load([Entry].self, from: Self.url) ?? []
        for e in list { book[e.email] = e }
    }

    func ingest(_ threads: [ThreadSummary], isMe: (String) -> Bool) {
        var changed = false
        for t in threads {
            var seen = Set<String>()
            for p in t.participants + [t.lastFrom] {
                let key = Person.normalized(p.email)
                guard !key.isEmpty, key.contains("@"), !isMe(key), seen.insert(key).inserted else { continue }
                if var e = book[key] {
                    if t.date > e.last { e.last = t.date; e.count += 1; changed = true }
                    if e.name.isEmpty, !p.name.isEmpty { e.name = p.name; changed = true }
                    book[key] = e
                } else {
                    book[key] = Entry(name: p.name, email: key, count: 1, last: t.date)
                    changed = true
                }
            }
        }
        if changed { scheduleSave() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            JSONFile.save(Array(self.book.values), to: Self.url)
        }
    }

    /// Последнее слово в строке поиска, если это не оператор: по нему подбираются люди.
    static func term(in query: String) -> String? {
        MailSearch.term(in: query)
    }

    func matches(_ term: String, limit: Int = 6) -> [Person] {
        let q = term.lowercased()
        func score(_ e: Entry) -> Int? {
            let name = e.name.lowercased(), mail = e.email
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let domain = mail.split(separator: "@").last.map(String.init) ?? ""
            if words.contains(where: { $0.hasPrefix(q) }) || mail.hasPrefix(q) { return 3 }
            if domain.hasPrefix(q) || domain.split(separator: ".").contains(where: { $0.hasPrefix(q) }) { return 2 }
            if name.contains(q) || mail.contains(q) { return 1 }
            return nil
        }
        var local = book.values.compactMap { e in score(e).map { (e, $0) } }
        local.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.count != b.0.count { return a.0.count > b.0.count }
            return a.0.last > b.0.last
        }
        var out = local.prefix(limit).map { Person(name: $0.0.name, email: $0.0.email) }
        if remote.query.lowercased() == q {
            for p in remote.people where out.count < limit && !out.contains(where: { $0.email == Person.normalized(p.email) }) {
                out.append(Person(name: p.name, email: Person.normalized(p.email)))
            }
        }
        return out
    }

    /// Добирает людей из Gmail, если своих совпадений мало. Пауза 300 мс, чтобы не дёргать API на каждую букву.
    func lookup(_ term: String, clients: [GmailClient]) {
        remoteTask?.cancel()
        guard matches(term).count < 5, !clients.isEmpty else { return }
        remoteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            var found: [Person] = []
            await withTaskGroup(of: [Person].self) { g in
                for c in clients { g.addTask { await c.peopleMatching(term) } }
                for await r in g { found += r }
            }
            guard let self, !Task.isCancelled else { return }
            let q = term.lowercased()
            var uniq: [String: Person] = [:]
            for p in found {
                let k = Person.normalized(p.email)
                guard (p.name.lowercased().contains(q) || k.contains(q)) else { continue }
                if uniq[k] == nil || (uniq[k]!.name.isEmpty && !p.name.isEmpty) { uniq[k] = p }
            }
            let people = Array(uniq.values)
            for p in people {
                let k = Person.normalized(p.email)
                if self.book[k] == nil { self.book[k] = Entry(name: p.name, email: k, count: 1, last: .distantPast) }
            }
            if !people.isEmpty { self.scheduleSave() }
            self.remote = (term, people)
        }
    }
}
