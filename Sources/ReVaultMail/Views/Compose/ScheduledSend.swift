import AppKit
import SwiftUI

/// Письмо, отложенное на потом. Gmail API отложенной отправки не умеет, поэтому очередь живёт на этом Mac.
struct ScheduledMail: Codable, Identifiable, Hashable {
    var id = UUID()
    var account: String
    var to: [Person]
    var cc: [Person]
    var bcc: [Person]
    var subject: String
    var body: String
    var bodyHTML: String?
    /// Тот же текст редактора без оформления: им письмо возвращается в редактор по Edit.
    var editorText: String
    var replyTo: MailMessage?
    var threadID: String?
    /// Копии файлов в Application Support/scheduled-files/<id>/: оригиналы могут исчезнуть до отправки.
    var attachmentPaths: [String]
    var forwardFrom: MailMessage?
    var from: Person?
    var mode: String
    var sendAt: Date
    var remind: Bool
    var remindDays: Int = 3
    var attempts: Int = 0
    var nextTry: Date?
    var lastError: String?

    var threadKey: ThreadKey? { threadID.map { ThreadKey(account: account, threadID: $0) } }
    var attachments: [URL] { attachmentPaths.map { URL(fileURLWithPath: $0) } }
    var title: String { "To \(to.first?.short ?? cc.first?.short ?? bcc.first?.short ?? "recipients")" }
    var failed: Bool { attempts >= ScheduledSendStore.maxAttempts }
}

