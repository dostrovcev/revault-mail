import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Общее для обоих редакторов

/// Поле редактора, в котором стоит курсор. Cmd+Enter отправляет письмо только из этих полей,
/// а не из чата команды под ответом.
enum ComposeField: Hashable { case to, cc, bcc, subject, body }

/// Связь редакторов с плашкой Undo: отменённое письмо возвращается туда, откуда ушло.
@Observable
@MainActor
final class ComposeBus {
    static let shared = ComposeBus()
    /// Проверка RVM_DEMO_AUTOSEND срабатывает один раз за запуск.
    static var demoAutoSendFired = false
    /// Тред, в редактор которого надо вернуть отменённый ответ.
    var restoreThread: (key: ThreadKey, nonce: UUID)?
    /// Отменённое новое письмо: окно нового письма открывается с ним.
    var restoreNew: MailStore.PendingSend?
    /// Запланированное новое письмо, которое вернули в редактор (Edit).
    var restoreScheduled: ScheduledMail?
    /// Последняя обработанная просьба ответить (R, кнопки письма): редактор, созданный позже, её не повторяет.
    @ObservationIgnored var handledReplyNonce: UUID?

    /// Undo для отложенной отправки: письмо не уходит и возвращается в свой редактор.
    static func undoPendingSend(store: MailStore, ui: UIState) {
        guard let p = store.cancelPendingSend() else { return }
        if let k = p.threadKey {
            if store.replyDrafts[k] == nil {
                let mode: ReplyMode = p.forwardFrom != nil ? .forward : (p.cc.isEmpty ? .reply : .replyAll)
                store.saveReplyDraft(k, ReplyDraft(mode: mode.rawValue, to: Recipients.join(p.to), cc: Recipients.join(p.cc),
                                                   bcc: Recipients.join(p.bcc), subject: p.subject, text: p.body,
                                                   gmailDraftID: p.draftID, replyToMessageID: (p.forwardFrom ?? p.replyTo)?.id))
            }
            var extras = ComposerSession.extras[k] ?? ComposerSession.Extras()
            extras.attachments = p.attachments
            if let f = p.from { extras.from = f }
            ComposerSession.extras[k] = extras
            shared.restoreThread = (k, UUID())
        } else {
            shared.restoreNew = p
            ui.showNewMessage = true
        }
    }
}

/// То, чего нет в ReplyDraft (адрес «От», файлы), держится на время работы приложения по треду.
@MainActor
enum ComposerSession {
    struct Extras {
        var from: Person?
        var attachments: [URL] = []
        var showCc = false
        var showBcc = false
        /// Текст с оформлением: черновик хранит только строку, оформление живёт до перезапуска.
        var rich: NSAttributedString?
        var remind = false
    }
    static var extras: [ThreadKey: Extras] = [:]
}

/// Адреса в поле Кому/Копия/Скрытая и подсказки по ним.
@MainActor
enum Recipients {
    static func join(_ people: [Person]) -> String { people.map { clean($0).rfcFull }.joined(separator: ", ") }

    /// Имя, совпадающее с адресом (или пустое в кавычках), не показывается и не уходит: просто адрес.
    nonisolated static func clean(_ p: Person) -> Person {
        let n = p.name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        if n.isEmpty || n.lowercased() == p.email.lowercased() { return Person(name: "", email: p.email) }
        return Person(name: n, email: p.email)
    }

    /// Подпись плашки: имя, иначе адрес.
    nonisolated static func label(_ p: Person) -> String {
        let c = clean(p)
        return c.name.isEmpty ? c.email : c.name
    }

