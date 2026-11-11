import SwiftUI

/// Выпадашка под поиском: подсказки операторов Gmail и последние десять поисков.
struct SearchSuggestions: View {
    @Environment(MailStore.self) private var store
    /// Вставить оператор в поле и вернуть в него курсор.
    let insert: (String) -> Void
    /// Запустить поиск по строке.
    let run: (String) -> Void
    /// Подсвеченный человек (стрелки ↓↑ в поле поиска), -1 никто.
    var highlighted: Int = -1

    static let operators: [(token: String, help: String)] = [
        ("from:", "Sender"), ("to:", "Recipient"), ("has:attachment", "With files"),
        ("is:unread", "Unread"), ("after:", "After date, 2026/10/01"), ("label:", "In label"),
    ]

    private var matches: [String] {
        let q = store.searchText.trimmingCharacters(in: .whitespaces)
        let list = store.recentSearches
        return q.isEmpty ? list : list.filter { $0.localizedCaseInsensitiveContains(q) && $0 != q }
    }

    /// Люди под последним словом строки: «wire» даёт Team Wirex, Wirex Support.
    var people: [Person] {
        guard let t = PeopleIndex.term(in: store.searchText) else { return [] }
        return store.people.matches(t)
    }

    /// Выбор человека сохраняет явно указанный оператор; без оператора ищет всю переписку.
    static func query(picking p: Person, in text: String) -> String {
        MailSearch.picking(email: p.email, in: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let people = self.people
            if !people.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(people.enumerated()), id: \.element.email) { i, p in
                        PersonRow(person: p, op: MailSearch.suggestionOperator(in: store.searchText),
                                  highlighted: i == highlighted) {
                            run(Self.query(picking: p, in: store.searchText))
                        }
                    }
                }
                .padding(6)
                HLine()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Self.operators, id: \.token) { op in
                        Button { insert(op.token) } label: {
                            Text(op.token).font(.g(12, .medium)).foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 7).frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
                        }
                        .buttonStyle(.plain).help(op.help)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            if !matches.isEmpty {
                HLine()
                HStack {
                    Text("Recent").font(.g(12, .medium)).foregroundStyle(Theme.faint)
                    Spacer()
                    Button("Clear") { store.clearRecentSearches() }.buttonStyle(.plain)
                        .font(.g(11.5)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { q in
                        RecentRow(text: q, run: { run(q) }, remove: { store.removeRecentSearch(q) })
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))

    }
}

private struct RecentRow: View {
    let text: String
    let run: () -> Void
    let remove: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text(text).font(.g(13)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 4)
            if hover {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint) }
                    .buttonStyle(.plain).help("Remove from recent")
            }
        }
        .padding(.horizontal, 8).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.navHover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: run)
    }
}

/// Строка человека с явным оператором, если он введён.
private struct PersonRow: View {
    let person: Person
    let op: String
    let highlighted: Bool
    let pick: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                SenderAvatar(person: person, size: 22)
                if !op.isEmpty { Text(op).font(.g(13)).foregroundStyle(Theme.sec) }
                Text(person.name.isEmpty ? person.email : person.name).font(.g(14, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
            }
            .padding(.leading, 3).padding(.trailing, 10).frame(height: 28)
            .background(Capsule().fill(Theme.blueSoft))
            .layoutPriority(1)
            Spacer(minLength: 8)
            if !person.name.isEmpty {
                Text(person.email).font(.g(13)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 6).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover || highlighted ? Theme.navHover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: pick)
    }
}