/// Очередь «Send later»: scheduled.json, проверка каждые 30 секунд и при запуске, отправка через MailStore.
@Observable
@MainActor
final class ScheduledSendStore {
    static let shared = ScheduledSendStore()
    nonisolated static let maxAttempts = 5
    private static let url = AppPaths.file("scheduled.json")
    private static let filesDir: URL = {
        let d = AppPaths.support.appendingPathComponent("scheduled-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private(set) var items: [ScheduledMail] = []
    @ObservationIgnored private weak var store: MailStore?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var inFlight = Set<UUID>()

    private init() {
        items = JSONFile.load([ScheduledMail].self, from: Self.url) ?? []
    }

    /// Запуск проверки. Повторный вызов ничего не делает.
    func start(store: MailStore) {
        self.store = store
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // при запуске ждём, пока поднимутся ящики
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                self?.checkDue()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func items(for key: ThreadKey) -> [ScheduledMail] {
        items.filter { $0.threadKey == key }.sorted { $0.sendAt < $1.sendAt }
    }

    @discardableResult
    func schedule(_ mail: ScheduledMail, files: [URL]) -> ScheduledMail {
        var m = mail
        let dir = Self.filesDir.appendingPathComponent(m.id.uuidString, isDirectory: true)
        var paths: [String] = []
        if !files.isEmpty { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for f in files {
            let scoped = f.startAccessingSecurityScopedResource()
            defer { if scoped { f.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(f.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: f, to: dest)) != nil { paths.append(dest.path) } else { paths.append(f.path) }
        }
        m.attachmentPaths = paths
        var list = items
        list.append(m)
        items = list
        persist()
        return m
    }

    /// Убрать из очереди. deleteFiles=false, когда письмо возвращается в редактор (файлы нужны ему).
    @discardableResult
    func cancel(_ id: UUID, deleteFiles: Bool = true) -> ScheduledMail? {
        let list = items
        guard let m = list.first(where: { $0.id == id }) else { return nil }
        items = list.filter { $0.id != id }
        persist()
        if deleteFiles { try? FileManager.default.removeItem(at: Self.filesDir.appendingPathComponent(id.uuidString)) }
        return m
    }

    func reschedule(_ id: UUID, to date: Date) {
        var list = items
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].sendAt = date
        list[i].attempts = 0
        list[i].nextTry = nil
        list[i].lastError = nil
        items = list
        persist()
    }

    func sendNow(_ id: UUID) {
        reschedule(id, to: Date())
        checkDue()
    }

    /// Пора: письмо уходит. Ошибка повторяется с паузой, после пяти попыток письмо ждёт человека.
    func checkDue() {
        guard let store, store.isOnline else { return }
        let now = Date()
        let due = items.filter { m in
            m.sendAt <= now && !m.failed && !inFlight.contains(m.id) && (m.nextTry.map { $0 <= now } ?? true)
        }
        for m in due {
            inFlight.insert(m.id)
            Task {
                defer { self.inFlight.remove(m.id) }
                // send() убирает черновик треда: новый ответ, начатый в том же треде после планирования, не трогаем
                let key = m.threadKey
                let keptDraft = key.flatMap { store.replyDrafts[$0] }
                if let key, keptDraft != nil { store.replyDrafts[key] = nil }
                @MainActor func putBack() {
                    if let key, let d = keptDraft, store.replyDrafts[key] == nil { store.saveReplyDraft(key, d) }
                }
                do {
                    try await store.composeSend(account: m.account, to: m.to, cc: m.cc, bcc: m.bcc, subject: m.subject,
                                                body: ComposeBody(plain: m.body, html: m.bodyHTML),
                                                replyTo: m.replyTo, threadID: m.threadID, attachments: m.attachments,
                                                forwardFrom: m.forwardFrom, from: m.from)
                    putBack()
                    self.cancel(m.id)
                    if m.remind {
                        FollowUpStore.shared.add(account: m.account, threadID: m.threadID, subject: m.subject,
                                                 recipient: (m.to + m.cc).first?.email ?? "", days: m.remindDays)
                    }
                    AppLog.write("scheduled send ok \(m.id)")
                } catch {
                    putBack()
                    self.markFailure(m.id, error.localizedDescription)
                }
            }
        }
    }

    private func markFailure(_ id: UUID, _ message: String) {
        var list = items
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].attempts += 1
        list[i].lastError = message
        list[i].nextTry = Date().addingTimeInterval(TimeInterval(120 * list[i].attempts))
        let failed = list[i].failed
        let title = list[i].title
        items = list
        persist()
        AppLog.write("scheduled send failed \(id): \(message)")
        if failed { store?.error = "Scheduled email \(title.lowercased()) was not sent: \(message)" }
    }

    private func persist() {
        let snapshot = items
        JSONFile.save(snapshot, to: Self.url)
    }

    // MARK: Время

    static func inOneHour(from now: Date = Date()) -> Date { now.addingTimeInterval(3600) }

    static func tomorrowMorning(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        return cal.date(byAdding: DateComponents(day: 1, hour: 8), to: start) ?? now.addingTimeInterval(86400)
    }

    static func nextMonday(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.weekday = 2
        comps.hour = 8
        comps.minute = 0
        return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? now.addingTimeInterval(7 * 86400)
    }

    static func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        let cal = Calendar.current
        if cal.isDateInToday(d) { f.dateFormat = "'today' HH:mm" }
        else if cal.isDateInTomorrow(d) { f.dateFormat = "'tomorrow' HH:mm" }
        else { f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEE, MMM d, HH:mm" : "EEE, MMM d yyyy, HH:mm" }
        return f.string(from: d)
    }
}

/// Шеврон рядом с Send: пресеты времени, своё время и список запланированного.
struct SendLaterMenu: View {
    let enabled: Bool
    let schedule: (Date) -> Void
    @State private var custom = false
    @State private var showList = false

    var body: some View {
        let count = ScheduledSendStore.shared.items.count
        Menu {
            Section("Send later (sends from this Mac)") {
                Button("In 1 hour") { schedule(ScheduledSendStore.inOneHour()) }.disabled(!enabled)
                Button("Tomorrow 08:00") { schedule(ScheduledSendStore.tomorrowMorning()) }.disabled(!enabled)
                Button("Monday 08:00") { schedule(ScheduledSendStore.nextMonday()) }.disabled(!enabled)
                Button("Custom date…") { custom = true }.disabled(!enabled)
            }
            Divider()
            Button(count == 0 ? "Scheduled" : "Scheduled (\(count))…") { showList = true }
        } label: {
            Image(systemName: "clock")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Send later. Scheduled emails send from this Mac while Re:Vault Mail is open.")
        .sheet(isPresented: $custom) {
            ScheduleCustomSheet { d in schedule(d) }
        }
        .popover(isPresented: $showList, arrowEdge: .bottom) { ScheduledListView() }
    }
}

/// Своё время отправки.
struct ScheduleCustomSheet: View {
    let onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = ScheduledSendStore.tomorrowMorning()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send later").font(.g(15, .semibold))
            DatePicker("", selection: $date, in: Date().addingTimeInterval(60)..., displayedComponents: [.date])
                .datePickerStyle(.graphical).labelsHidden()
            DatePicker("Time", selection: $date, displayedComponents: [.hourAndMinute])
            Text("Sends from this Mac. Re:Vault Mail has to be open at that time, otherwise it sends when you open it next.")
                .font(.g(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Schedule") { onPick(max(date, Date().addingTimeInterval(30))); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.dashPrimary)
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}

/// Список запланированного: время, кому, тема; отправить сейчас или отменить.
struct ScheduledListView: View {
    @Environment(MailStore.self) private var store
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let list = ScheduledSendStore.shared.items.sorted { $0.sendAt < $1.sendAt }
        VStack(alignment: .leading, spacing: 8) {
            Text("Scheduled").font(.g(14, .semibold))
            if list.isEmpty {
                Text("Nothing scheduled.").font(.g(12.5)).foregroundStyle(Theme.muted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(list) { m in row(m) }
                    }
                }
                .frame(maxHeight: 320)
            }
            Text("Sends from this Mac while Re:Vault Mail is open.").font(.g(11)).foregroundStyle(Theme.faint)
        }
        .padding(12)
        .frame(width: 380)
    }

    private func row(_ m: ScheduledMail) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.g(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(m.subject.isEmpty ? "(no subject)" : m.subject).font(.g(12)).foregroundStyle(Theme.muted).lineLimit(1)
                if m.failed, let e = m.lastError {
                    Text("Not sent: \(e)").font(.g(11)).foregroundStyle(Theme.accentText).lineLimit(2)
                } else {
                    Text(ScheduledSendStore.label(m.sendAt)).font(.g(11.5)).foregroundStyle(Theme.faint)
                }
            }
            Spacer()
            Button("Edit") { edit(m) }.buttonStyle(.link).font(.g(12))
                .help(m.threadKey == nil ? "Open it in a new email window" : "Open the conversation; edit it from the reply banner")
            Button(m.failed ? "Retry" : "Send now") { ScheduledSendStore.shared.sendNow(m.id) }.buttonStyle(.link).font(.g(12))
            Button("Cancel") { ScheduledSendStore.shared.cancel(m.id) }.buttonStyle(.link).font(.g(12))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.hover))
    }

    /// Ответ правится в своём треде (там баннер с Edit), новое письмо открывается окном нового письма.
    private func edit(_ m: ScheduledMail) {
        if let k = m.threadKey {
            store.selectedThread = k
        } else if let back = ScheduledSendStore.shared.cancel(m.id, deleteFiles: false) {
            ComposeBus.shared.restoreScheduled = back
            ui.showNewMessage = true
        }
        dismiss()
    }
}