    /// Куски строки адресов по запятой вне кавычек и угловых скобок.
    nonisolated static func segments(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false, depth = 0
        for ch in s {
            if ch == "\"" { quoted.toggle() }
            if !quoted, ch == "<" { depth += 1 }
            if !quoted, ch == ">" { depth = max(0, depth - 1) }
            if (ch == "," || ch == ";"), !quoted, depth == 0 {
                out.append(cur); cur = ""
            } else {
                cur.append(ch)
            }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Повторы одного адреса убираются, первый остаётся.
    static func dedupe(_ people: [Person]) -> [Person] {
        var seen = Set<String>()
        return people.filter { seen.insert(Person.normalized($0.email)).inserted }
    }

    /// Неверные адреса во всех полях: для понятного отказа до отправки.
    static func invalid(_ fields: [String]) -> [String] {
        fields.flatMap { Person.invalidEntries($0) }
    }

    private static var cache: (stamp: Int, people: [Person])?

    /// Люди для подсказок: те, кому я писал, и участники тредов в списке. Без моих адресов и роботов.
    static func people(_ store: MailStore) -> [Person] {
        let contacts = store.importance.contacts
        let stamp = store.threads.count &* 31 &+ contacts.count &+ store.details.count &* 7
        if let c = cache, c.stamp == stamp { return c.people }
        var names: [String: String] = [:]
        var score: [String: Int] = [:]
        func add(_ p: Person, weight: Int) {
            let e = p.email.lowercased()
            guard e.contains("@"), !store.isMe(e), !isRobot(e) else { return }
            if names[e, default: ""].isEmpty, !p.name.isEmpty, p.name.lowercased() != e { names[e] = p.name }
            score[e, default: 0] += weight
        }
        for t in store.threads {
            t.participants.forEach { add($0, weight: 1) }
            if let p = t.lastIncoming { add(p, weight: 1) }
        }
        for d in store.details.values {
            for m in d.messages {
                add(m.from, weight: 1)
                (m.to + m.cc).forEach { add($0, weight: 1) }
            }
        }
        for e in contacts { add(Person(name: "", email: e), weight: 5) }
        let out = score.keys.sorted { (score[$0] ?? 0, $1) > (score[$1] ?? 0, $0) }
            .map { Person(name: names[$0] ?? "", email: $0) }
        cache = (stamp, out)
        return out
    }

    private static func isRobot(_ e: String) -> Bool {
        let local = e.split(separator: "@").first.map(String.init) ?? e
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon", "notifications", "notification", "bounce"]
            .contains { local.hasPrefix($0) }
    }

    /// Недописанный адрес: всё после последней запятой.
    static func currentToken(_ text: String) -> String {
        let cut = text.lastIndex { $0 == "," || $0 == ";" }.map { text.index(after: $0) } ?? text.startIndex
        return String(text[cut...]).trimmingCharacters(in: .whitespaces)
    }

    static func matches(_ text: String, store: MailStore, limit: Int = 6) -> [Person] {
        let q = currentToken(text).lowercased()
        guard !q.isEmpty, !q.contains("<") else { return [] }
        let already = Set(Person.parseList(text).map { Person.normalized($0.email) })
        var out: [Person] = []
        for p in people(store) {
            if already.contains(Person.normalized(p.email)) && p.email != q { continue }
            let nameHit = p.name.lowercased().split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" })
                .contains { $0.hasPrefix(q) } || p.name.lowercased().hasPrefix(q)
            if p.email.hasPrefix(q) || nameHit || p.email.split(separator: "@").last?.hasPrefix(q) == true {
                if p.email == q { continue }
                out.append(p)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Подставить выбранного человека вместо недописанного адреса.
    static func accept(_ p: Person, into text: String) -> String {
        let cut = text.lastIndex { $0 == "," || $0 == ";" }.map { text.index(after: $0) } ?? text.startIndex
        let head = String(text[..<cut]).trimmingCharacters(in: .whitespaces)
        return (head.isEmpty ? "" : head + " ") + p.rfcFull + ", "
    }
}

/// Адресат плашкой: введённая строка и разобранный человек (nil, если это не адрес).
struct RecipientChip: Identifiable, Hashable {
    let id = UUID()
    var raw: String
    var person: Person?

    init(raw: String) {
        self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = self.raw.contains("@") ? Person.parse(self.raw).map(Recipients.clean) : nil
        person = p
    }

    init(person: Person) {
        let p = Recipients.clean(person)
        raw = p.rfcFull
        self.person = p
    }

    var valid: Bool { person?.isValidEmail ?? false }
    var label: String { person.map(Recipients.label) ?? raw }
    var serialized: String { person?.rfcFull ?? raw }
}

/// Поле адресатов плашками, как в Apple Mail: запятая, Return или Tab превращают набранное в плашку,
/// Backspace в пустом поле убирает последнюю, неверный адрес красный. Подсказки: стрелки, Return/Tab, Esc.
/// Наружу поле отдаёт ту же строку адресов, что и раньше (её разбирает Person.parseList).
struct RecipientField: View {
    let title: String
    @Binding var text: String
    let field: ComposeField
    var focus: FocusState<ComposeField?>.Binding
    @Environment(MailStore.self) private var store
    @State private var highlighted = 0
    @State private var hidden = false
    @State private var chips: [RecipientChip] = []
    @State private var draft = ""
    /// Строка, которую поле записало само: чужая запись (загрузка черновика, автоподстановка) разбирается заново.
    @State private var lastWritten: String?

    private var focused: Bool { focus.wrappedValue == field }

    private var suggestions: [Person] {
        guard focused, !hidden, !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let committed = chips.map(\.serialized).joined(separator: ", ")
        return Recipients.matches(committed.isEmpty ? draft : committed + ", " + draft, store: store)
    }

    var body: some View {
        let list = suggestions
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Text(title).font(.g(12)).foregroundStyle(Theme.muted).frame(width: 52, height: 21, alignment: .leading)
                FlowLayout(spacing: 4, lineSpacing: 3) {
                    ForEach(chips) { chip in chipView(chip) }
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.g(13))
                        .frame(minWidth: 120, minHeight: 21)
                        .focused(focus, equals: field)
                        .onChange(of: draft) { _, v in
                            hidden = false; highlighted = 0
                            if v.contains(",") || v.contains(";") { commitSeparated(v) } else { write() }
                        }
                        .onSubmit { commitDraft() }
                        .onKeyPress(.downArrow) {
                            guard !list.isEmpty else { return .ignored }
                            highlighted = min(highlighted + 1, list.count - 1); return .handled
                        }
                        .onKeyPress(.upArrow) {
                            guard !list.isEmpty else { return .ignored }
                            highlighted = max(highlighted - 1, 0); return .handled
                        }
                        .onKeyPress(.return) {
                            if !list.isEmpty { pick(list[min(highlighted, list.count - 1)]); return .handled }
                            guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return .ignored }
                            commitDraft(); return .handled
                        }
                        .onKeyPress(.tab) {
                            if !list.isEmpty { pick(list[min(highlighted, list.count - 1)]); return .handled }
                            if !draft.trimmingCharacters(in: .whitespaces).isEmpty { commitDraft() }
                            return .ignored
                        }
                        .onKeyPress(.delete) {
                            guard draft.isEmpty, !chips.isEmpty else { return .ignored }
                            chips.removeLast()
                            write()
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            guard !list.isEmpty else { return .ignored }
                            hidden = true; return .handled
                        }
                }
                .contentShape(Rectangle())
                .onTapGesture { focus.wrappedValue = field }
            }
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.email) { i, p in
                        Button { pick(p) } label: {
                            HStack(spacing: 8) {
                                Text(Recipients.label(p)).font(.g(12.5, .medium)).foregroundStyle(Theme.ink)
                                if !Recipients.clean(p).name.isEmpty { Text(p.email).font(.g(12)).foregroundStyle(Theme.muted) }
                                Spacer()
                            }
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 5).fill(i == highlighted ? Theme.chip : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.white))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                .padding(.leading, 56)
            }
        }
        .padding(.vertical, 2)
        .onAppear { parse(text) }
        .onChange(of: text) { _, v in if v != lastWritten { parse(v) } }
        .onChange(of: focused) { _, f in if !f { commitDraft() } }
    }

    private func chipView(_ chip: RecipientChip) -> some View {
        HStack(spacing: 4) {
            Text(chip.label).font(.g(12.5, .medium))
                .foregroundStyle(chip.valid ? Theme.ink2 : Theme.accentText)
                .lineLimit(1).truncationMode(.middle)
            Button {
                chips.removeAll { $0.id == chip.id }
                write()
            } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(chip.valid ? Theme.muted : Theme.accentText)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.leading, 8).padding(.trailing, 6).frame(height: 21)
        .frame(maxWidth: 260)
        .background(Capsule().fill(chip.valid ? Theme.chip : Theme.accentBg))
        .overlay(Capsule().stroke(chip.valid ? .clear : Theme.accent.opacity(0.5)))
        .help(chip.valid ? (chip.person.map { Recipients.clean($0).name.isEmpty ? $0.email : "\(Recipients.clean($0).name) <\($0.email)>" } ?? chip.raw)
              : "Not a valid address: \(chip.raw)")
    }

    private func parse(_ s: String) {
        chips = Recipients.segments(s).map(RecipientChip.init(raw:))
        draft = ""
        lastWritten = s
    }

    /// Строка наружу: плашки и недописанный адрес (он тоже уходит при отправке и проверке).
    private func write() {
        var parts = chips.map(\.serialized)
        let d = draft.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty { parts.append(d) }
        let s = parts.joined(separator: ", ")
        lastWritten = s
        if text != s { text = s }
    }

    private func commitDraft() {
        let d = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return }
        chips.append(contentsOf: Recipients.segments(d).map(RecipientChip.init(raw:)))
        draft = ""
        write()
    }

    /// Набрали или вставили запятую: всё до последней запятой становится плашками.
    private func commitSeparated(_ v: String) {
        let cut = v.lastIndex { $0 == "," || $0 == ";" }.map { v.index(after: $0) } ?? v.startIndex
        let head = String(v[..<cut])
        let tail = String(v[cut...])
        chips.append(contentsOf: Recipients.segments(head).map(RecipientChip.init(raw:)))
        draft = tail.trimmingCharacters(in: .whitespaces)
        write()
    }

    private func pick(_ p: Person) {
        chips.append(RecipientChip(person: p))
        draft = ""
        hidden = true
        highlighted = 0
        write()
    }
}

/// Файлы письма плашками: свои с крестиком, вложения пересылаемого письма без него (уходят вместе с ним).
struct ComposeAttachmentChips: View {
    @Binding var files: [URL]
    var forwarded: [Attachment] = []

    var body: some View {
        if !files.isEmpty || !forwarded.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(forwarded) { a in
                        chip(name: a.filename, size: a.size, help: "Attached from the forwarded email", remove: nil)
                    }
                    ForEach(files, id: \.self) { url in
                        chip(name: url.lastPathComponent, size: Self.size(of: url), help: url.path) {
                            files.removeAll { $0 == url }
                        }
                    }
                }
            }
        }
    }

    private func chip(name: String, size: Int, help: String, remove: (() -> Void)?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "paperclip").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
            Text(name).font(.g(12, .medium)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
            if size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.g(11)).foregroundStyle(Theme.faint)
            }
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted) }
                    .buttonStyle(.plain).help("Remove")
            }
        }
        .padding(.horizontal, 8).frame(height: 24)
        .frame(maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
        .help(help)
    }

    static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Файлы, брошенные на редактор.
    static func load(_ providers: [NSItemProvider], into add: @escaping @MainActor (URL) -> Void) -> Bool {
        var any = false
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            any = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in add(url) }
            }
        }
        return any
    }

    /// Только обычные файлы: папку письмом не отправить.
    static func isRegularFile(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }
}

/// Плашка «Sending to X · Undo · Send now» для отложенной отправки. Ставится поверх окна (RootView).
struct SendUndoToast: View {
    @Environment(MailStore.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        if let p = store.pendingSend {
            HStack(spacing: 16) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(p.fireAt.timeIntervalSince(ctx.date).rounded(.up)))
                    Text("\(p.title) · \(left)s").font(.g(13.5)).foregroundStyle(.white).monospacedDigit()
                }
                Button("Undo") { ComposeBus.undoPendingSend(store: store, ui: ui) }
                    .buttonStyle(.plain).font(.g(13.5, .semibold)).foregroundStyle(.white)
                Button("Send now") { store.flushPendingSend() }
                    .buttonStyle(.plain).font(.g(13)).foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x2B2F36)))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Галочка напоминания «нет ответа через 3 дня».
@MainActor
func remindToggle(_ on: Binding<Bool>) -> some View {
    Toggle("Remind me if no reply in 3 days", isOn: on)
        .toggleStyle(.checkbox).font(.g(11.5)).foregroundStyle(Theme.muted)
        .help("If the last email in the conversation is still yours in 3 days, you get a notification and it turns unread")
}

// MARK: Ответ в треде

