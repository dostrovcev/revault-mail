import AppKit
import SwiftUI

/// Шаблон письма: имя и текст. {first_name} подставляется именем первого адресата.
struct MailTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var body: String
}

/// Шаблоны и сниппеты: лежат в Application Support/templates.json.
@Observable
@MainActor
final class TemplateStore {
    static let shared = TemplateStore()
    private static let url = AppPaths.file("templates.json")

    private(set) var items: [MailTemplate] = []

    private init() {
        items = JSONFile.load([MailTemplate].self, from: Self.url) ?? []
    }

    func add(name: String, body: String) {
        var list = items
        if let i = list.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            list[i].body = body
        } else {
            list.append(MailTemplate(name: name, body: body))
        }
        items = list
        persist()
    }

    func update(_ t: MailTemplate) {
        var list = items
        guard let i = list.firstIndex(where: { $0.id == t.id }) else { return }
        list[i] = t
        items = list
        persist()
    }

    func remove(_ id: UUID) {
        let list = items.filter { $0.id != id }
        items = list
        persist()
    }

    func matches(_ query: String) -> [MailTemplate] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = items
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.lowercased().contains(q) || $0.body.lowercased().contains(q) }
    }

    /// Текст шаблона с подстановкой имени адресата.
    static func render(_ t: MailTemplate, to recipients: String) -> String {
        let first = Person.parseList(recipients).first
        let name = first.map { p -> String in
            let n = p.name.lowercased() == p.email.lowercased() ? "" : p.name
            return n.split(separator: " ").first.map(String.init) ?? ""
        } ?? ""
        return t.body.replacingOccurrences(of: "{first_name}", with: name.isEmpty ? "there" : name)
    }

    private func persist() {
        let snapshot = items
        JSONFile.save(snapshot, to: Self.url)
    }
}

/// Меню «Templates» в панели редактора: вставить, сохранить текущий текст шаблоном, управлять.
struct TemplatesMenu: View {
    let currentText: () -> String
    let insert: (MailTemplate) -> Void
    @State private var managing = false

    var body: some View {
        let list = TemplateStore.shared.items
        Menu {
            if list.isEmpty {
                Text("No templates yet")
            } else {
                ForEach(list) { t in Button(t.name) { insert(t) } }
            }
            Divider()
            Button("Save current as template…") {
                let text = currentText()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                ComposePrompt.ask(title: "Save as template", info: "Type ;; in an email to insert it. {first_name} becomes the recipient's first name.",
                                  placeholder: "Template name") { name in
                    TemplateStore.shared.add(name: name, body: text)
                }
            }
            Button("Manage…") { managing = true }
        } label: {
            Label("Templates", systemImage: "text.badge.plus")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Templates (type ;; in the text to pick one)")
        .sheet(isPresented: $managing) { TemplatesManager() }
    }
}

/// Выбор шаблона по «;;»: поиск, стрелки, Return вставляет, Esc закрывает.
struct TemplatePicker: View {
    let onPick: (MailTemplate) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let list = TemplateStore.shared.matches(query)
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search templates", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onChange(of: query) { _, _ in highlighted = 0 }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, list.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.return) {
                    if list.indices.contains(highlighted) { onPick(list[highlighted]) }
                    return .handled
                }
                .onKeyPress(.escape) { onCancel(); return .handled }
            if TemplateStore.shared.items.isEmpty {
                Text("No templates yet. Write the text, then Templates > Save current as template.")
                    .font(.g(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if list.isEmpty {
                Text("Nothing found").font(.g(12)).foregroundStyle(Theme.muted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                            Button { onPick(t) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.name).font(.g(12.5, .medium)).foregroundStyle(Theme.ink)
                                    Text(t.body.replacingOccurrences(of: "\n", with: " ")).font(.g(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 5).fill(i == highlighted ? Theme.chip : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(10)
        .frame(width: 300)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// Список шаблонов: правка имени и текста, удаление, новый.
struct TemplatesManager: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var name = ""
    @State private var text = ""

    var body: some View {
        let list = TemplateStore.shared.items
        VStack(alignment: .leading, spacing: 10) {
            Text("Templates").font(.g(15, .semibold))
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    List(selection: $selection) {
                        ForEach(list) { t in Text(t.name).tag(t.id) }
                    }
                    .frame(width: 180, height: 260)
                    HStack {
                        Button { addNew() } label: { Image(systemName: "plus") }.help("New template")
                        Button {
                            if let id = selection { TemplateStore.shared.remove(id); selection = nil; name = ""; text = "" }
                        } label: { Image(systemName: "minus") }
                        .disabled(selection == nil).help("Delete template")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                }
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    TextEditor(text: $text)
                        .font(.g(13))
                        .frame(height: 220)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.ink.opacity(0.1)))
                    Text("{first_name} becomes the first recipient's first name.").font(.g(11)).foregroundStyle(Theme.faint)
                }
                .disabled(selection == nil)
            }
            HStack {
                Spacer()
                Button("Done") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onChange(of: name) { _, _ in save() }
        .onChange(of: text) { _, _ in save() }
        .onChange(of: selection) { _, new in
            if let t = TemplateStore.shared.items.first(where: { $0.id == new }) { name = t.name; text = t.body }
        }
        .onAppear {
            if let first = list.first { selection = first.id; name = first.name; text = first.body }
        }
    }

    private func save() {
        guard let id = selection, var t = TemplateStore.shared.items.first(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != t.name || text != t.body else { return }
        t.name = n
        t.body = text
        TemplateStore.shared.update(t)
    }

    private func addNew() {
        save()
        TemplateStore.shared.add(name: "New template \(TemplateStore.shared.items.count + 1)", body: "")
        if let t = TemplateStore.shared.items.last { selection = t.id; name = t.name; text = t.body }
    }
}