/// Ответ внизу треда, как в Missive: по клику редактор. Недописанный ответ живёт в store.replyDrafts:
/// переживает переход к другому треду и перезапуск, в Gmail он же сохраняется черновиком.
struct ComposerView: View {
    let detail: ThreadDetail
    /// Высота окна треда: большой ответ занимает её почти всю.
    var available: CGFloat = 0
    /// Ответ на весь экран; кнопка в шапке редактора ужимает его, чтобы читать письмо рядом.
    @AppStorage("composer.big") private var bigPreferred = true
    /// Ответ открыт нажатием. Черновик, поднятый при открытии письма, письмо не закрывает.
    @State private var openedByHand = false
    @Environment(MailStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @Environment(\.openWindow) private var openWindow

    @State private var expanded = false
    @State private var mode: ReplyMode = .reply
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var text = ""
    /// Письмо, на которое отвечаем или которое пересылаем (то, на котором нажали Reply).
    @State private var targetID: String?
    @State private var from: Person?
    @State private var attachments: [URL] = []
    @State private var savingDraft = false
    @State private var savedNote = false
    @State private var translating = false
    @State private var undoText: String?
    @State private var showCc = false
    @State private var showBcc = false
    @State private var picking = false
    @State private var dropTargeted = false
    @FocusState private var focus: ComposeField?
    @State private var note = ""
    @State private var noteFocus = UUID()
    /// Что подставил сам редактор: пока пользователь их не правил, смена режима их переписывает.
    @State private var autoTo = ""
    @State private var autoCc = ""
    @State private var autoSubject = ""
    @State private var saveTask: Task<Void, Never>?
    /// Ищем id черновика Gmail, найденного в треде: до ответа не сохраняем, иначе появится второй черновик.
    @State private var adoptingDraft = false
    @State private var adoptedDraftID: String?
    /// Письмо-адресат на момент последней правки: нужно, чтобы сохранить ответ уже после смены треда.
    @State private var knownTargetID: String?
    /// Редактор тела с оформлением.
    @State private var rich = RichTextController()
    @State private var editorHeight: CGFloat = 130
    @State private var bodyFocused = false
    /// Цитата, срезанная с восстановленного черновика: уходит в письмо, если у ответа нет письма-адресата.
    @State private var quotedTail: String?
    @State private var remind = false
    @State private var templatePicker = false

    /// Тред из чужой почты (участник видит снимок): ответить письмом нельзя, только обсуждать.
    private var canReply: Bool { store.isMe(detail.account) }

    /// Письма треда без черновиков.
    private var sent: [MailMessage] { detail.sentMessages }

    /// По умолчанию последнее входящее; Reply на конкретном письме выбирает его.
    private var target: MailMessage? {
        if let id = targetID, let m = sent.first(where: { $0.id == id }) { return m }
        return sent.last { !store.isMe($0.from.email) } ?? sent.last
    }

    private var pendingHere: MailStore.PendingSend? {
        guard let p = store.pendingSend, p.threadKey == detail.key else { return nil }
        return p
    }

    private var sender: Person { from ?? store.defaultFrom(account: detail.account, replyingTo: target) }

    private var fromOptions: [Person] {
        let list = store.aliases[detail.account] ?? []
        var out = list.isEmpty ? [store.me(detail.account)] : list
        if let f = from, !out.contains(where: { Person.normalized($0.email) == Person.normalized(f.email) }) { out.append(f) }
        return out
    }

    private var editorFocused: Bool { focus != nil || bodyFocused }

    private var canSend: Bool {
        pendingHere == nil && !Recipients.dedupe(Person.parseList(to) + Person.parseList(cc) + Person.parseList(bcc)).isEmpty
            && (mode == .forward || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var signatureHTML: String? { store.signature(for: sender.email) ?? store.signature(for: detail.account) }

    /// Снимок полей: любое изменение запускает сохранение черновика.
    private var snapshot: String { [mode.rawValue, to, cc, bcc, subject, text, targetID ?? ""].joined(separator: "\u{1}") }

    private var isBig: Bool { bigPreferred && openedByHand && expanded && canReply && available > 0 }

    /// Шапка письма и полоска письма над ответом (220), поле заметки с отступами (86).
    private var bigHeight: CGFloat { max(360, available - 306) }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = pendingHere {
                sendingBanner(p)
            }
            ForEach(ScheduledSendStore.shared.items(for: detail.key)) { m in scheduledBanner(m) }
            if expanded && canReply {
                editor
                    .frame(height: isBig ? bigHeight : nil)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.white))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(dropTargeted ? Theme.accent : Theme.border, lineWidth: dropTargeted ? 2 : 1))
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                        ComposeAttachmentChips.load(providers) { addFile($0) }
                    }
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
        .frame(maxWidth: 1040)
        .frame(maxWidth: .infinity)
        .background(Theme.page)
    }

    var body: some View {
        observers(layout)
            .onChange(of: snapshot) { _, _ in scheduleSave() }
            .onChange(of: from) { _, _ in rememberExtras() }
            .onChange(of: attachments) { _, _ in rememberExtras() }
            .onChange(of: remind) { _, _ in rememberExtras() }
            .onChange(of: agent.pendingInsert?.text) { _, _ in consumePending() }
            .onChange(of: agent.autoSendRequest?.nonce) { _, _ in consumeAutoSend() }
            .onAppear {
                ScheduledSendStore.shared.start(store: store)
                FollowUpStore.shared.start(store: store)
                load()
                handleReplyRequest()
                consumePending()
                if DevTools.isDemo, ProcessInfo.processInfo.environment["RVM_DEMO_REPLY"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { open(.replyAll) }
                }
                // проверка без Gmail: RVM_DEMO_AUTOSEND=<ответ модели> проходит тем же путём, что кнопка Send
                if DevTools.isDemo, !ComposeBus.demoAutoSendFired, let raw = ProcessInfo.processInfo.environment["RVM_DEMO_AUTOSEND"],
                   let t = AgentStore.replyText(in: raw) {
                    ComposeBus.demoAutoSendFired = true
                    let k = detail.key
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { agent.autoSendRequest = (k, t, UUID()) }
                }
            }
            .onDisappear { flush(detail.key) }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach(addFile) }
            }
    }

    private func observers<V: View>(_ v: V) -> some View {
        v
        .onChange(of: detail.key) { old, _ in
            flush(old)
            note = ""
            load()
        }
        .onChange(of: detail.latestDraft?.id) { _, _ in
            // черновик Gmail пришёл с догрузкой треда: подхватываем, если своего ответа ещё нет
            if !expanded, store.replyDrafts[detail.key] == nil, let gd = detail.latestDraft, canReply { adoptGmailDraft(gd) }
        }
        .onChange(of: ui.replyRequest?.nonce) { _, _ in handleReplyRequest() }
        .onChange(of: ui.noteRequest?.nonce) { _, _ in
            if let r = ui.noteRequest {
                let t = r.text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !note.contains(t) { note = r.text + note }
                noteFocus = UUID()
            }
        }
        .onChange(of: ComposeBus.shared.restoreThread?.nonce) { _, _ in
            guard let r = ComposeBus.shared.restoreThread, r.key == detail.key else { return }
            ComposeBus.shared.restoreThread = nil
            load()
            expanded = true
            focusEditor()
        }
    }

    private func sendingBanner(_ p: MailStore.PendingSend) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(p.fireAt.timeIntervalSince(ctx.date).rounded(.up)))
                Text("\(p.title) in \(left)s").font(.g(13)).foregroundStyle(Theme.ink2).monospacedDigit()
            }
            Spacer()
            Button("Undo") { ComposeBus.undoPendingSend(store: store, ui: ui) }.buttonStyle(.link).font(.g(13, .semibold))
            Button("Send now") { store.flushPendingSend() }.buttonStyle(.link).font(.g(12.5))
        }
        .padding(.horizontal, 14).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private func scheduledBanner(_ m: ScheduledMail) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(m.failed ? "Scheduled reply was not sent" : "Reply scheduled for \(ScheduledSendStore.label(m.sendAt))")
                .font(.g(13)).foregroundStyle(m.failed ? Theme.accentText : Theme.ink2)
            Text("from this Mac").font(.g(11.5)).foregroundStyle(Theme.faint)
            Spacer()
            Button("Edit") { editScheduled(m) }.buttonStyle(.link).font(.g(12.5, .semibold))
            Button(m.failed ? "Retry" : "Send now") { ScheduledSendStore.shared.sendNow(m.id) }.buttonStyle(.link).font(.g(12.5))
            Button("Cancel") { ScheduledSendStore.shared.cancel(m.id) }.buttonStyle(.link).font(.g(12.5))
        }
        .padding(.horizontal, 14).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    private func editorHeader(pickerWidth: CGFloat, showFrom: Bool) -> some View {
        HStack {
            Picker("", selection: Binding(get: { mode }, set: { switchMode($0) })) {
                Text("Reply").tag(ReplyMode.reply)
                Text("Reply all").tag(ReplyMode.replyAll)
                Text("Forward").tag(ReplyMode.forward)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: pickerWidth)
            Spacer(minLength: 4)
            if showFrom { fromPicker.fixedSize() }
            Button {
                if isBig { bigPreferred = false } else { bigPreferred = true; openedByHand = true }
            } label: { Image(systemName: isBig ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless).help(isBig ? "Make the reply smaller to read the email" : "Make the reply full height")
            Button { popOut() } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).help("Open in a separate window")
            Button { collapse() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close (the draft is kept)")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            // шапка влезает в любую колонку: сначала уходит адрес отправителя, потом сужаются режимы
            ViewThatFits(in: .horizontal) {
                editorHeader(pickerWidth: 300, showFrom: true)
                editorHeader(pickerWidth: 300, showFrom: false)
                editorHeader(pickerWidth: 214, showFrom: false)
            }
            if let t = target, sent.count > 1, t.id != sent.last?.id || targetID != nil {
                Text("\(mode == .forward ? "Forwarding" : "Replying to") \(t.from.short), \(Fmt.fullDate(t.date))")
                    .font(.g(11.5)).foregroundStyle(Theme.faint)
            }
            RecipientField(title: "To", text: $to, field: .to, focus: $focus)
            if showCc || !cc.isEmpty { RecipientField(title: "Cc", text: $cc, field: .cc, focus: $focus) }
            if showBcc || !bcc.isEmpty { RecipientField(title: "Bcc", text: $bcc, field: .bcc, focus: $focus) }
            if mode == .forward {
                HStack {
                    Text("Subject").font(.g(12)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                    TextField("", text: $subject).textFieldStyle(.plain).focused($focus, equals: .subject)
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                FormatBar(controller: rich)
                ZStack(alignment: .topLeading) {
                    RichTextEditor(text: $text, controller: rich, minHeight: 130, maxHeight: isBig ? 4000 : 460, height: $editorHeight,
                                   onAttach: { addFile($0) },
                                   onSubmit: { if canSend { send() } },
                                   onFocusChange: { f in bodyFocused = f },
                                   onTrigger: { templatePicker = true })
                        .frame(height: isBig ? nil : editorHeight)
                        .frame(maxHeight: isBig ? .infinity : nil)
                    if text.isEmpty {
                        Text(mode == .forward ? "Add a note (the original email is attached below it)" : "Write a reply  (;; for templates)")
                            .font(.g(13.5)).foregroundStyle(Theme.faint).padding(.leading, 5).padding(.top, 4).allowsHitTesting(false)
                    }
                }
                .popover(isPresented: $templatePicker, arrowEdge: .bottom) {
                    TemplatePicker(onPick: { t in insertTemplate(t, trigger: true) }, onCancel: { templatePicker = false; rich.focus() })
                }
            }
            .padding(6)
            .background(Theme.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.ink.opacity(0.1)))

            if mode != .forward, let quote = target.map(ComposeQuote.preview) ?? quotedTail {
                QuotedTextToggle(quote: quote).padding(.leading, 6)
            }

            if let block = ComposeSignature.block(signatureHTML) {
                Text(block).font(.g(11.5)).foregroundStyle(Theme.faint).lineLimit(5)
                    .padding(.leading, 6).help("Your signature is added when the email is sent")
            }

            ComposeAttachmentChips(files: $attachments, forwarded: mode == .forward ? (target?.attachments.filter { !$0.inline } ?? []) : [])

            remindToggle($remind)

            ViewThatFits(in: .horizontal) {
                actionRow(compact: false).fixedSize(horizontal: true, vertical: false)
                actionRow(compact: true)
                actionRow(compact: true, tiny: true)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    /// Нижний ряд редактора: полный, а в узком окне без подписей, Cc/Bcc и «Save draft» уходят в меню.
    @ViewBuilder private func actionRow(compact: Bool, tiny: Bool = false) -> some View {
        HStack(spacing: 10) {
                Button { askAgentForReply() } label: { Group { if compact { Image(systemName: "sparkle") } else { Label("Agent", systemImage: "sparkle") } } }
                    .help("The agent writes or improves the reply")
                if !tiny {
                Menu {
                    ForEach(AppSettings.languages, id: \.self) { lang in
                        Button(lang) { translateDraft(to: lang) }
                    }
                } label: {
                    if translating { ProgressView().controlSize(.small) } else if compact { Image(systemName: "character.bubble") } else { Label("Translate", systemImage: "character.bubble") }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(text.isEmpty || translating)
                }
                Button { picking = true } label: { Image(systemName: "paperclip") }.help("Attach files (or drop or paste them here)")
                if !tiny { TemplatesMenu(currentText: { text }, insert: { insertTemplate($0, trigger: false) }) }
                if let undo = undoText {
                    Button("Undo") { text = undo; undoText = nil }.buttonStyle(.link).font(.g(12))
                }
                if !compact, !showCc && cc.isEmpty { Button("Cc") { showCc = true; focusLater(.cc) }.buttonStyle(.link).font(.g(12)) }
                if !compact, !showBcc && bcc.isEmpty { Button("Bcc") { showBcc = true; focusLater(.bcc) }.buttonStyle(.link).font(.g(12)) }
                Spacer()
                if savedNote { Text("Draft saved").font(.g(11.5)).foregroundStyle(Theme.faint) }
                if !tiny { Button { discard() } label: { Image(systemName: "trash") }.help("Discard this reply and its draft") }
                if compact {
                    Menu {
                        if tiny {
                            Menu("Translate") {
                                ForEach(AppSettings.languages, id: \.self) { lang in
                                    Button(lang) { translateDraft(to: lang) }
                                }
                            }
                            .disabled(text.isEmpty || translating)
                            Button("Templates") { templatePicker = true }
                            Button("Discard reply", role: .destructive) { discard() }
                        }
                        if !showCc && cc.isEmpty { Button("Cc") { showCc = true; focusLater(.cc) } }
                        if !showBcc && bcc.isEmpty { Button("Bcc") { showBcc = true; focusLater(.bcc) } }
                        Button("Save draft") { Task { await saveDraftNow() } }.disabled(savingDraft)
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                } else {
                    Button("Save draft") { Task { await saveDraftNow() } }.disabled(savingDraft)
                }
                Button {
                    send()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                // Cmd+Enter только из полей письма: в чате команды он отправляет заметку
                .keyboardShortcut(editorFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .buttonStyle(.dashPrimary)
                .disabled(!canSend)
                .help("Send (Cmd+Enter)")
                SendLaterMenu(enabled: canSend) { scheduleSend(at: $0) }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var fromPicker: some View {
        let options = fromOptions
        if options.count > 1 {
            Menu {
                ForEach(options, id: \.email) { p in
                    Button { from = p } label: {
                        if Person.normalized(p.email) == Person.normalized(sender.email) { Label(p.full, systemImage: "checkmark") } else { Text(p.full) }
                    }
                }
            } label: {
                Text("from \(sender.email)").font(.g(12)).foregroundStyle(Theme.muted)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Send from another address")
        } else {
            Text("from \(sender.email)").font(.g(12)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Состояние

    private func resetFields() {
        saveTask?.cancel()
        saveTask = nil
        expanded = false
        openedByHand = false
        mode = .reply
        to = ""; cc = ""; bcc = ""; subject = ""; text = ""
        autoTo = ""; autoCc = ""; autoSubject = ""
        targetID = nil
        from = nil
        attachments = []
        undoText = nil
        showCc = false
        showBcc = false
        savedNote = false
        adoptingDraft = false
        adoptedDraftID = nil
        knownTargetID = nil
        quotedTail = nil
        remind = false
        templatePicker = false
    }

    /// Текст для редактора: без цитаты прошлого письма и без подписи (их добавит отправка).
    private func editable(_ raw: String) -> String {
        let parts = ComposeQuote.split(raw)
        if let q = parts.quote { quotedTail = q }
        return ComposeSignature.strip(parts.body, signatureHTML: signatureHTML)
    }

    /// Что уходит в письмо: текст с оформлением; срезанная цитата возвращается, только если отправка её не добавит сама.
    private func outgoingBody() -> ComposeBody {
        let same = attributedRaw(rich.attributed) == text
        var plain = same ? rich.plain : text
        var html = same ? rich.html : nil
        if mode != .forward, target == nil, let q = quotedTail {
            plain += "\n\n" + q
            if html != nil { html! += "<blockquote style=\"margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex\">" + HTMLText.paragraphs(q) + "</blockquote>" }
        }
        return ComposeBody(plain: plain, html: html)
    }

    /// Поднять ответ этого треда: свой недописанный, иначе черновик из Gmail.
    private func load() {
        resetFields()
        guard canReply else { return }
        let k = detail.key
        // письмо этого треда ждёт отправки: редактор пуст, пока не нажали Undo
        if store.pendingSend?.threadKey == k { return }
        let extras = ComposerSession.extras[k]
        if let d = store.replyDrafts[k] {
            apply(d)
            from = extras?.from
            attachments = extras?.attachments ?? []
            showCc = extras?.showCc ?? false
            showBcc = extras?.showBcc ?? false
            remind = extras?.remind ?? false
            if let r = extras?.rich, attributedRaw(r) == text { rich.restore(r) }
            if !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty { expanded = true }
        } else if let gd = detail.latestDraft {
            adoptGmailDraft(gd)
        }
        knownTargetID = target?.id
    }

    private func apply(_ d: ReplyDraft) {
        mode = ReplyMode(rawValue: d.mode) ?? .reply
        targetID = d.replyToMessageID
        let auto = autofill(mode)
        autoTo = auto.to; autoCc = auto.cc; autoSubject = auto.subject
        to = d.to; cc = d.cc; bcc = d.bcc
        subject = d.subject.isEmpty ? auto.subject : d.subject
        text = editable(d.text)
    }

    /// Черновик, лежащий в треде в Gmail (с телефона, из Gmail web, из прошлой версии): открывается в редакторе.
    private func adoptGmailDraft(_ m: MailMessage) {
        let k = detail.key
        // в черновике одна цитата без своего текста (оставил другой клиент): редактор сам не раскрываем
        if store.editableText(ofDraft: m).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !m.attachments.contains(where: { !$0.inline }) { return }
        let s = m.subject.lowercased()
        mode = s.hasPrefix("fwd:") || s.hasPrefix("fw:") ? .forward : (m.cc.isEmpty ? .reply : .replyAll)
        targetID = nil
        let auto = autofill(mode)
        autoTo = auto.to; autoCc = auto.cc; autoSubject = auto.subject
        to = Recipients.join(m.to)
        cc = Recipients.join(m.cc)
        bcc = ""
        subject = m.subject.isEmpty ? auto.subject : m.subject
        text = editable(store.editableText(ofDraft: m))
        expanded = true
        adoptingDraft = true
        Task {
            let id = await store.client(k.account).draftID(forMessage: m.id)
            guard detail.key == k, adoptingDraft else { return }
            adoptedDraftID = id
            adoptingDraft = false
            flush(k)
        }
    }

    private func currentDraft(_ k: ThreadKey) -> ReplyDraft {
        // при смене треда detail уже новый: письмо-адресат берём из запомненного
        ReplyDraft(mode: mode.rawValue, to: to, cc: cc, bcc: bcc, subject: subject, text: text,
                   gmailDraftID: store.replyDrafts[k]?.gmailDraftID ?? adoptedDraftID,
                   replyToMessageID: k == detail.key ? target?.id : knownTargetID)
    }

    private func scheduleSave() {
        guard expanded, canReply else { return }
        knownTargetID = target?.id
        savedNote = false
        saveTask?.cancel()
        let k = detail.key
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, detail.key == k else { return }
            flush(k)
        }
    }

    /// Записать ответ в store сразу (уход с треда, закрытие, отправка).
    private func flush(_ k: ThreadKey) {
        saveTask?.cancel()
        saveTask = nil
        guard expanded, store.isMe(k.account), !adoptingDraft, store.pendingSend?.threadKey != k else { return }
        store.saveReplyDraft(k, currentDraft(k))
        rememberExtras(k)
    }

    private func rememberExtras(_ key: ThreadKey? = nil) {
        let k = key ?? detail.key
        guard expanded else { return }
        ComposerSession.extras[k] = ComposerSession.Extras(from: from, attachments: attachments, showCc: showCc, showBcc: showBcc,
                                                           rich: rich.attributed.length > 0 ? rich.attributed : nil, remind: remind)
    }

    /// Как в Spark: ответ уходит в своё окно, черновик остаётся тем же. Если окно с тредом уже есть, оно получает ответ.
    private func popOut() {
        let k = detail.key
        flush(k)
        ReaderPending.reply[k] = mode
        expanded = false
        openWindow(id: Reader.windowID, value: k)
    }

    /// Свернуть: текст остаётся черновиком. Пустой ответ без черновика в Gmail просто забывается.
    private func collapse() {
        let k = detail.key
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        if empty && (store.replyDrafts[k]?.gmailDraftID ?? adoptedDraftID) == nil {
            saveTask?.cancel()
            store.discardReplyDraft(k)
            ComposerSession.extras[k] = nil
            resetFields()
            return
        }
        flush(k)
        expanded = false
    }

    private func discard() {
        let k = detail.key
        saveTask?.cancel()
        if store.replyDrafts[k] == nil, let id = adoptedDraftID {
            // черновик из Gmail ещё не записан у нас: удаляем напрямую
            let c = store.client(k.account)
            Task { try? await c.deleteDraft(id: id); await store.loadDetail(k) }
        }
        store.discardReplyDraft(k)
        ComposerSession.extras[k] = nil
        resetFields()
    }

    // MARK: Открытие и режимы

    private func handleReplyRequest() {
        guard let r = ui.replyRequest, ComposeBus.shared.handledReplyNonce != r.nonce else { return }
        ComposeBus.shared.handledReplyNonce = r.nonce
        guard canReply, pendingHere == nil else { return }
        open(r.mode, messageID: r.messageID)
    }

    /// id письма из просьбы ответить, если просьба его несёт (поле messageID в UIState.replyRequest).

    /// Что редактор подставляет сам для режима и письма.
    private func autofill(_ m: ReplyMode) -> (to: String, cc: String, subject: String) {
        guard let t = target else { return ("", "", detail.subject) }
        let base = t.subject.isEmpty ? detail.subject : t.subject
        switch m {
        case .reply, .replyAll:
            let primary: [Person]
            if store.isMe(t.from.email) { primary = t.to } else { primary = t.replyTo.isEmpty ? [t.from] : t.replyTo }
            let prim = Recipients.dedupe(primary.filter { !store.isMe($0.email) || store.isMe(t.from.email) })
            var others: [Person] = []
            if m == .replyAll {
                let primSet = Set(prim.map { Person.normalized($0.email) })
                others = Recipients.dedupe((t.to + t.cc).filter { p in
                    !store.isMe(p.email) && !primSet.contains(Person.normalized(p.email))
                })
            }
            let subj = base.lowercased().hasPrefix("re:") ? base : "Re: " + base
            return (Recipients.join(prim), Recipients.join(others), subj)
        case .forward:
            let subj = base.lowercased().hasPrefix("fwd:") ? base : "Fwd: " + base
            return ("", "", subj)
        }
    }

    /// Открыть редактор по кнопке или клавише. Уже начатый ответ того же режима не трогается.
    private func open(_ m: ReplyMode, messageID: String? = nil) {
        openedByHand = true
        if let messageID, messageID != targetID, sent.contains(where: { $0.id == messageID }) {
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !expanded || !hasText {
                targetID = messageID
                // письмо другое: подставленные адреса считаются заново
                applyAutofill(m, force: !hasText)
                mode = m
                expanded = true
                focusEditor()
                return
            }
            targetID = messageID
        }
        if expanded, m == mode {
            focusEditor()
            return
        }
        if !expanded && to.isEmpty && cc.isEmpty && text.isEmpty {
            applyAutofill(m, force: true)
            mode = m
            expanded = true
            focusEditor()
            return
        }
        switchMode(m)
        expanded = true
        focusEditor()
    }

    /// Смена режима переписывает только то, что пользователь не трогал.
    private func switchMode(_ m: ReplyMode) {
        guard m != mode || !expanded else { return }
        applyAutofill(m, force: false)
        mode = m
    }

    private func applyAutofill(_ m: ReplyMode, force: Bool) {
        let a = autofill(m)
        if force || to == autoTo { to = a.to }
        if force || cc == autoCc { cc = a.cc }
        if force || subject == autoSubject || subject.isEmpty { subject = a.subject }
        autoTo = a.to; autoCc = a.cc; autoSubject = a.subject
    }

    private func focusEditor() {
        knownTargetID = target?.id
        focusLater(mode == .forward && to.isEmpty ? .to : .body)
    }

    /// Фокус ставится на следующем такте: поле должно уже появиться на экране.
    private func focusLater(_ f: ComposeField) {
        DispatchQueue.main.async {
            if f == .body {
                rich.focus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { if !bodyFocused { rich.focus() } }
                return
            }
            focus = f
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { if focus != f { focus = f } }
        }
    }

    private func insertTemplate(_ t: MailTemplate, trigger: Bool) {
        templatePicker = false
        if !expanded { open(.reply) }
        let body = TemplateStore.render(t, to: to)
        DispatchQueue.main.async { rich.insert(body, replacingTrigger: trigger ? ";;" : nil) }
    }

    private func addFile(_ url: URL) {
        guard ComposeAttachmentChips.isRegularFile(url), !attachments.contains(url) else { return }
        if !expanded { open(.reply) }
        attachments.append(url)
    }

    private func consumePending() {
        guard let p = agent.pendingInsert, p.thread == nil || p.thread == detail.key, canReply else { return }
        if !expanded { open(.reply) }
        undoText = text.isEmpty ? nil : text
        text = editable(p.text)
        agent.pendingInsert = nil
    }

    /// Кнопка Send в панели: текст Револта уходит ответом всем, через ту же отправку с паузой на Undo.
    /// Начатый руками ответ не затирается: тогда письмо остаётся карточкой в панели.
    private func consumeAutoSend() {
        guard let p = agent.autoSendRequest, p.thread == detail.key else { return }
        agent.autoSendRequest = nil
        let own = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard canReply, pendingHere == nil, !own else {
            store.error = own && pendingHere == nil
                ? "Not sent: you have an unfinished reply in this email. Use Insert into reply."
                : "Not sent: this email can't be answered right now. Use Insert into reply."
            return
        }
        targetID = nil
        open(.replyAll)
        text = editable(p.text)
        // адреса и текст уже в полях; сама отправка следующим тиком, когда состояние применится
        DispatchQueue.main.async { send(minDelay: 10) }
    }

    private func askAgentForReply() {
        settings.showAgentPanel = true
        let chatID = agent.chats(for: detail.key).first?.id
        let ask = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Напиши ответ на последнее письмо в этом треде."
            : "Улучши мой черновик ответа, смысл не меняй:\n\n\(text)"
        agent.send(ask, chatID: chatID, thread: detail, account: detail.account)
        if !expanded { open(.reply) }
    }

    private func translateDraft(to lang: String) {
        translating = true
        let original = text
        Task {
            do {
                let out = try await Translator.translateText(original, to: lang)
                undoText = original
                text = out
            } catch {
                store.error = error.localizedDescription
            }
            translating = false
        }
    }

    // MARK: Отправка

    private func saveDraftNow() async {
        let k = detail.key
        flush(k)
        savingDraft = true
        defer { savingDraft = false }
        let replyTarget = mode == .forward ? nil : target
        do {
            try await store.composeSend(account: detail.account, to: Person.parseList(to), cc: Person.parseList(cc), bcc: Person.parseList(bcc),
                                 subject: subject, body: outgoingBody(), replyTo: replyTarget, threadID: detail.id, draftOnly: true,
                                 attachments: attachments, forwardFrom: mode == .forward ? target : nil, from: from,
                                 draftID: store.replyDrafts[k]?.gmailDraftID ?? adoptedDraftID)
            if detail.key == k { savedNote = true }
        } catch {
            store.error = error.localizedDescription
        }
    }

    /// Отправка с паузой: письмо уходит через несколько секунд, плашка над редактором даёт Undo.
    private func send(minDelay: Double = 0) {
        let k = detail.key
        let bad = Recipients.invalid([to, cc, bcc])
        if let b = bad.first {
            store.error = "Check the address: \(b)"
            return
        }
        flush(k)
        let replyTarget = mode == .forward ? nil : target
        let toList = Recipients.dedupe(Person.parseList(to))
        let toSet = Set(toList.map { Person.normalized($0.email) })
        let ccList = Recipients.dedupe(Person.parseList(cc)).filter { !toSet.contains(Person.normalized($0.email)) }
        let ccSet = toSet.union(ccList.map { Person.normalized($0.email) })
        let bccList = Recipients.dedupe(Person.parseList(bcc)).filter { !ccSet.contains(Person.normalized($0.email)) }
        do {
            try store.composeSendWithUndo(account: detail.account, to: toList, cc: ccList, bcc: bccList,
                                          subject: subject, body: outgoingBody(), replyTo: replyTarget, threadID: detail.id,
                                          attachments: attachments, forwardFrom: mode == .forward ? target : nil, from: from,
                                          draftID: store.replyDrafts[k]?.gmailDraftID ?? adoptedDraftID, minDelay: minDelay)
            if remind {
                FollowUpStore.shared.add(account: detail.account, threadID: detail.id, subject: subject,
                                         recipient: (toList + ccList).first?.email ?? "")
            }
            ComposerSession.extras[k] = ComposerSession.Extras(from: from, attachments: attachments, showCc: showCc, showBcc: showBcc,
                                                               rich: rich.attributed, remind: remind)
            resetFields()
        } catch {
            store.error = error.localizedDescription
        }
    }

    /// Поставить ответ в очередь «Send later»: редактор закрывается, черновик треда убирается.
    private func scheduleSend(at date: Date) {
        let k = detail.key
        if let b = Recipients.invalid([to, cc, bcc]).first {
            store.error = "Check the address: \(b)"
            return
        }
        let toList = Recipients.dedupe(Person.parseList(to))
        let toSet = Set(toList.map { Person.normalized($0.email) })
        let ccList = Recipients.dedupe(Person.parseList(cc)).filter { !toSet.contains(Person.normalized($0.email)) }
        let ccSet = toSet.union(ccList.map { Person.normalized($0.email) })
        let bccList = Recipients.dedupe(Person.parseList(bcc)).filter { !ccSet.contains(Person.normalized($0.email)) }
        let body = outgoingBody()
        let mail = ScheduledMail(account: detail.account, to: toList, cc: ccList, bcc: bccList, subject: subject,
                                 body: body.plain, bodyHTML: body.html, editorText: text,
                                 replyTo: mode == .forward ? nil : target, threadID: detail.id, attachmentPaths: [],
                                 forwardFrom: mode == .forward ? target : nil, from: from, mode: mode.rawValue,
                                 sendAt: date, remind: remind)
        ScheduledSendStore.shared.schedule(mail, files: attachments)
        saveTask?.cancel()
        // черновик в Gmail убираем: иначе его можно отправить второй раз с телефона
        if store.replyDrafts[k] == nil, let id = adoptedDraftID {
            let c = store.client(k.account)
            Task { try? await c.deleteDraft(id: id); await store.loadDetail(k) }
        }
        store.discardReplyDraft(k)
        ComposerSession.extras[k] = nil
        resetFields()
    }

    /// Вернуть запланированный ответ в редактор: из очереди он убирается.
    private func editScheduled(_ m: ScheduledMail) {
        guard let k = m.threadKey, let back = ScheduledSendStore.shared.cancel(m.id, deleteFiles: false) else { return }
        let mode = ReplyMode(rawValue: back.mode) ?? .reply
        store.saveReplyDraft(k, ReplyDraft(mode: mode.rawValue, to: Recipients.join(back.to), cc: Recipients.join(back.cc),
                                           bcc: Recipients.join(back.bcc), subject: back.subject, text: back.editorText,
                                           gmailDraftID: nil, replyToMessageID: (back.forwardFrom ?? back.replyTo)?.id))
        ComposerSession.extras[k] = ComposerSession.Extras(from: back.from, attachments: back.attachments,
                                                           showCc: !back.cc.isEmpty, showBcc: !back.bcc.isEmpty, remind: back.remind)
        load()
        expanded = true
        focusEditor()
    }
}

// MARK: Новое письмо

/// Новое письмо в отдельном окне-листе. Сохраняется черновиком в Gmail само, Esc спрашивает, что делать с текстом.
struct NewMessageView: View {
    @Environment(MailStore.self) private var store
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    /// Выбранный адрес отправки: «ящик|адрес».
    @State private var fromKey = ""
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var showBcc = false
    @State private var subject = ""
    @State private var text = ""
    @State private var attachments: [URL] = []
    @State private var translating = false
    @State private var agentBusy = false
    @State private var agentAsk = ""
    @State private var picking = false
    @State private var dropTargeted = false
    @State private var confirmClose = false
    @State private var failure: String?
    @State private var savedNote = false
    @FocusState private var focus: ComposeField?
    /// Черновик в Gmail, который ведёт это окно, и ящик, где он лежит.
    @State private var draftID: String?
    @State private var draftAccount: String?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var inFlightSave: Task<Void, Never>?
    @State private var closing = false
    @State private var rich = RichTextController()
    @State private var editorHeight: CGFloat = 240
    @State private var bodyFocused = false
    @State private var remind = false
    @State private var templatePicker = false

    private struct FromOption: Hashable { var account: String; var person: Person; var key: String { account + "|" + person.email } }

    private var fromOptions: [FromOption] {
        store.accounts.flatMap { acc -> [FromOption] in
            let list = store.aliases[acc.email] ?? []
            let people = list.isEmpty ? [store.me(acc.email)] : list
            return people.map { FromOption(account: acc.email, person: $0) }
        }
    }

    private var selectedFrom: FromOption? {
        fromOptions.first { $0.key == fromKey }
            ?? fromKey.split(separator: "|", maxSplits: 1).first.map(String.init).flatMap { acc in
                store.accounts.contains { $0.email == acc } ? FromOption(account: acc, person: store.me(acc)) : nil
            }
    }

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !subject.trimmingCharacters(in: .whitespaces).isEmpty
            || !to.trimmingCharacters(in: .whitespaces).isEmpty
            || !attachments.isEmpty
    }

    private var snapshot: String { [fromKey, to, cc, bcc, subject, text].joined(separator: "\u{1}") }

    private var canSend: Bool {
        !closing && selectedFrom != nil && !(Person.parseList(to) + Person.parseList(cc) + Person.parseList(bcc)).isEmpty
    }

    /// Текст письма: с оформлением, если строка редактора та же.
    private func outgoingBody() -> ComposeBody {
        attributedRaw(rich.attributed) == text ? ComposeBody(plain: rich.plain, html: rich.html) : ComposeBody(plain: text, html: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("New email").font(.g(15, .semibold))
                Spacer()
                if savedNote { Text("Draft saved").font(.g(11.5)).foregroundStyle(Theme.faint) }
            }
            HStack {
                Text("From").font(.g(12)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                Picker("", selection: $fromKey) {
                    ForEach(fromOptions, id: \.key) { o in Text(o.person.full).tag(o.key) }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                RecipientField(title: "To", text: $to, field: .to, focus: $focus)
                Divider()
                RecipientField(title: "Cc", text: $cc, field: .cc, focus: $focus)
                if showBcc || !bcc.isEmpty {
                    Divider()
                    RecipientField(title: "Bcc", text: $bcc, field: .bcc, focus: $focus)
                }
                Divider()
                HStack {
                    Text("Subject").font(.g(12)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                    TextField("", text: $subject).textFieldStyle(.plain).focused($focus, equals: .subject)
                }
                .padding(.vertical, 2)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.white))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.ink.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                FormatBar(controller: rich)
                ZStack(alignment: .topLeading) {
                    RichTextEditor(text: $text, controller: rich, minHeight: 240, maxHeight: 420, height: $editorHeight,
                                   onAttach: { url in
                                       if ComposeAttachmentChips.isRegularFile(url), !attachments.contains(url) { attachments.append(url) }
                                   },
                                   onSubmit: { if canSend { Task { await send() } } },
                                   onFocusChange: { f in bodyFocused = f },
                                   onTrigger: { templatePicker = true })
                        .frame(height: editorHeight)
                    if text.isEmpty {
                        Text("Write your email  (;; for templates)").font(.g(13.5)).foregroundStyle(Theme.faint)
                            .padding(.leading, 5).padding(.top, 4).allowsHitTesting(false)
                    }
                }
                .popover(isPresented: $templatePicker, arrowEdge: .bottom) {
                    TemplatePicker(onPick: { t in insertTemplate(t, trigger: true) }, onCancel: { templatePicker = false; rich.focus() })
                }
            }
            .padding(6)
            .background(Theme.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(dropTargeted ? Theme.accent : Theme.ink.opacity(0.1), lineWidth: dropTargeted ? 2 : 1))
            if let o = selectedFrom, let block = ComposeSignature.block(store.signature(for: o.person.email) ?? store.signature(for: o.account)) {
                Text(block).font(.g(11.5)).foregroundStyle(Theme.faint).lineLimit(5)
                    .help("Your signature is added when the email is sent")
            }
            ComposeAttachmentChips(files: $attachments)
            remindToggle($remind)
            HStack {
                TextField("Ask the agent what to write", text: $agentAsk)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await draftWithAgent() } }
                Button { Task { await draftWithAgent() } } label: {
                    if agentBusy { ProgressView().controlSize(.small) } else { Label("Write", systemImage: "sparkle") }
                }.disabled(agentAsk.isEmpty || agentBusy)
            }
            if let failure {
                Text(failure).font(.g(12)).foregroundStyle(Theme.accentText).lineLimit(2)
            }
            HStack {
                Menu("Translate") {
                    ForEach(AppSettings.languages, id: \.self) { lang in
                        Button(lang) {
                            translating = true
                            Task {
                                if let out = try? await Translator.translateText(text, to: lang) { text = out }
                                translating = false
                            }
                        }
                    }
                }.fixedSize().disabled(text.isEmpty || translating)
                if translating { ProgressView().controlSize(.small) }
                Button { picking = true } label: { Label("Attach", systemImage: "paperclip") }
                    .help("Attach files (or drop or paste them on the text)")
                TemplatesMenu(currentText: { text }, insert: { insertTemplate($0, trigger: false) })
                if !showBcc && bcc.isEmpty { Button("Bcc") { showBcc = true; focusLater(.bcc) }.buttonStyle(.link).font(.g(12)) }
                Spacer()
                Button("Cancel") { requestClose() }.keyboardShortcut(.cancelAction)
                Button("Save draft") { Task { await saveDraftAndClose() } }.disabled(closing)
                Button("Send") { Task { await send() } }
                    // Cmd+Enter только из полей письма
                    .keyboardShortcut(focus != nil || bodyFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .buttonStyle(.dashPrimary)
                    .disabled(!canSend)
                    .help("Send (Cmd+Enter)")
                SendLaterMenu(enabled: canSend) { d in Task { await scheduleSend(at: d) } }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(18)
        .frame(width: 640)
        .interactiveDismissDisabled(hasContent)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            ComposeAttachmentChips.load(providers) { url in
                if ComposeAttachmentChips.isRegularFile(url), !attachments.contains(url) { attachments.append(url) }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for u in urls where !attachments.contains(u) { attachments.append(u) }
            }
        }
        .confirmationDialog("Keep this email?", isPresented: $confirmClose) {
            Button("Save draft") { Task { await saveDraftAndClose() } }
            Button("Discard", role: .destructive) { Task { await discardAndClose() } }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Save it to Drafts to finish later, or discard it.")
        }
        .onChange(of: snapshot) { _, _ in scheduleAutosave() }
        .onChange(of: ComposeBus.shared.restoreScheduled?.id) { _, _ in
            // окно уже открыто: запланированное письмо подставляется, если в окне пусто
            guard let m = ComposeBus.shared.restoreScheduled, !hasContent else { return }
            ComposeBus.shared.restoreScheduled = nil
            restore(m)
        }
        .onAppear {
            ScheduledSendStore.shared.start(store: store)
            FollowUpStore.shared.start(store: store)
            let acc = store.mailbox.account ?? store.accounts.first?.email ?? ""
            fromKey = acc + "|" + store.defaultFrom(account: acc).email
            if selectedFrom == nil || !fromOptions.contains(where: { $0.key == fromKey }) {
                fromKey = fromOptions.first { $0.account == acc }?.key ?? fromOptions.first?.key ?? fromKey
            }
            if let p = ComposeBus.shared.restoreNew {
                ComposeBus.shared.restoreNew = nil
                restore(p)
            } else if let m = ComposeBus.shared.restoreScheduled {
                ComposeBus.shared.restoreScheduled = nil
                restore(m)
            } else if let p = ui.newMessagePrefill {
                to = p.to; subject = p.subject; text = p.body
                ui.newMessagePrefill = nil
            }
            focusLater(to.isEmpty ? .to : .body)
        }
        .onDisappear {
            // окно закрыли не кнопкой: текст не теряется, остаётся черновиком
            if !closing, hasContent { Task { await autosave(force: true) } }
            autosaveTask?.cancel()
        }
    }

    private func restore(_ p: MailStore.PendingSend) {
        if let f = p.from {
            let key = p.account + "|" + f.email
            fromKey = fromOptions.contains { $0.key == key } ? key : (p.account + "|" + store.me(p.account).email)
        } else {
            fromKey = p.account + "|" + store.defaultFrom(account: p.account).email
        }
        to = Recipients.join(p.to)
        cc = Recipients.join(p.cc)
        bcc = Recipients.join(p.bcc)
        showBcc = !p.bcc.isEmpty
        subject = p.subject
        text = p.body
        attachments = p.attachments
        draftID = p.draftID
        draftAccount = p.draftID == nil ? nil : p.account
    }

    private func restore(_ m: ScheduledMail) {
        let key = m.account + "|" + (m.from?.email ?? store.defaultFrom(account: m.account).email)
        fromKey = fromOptions.contains { $0.key == key } ? key : (m.account + "|" + store.me(m.account).email)
        to = Recipients.join(m.to)
        cc = Recipients.join(m.cc)
        bcc = Recipients.join(m.bcc)
        showBcc = !m.bcc.isEmpty
        subject = m.subject
        text = m.editorText
        attachments = m.attachments
        remind = m.remind
    }

    private func focusLater(_ f: ComposeField) {
        DispatchQueue.main.async {
            if f == .body {
                rich.focus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { if !bodyFocused { rich.focus() } }
                return
            }
            focus = f
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { if focus != f { focus = f } }
        }
    }

    private func insertTemplate(_ t: MailTemplate, trigger: Bool) {
        templatePicker = false
        let body = TemplateStore.render(t, to: to)
        DispatchQueue.main.async { rich.insert(body, replacingTrigger: trigger ? ";;" : nil) }
    }

    private func requestClose() {
        if hasContent {
            confirmClose = true
        } else {
            Task { await discardAndClose() }
        }
    }

    // MARK: Черновик

    private func scheduleAutosave() {
        savedNote = false
        guard !closing else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await autosave(force: false)
        }
    }

    /// Окно ведёт один черновик в Gmail и обновляет его на месте. Сохранение не прерывается отменой,
    /// иначе черновик создастся в Gmail, а его id потеряется.
    private func autosave(force: Bool) async {
        await inFlightSave?.value
        guard force || !closing else { return }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !subject.trimmingCharacters(in: .whitespaces).isEmpty
        guard hasText, let o = selectedFrom, store.isOnline else { return }
        let raw = MIMEBuilder.build(from: o.person, to: Person.parseList(to), cc: Person.parseList(cc), bcc: Person.parseList(bcc),
                                    subject: subject, body: outgoingBody().plain, inReplyTo: nil, quoteOriginal: false,
                                    signatureHTML: store.signature(for: o.person.email) ?? store.signature(for: o.account))
        let oldID = draftID, oldAccount = draftAccount
        let task = Task {
            do {
                // сменили ящик «От»: черновик переезжает, старый удаляется
                if let oldID, let oldAccount, oldAccount != o.account {
                    try? await store.client(oldAccount).deleteDraft(id: oldID)
                    draftID = nil; draftAccount = nil
                }
                let id = try await store.client(o.account).saveDraft(raw: raw, threadID: nil, draftID: draftAccount == o.account ? draftID : nil)
                draftID = id
                draftAccount = o.account
                savedNote = true
            } catch {
                AppLog.write("new email autosave: \(error.localizedDescription)")
            }
        }
        inFlightSave = task
        await task.value
    }

    private func stopAutosave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await inFlightSave?.value
    }

    private func saveDraftAndClose() async {
        guard let o = selectedFrom else { return }
        closing = true
        await stopAutosave()
        do {
            let id = try await store.composeSend(account: o.account, to: Person.parseList(to), cc: Person.parseList(cc), bcc: Person.parseList(bcc),
                                          subject: subject, body: outgoingBody(), replyTo: nil, threadID: nil, draftOnly: true,
                                          attachments: attachments, from: o.person,
                                          draftID: draftAccount == o.account ? draftID : nil)
            if let draftID, let draftAccount, draftAccount != o.account {
                try? await store.client(draftAccount).deleteDraft(id: draftID)
            }
            self.draftID = id
            dismiss()
        } catch {
            closing = false
            failure = error.localizedDescription
        }
    }

    private func discardAndClose() async {
        closing = true
        await stopAutosave()
        if let draftID, let draftAccount {
            try? await store.client(draftAccount).deleteDraft(id: draftID)
            self.draftID = nil
        }
        dismiss()
    }

    private func draftWithAgent() async {
        agentBusy = true
        defer { agentBusy = false }
        let prompt = """
        Write an email body. Request from the sender: \(agentAsk)
        Recipient: \(to). Subject: \(subject).
        Existing draft (may be empty): \(text)
        Write in the language of the request unless the recipient clearly needs another. Short, human, paragraphs separated by blank lines, no em dashes, no subject line. Output only the email body.
        """
        do { text = try await ClaudeProcess.oneShot(prompt: prompt, model: "sonnet") } catch { store.error = error.localizedDescription }
    }

    /// Отправка с паузой (Undo на плашке внизу окна). Черновик окна удаляется, когда письмо уйдёт.
    private func send() async {
        guard let o = selectedFrom else { return }
        if let b = Recipients.invalid([to, cc, bcc]).first {
            failure = "Check the address: \(b)"
            return
        }
        closing = true
        await stopAutosave()
        var dID = draftAccount == o.account ? draftID : nil
        if let draftID, let draftAccount, draftAccount != o.account {
            try? await store.client(draftAccount).deleteDraft(id: draftID)
            dID = nil
        }
        let toList = Recipients.dedupe(Person.parseList(to))
        let toSet = Set(toList.map { Person.normalized($0.email) })
        let ccList = Recipients.dedupe(Person.parseList(cc)).filter { !toSet.contains(Person.normalized($0.email)) }
        let ccSet = toSet.union(ccList.map { Person.normalized($0.email) })
        let bccList = Recipients.dedupe(Person.parseList(bcc)).filter { !ccSet.contains(Person.normalized($0.email)) }
        do {
            try store.composeSendWithUndo(account: o.account, to: toList, cc: ccList, bcc: bccList,
                                          subject: subject, body: outgoingBody(), replyTo: nil, threadID: nil,
                                          attachments: attachments, from: o.person, draftID: dID)
            if remind {
                FollowUpStore.shared.add(account: o.account, threadID: nil, subject: subject,
                                         recipient: (toList + ccList + bccList).first?.email ?? "")
            }
            dismiss()
        } catch {
            closing = false
            failure = error.localizedDescription
        }
    }

    /// «Send later»: письмо уходит в очередь этого Mac, черновик окна удаляется, окно закрывается.
    private func scheduleSend(at date: Date) async {
        guard let o = selectedFrom else { return }
        if let b = Recipients.invalid([to, cc, bcc]).first {
            failure = "Check the address: \(b)"
            return
        }
        closing = true
        await stopAutosave()
        let toList = Recipients.dedupe(Person.parseList(to))
        let toSet = Set(toList.map { Person.normalized($0.email) })
        let ccList = Recipients.dedupe(Person.parseList(cc)).filter { !toSet.contains(Person.normalized($0.email)) }
        let ccSet = toSet.union(ccList.map { Person.normalized($0.email) })
        let bccList = Recipients.dedupe(Person.parseList(bcc)).filter { !ccSet.contains(Person.normalized($0.email)) }
        let body = outgoingBody()
        let mail = ScheduledMail(account: o.account, to: toList, cc: ccList, bcc: bccList, subject: subject,
                                 body: body.plain, bodyHTML: body.html, editorText: text, replyTo: nil, threadID: nil,
                                 attachmentPaths: [], forwardFrom: nil, from: o.person, mode: ReplyMode.reply.rawValue,
                                 sendAt: date, remind: remind)
        ScheduledSendStore.shared.schedule(mail, files: attachments)
        if let draftID, let draftAccount {
            try? await store.client(draftAccount).deleteDraft(id: draftID)
            self.draftID = nil
        }
        dismiss()
    }
}
