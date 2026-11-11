import AppKit
import SwiftUI

/// Тред в отдельном окне, как «Open in New Window» в Apple Mail и Spark.
/// Своё UIState у окна: «Reply» отсюда открывает ответ в этом окне, а не в главном.
enum Reader {
    static let windowID = "reader"
    /// Масштаб текста письма: 0.7...2.0, шаг 0.1.
    static let zoomKey = "readerZoom"
    static let focusKey = "focusMode"

    static func clampZoom(_ z: Double) -> Double { min(2.0, max(0.7, (z * 10).rounded() / 10)) }
}

/// Открыть тред в окне: `ReaderOpener(openWindow)(key)` или прямо `openWindow(id: "reader", value: key)`.
struct ReaderOpener {
    let openWindow: OpenWindowAction
    @MainActor func callAsFunction(_ key: ThreadKey) { openWindow(id: Reader.windowID, value: key) }
}

extension EnvironmentValues {
    /// Помощник открытия треда в окне из любой вьюхи: `@Environment(\.openReader) var openReader`.
    var openReader: ReaderOpener { ReaderOpener(openWindow: openWindow) }
}

// Окно-читалка сообщает меню, какой тред и какое UIState у него: ⌘P, ⌘R, ⌘E работают по нему.
struct ReaderThreadFocusKey: FocusedValueKey { typealias Value = ThreadKey }
struct ReaderUIFocusKey: FocusedValueKey { typealias Value = UIState }

extension FocusedValues {
    var readerThread: ThreadKey? {
        get { self[ReaderThreadFocusKey.self] }
        set { self[ReaderThreadFocusKey.self] = newValue }
    }
    var readerUI: UIState? {
        get { self[ReaderUIFocusKey.self] }
        set { self[ReaderUIFocusKey.self] = newValue }
    }
}

/// Ответ, который надо открыть сразу при появлении окна треда («Open in a separate window» в редакторе).
@MainActor enum ReaderPending { static var reply: [ThreadKey: ReplyMode] = [:] }

struct ReaderWindow: View {
    let key: ThreadKey?
    @Environment(MailStore.self) private var store
    @Environment(HubStore.self) private var hub
    @State private var ui = UIState()

    private var title: String {
        guard let key else { return "Email" }
        return store.details[key]?.subject ?? hub.snapshotDetail(key)?.subject ?? "Email"
    }

    var body: some View {
        Group {
            if let key {
                ThreadView(pinnedKey: key)
            } else {
                Text("This email is no longer available").font(.g(14)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(ui)
        .background(Theme.page)
        .navigationTitle(title)
        .focusedSceneValue(\.readerThread, key)
        .focusedSceneValue(\.readerUI, ui)
        .task(id: key) {
            // свежая версия треда, даже если в памяти уже есть: окно могли открыть из старого списка
            if let key { await store.loadDetail(key) }
            if let key, let m = ReaderPending.reply.removeValue(forKey: key) {
                try? await Task.sleep(for: .milliseconds(150))
                ui.replyRequest = (m, nil, UUID())
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .font(.g(13.5))
        .foregroundStyle(Theme.ink)
        .tint(Theme.ink)
        .preferredColorScheme(.light)
    }
}

/// Команды чтения: окно треда, печать, фокус на письме, масштаб текста.
struct ReaderCommands: Commands {
    let store: MailStore
    @FocusedValue(\.readerThread) private var readerThread
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Reader.focusKey) private var focusMode = false
    @AppStorage(Reader.zoomKey) private var zoom: Double = 1.0

    /// Тред под командой: окна-читалки, если оно впереди, иначе выбранный в главном окне.
    @MainActor private var target: ThreadKey? { readerThread ?? store.selectedThread }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open in New Window") {
                if let k = store.selectedThread { openWindow(id: Reader.windowID, value: k) }
            }
            .keyboardShortcut("o")
            .disabled(store.selectedThread == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show Inbox") {
                if let w = Shortcuts.mainWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
                else { openWindow(id: "main") }
            }
            .keyboardShortcut("1", modifiers: .command)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { printLatest() }
                .keyboardShortcut("p")
                .disabled(target == nil)
        }
        CommandGroup(before: .toolbar) {
            Button(focusMode ? "Exit Focus" : "Focus on Message") { focusMode.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Divider()
            Button("Larger Message Text") { zoom = Reader.clampZoom(zoom + 0.1) }
                .keyboardShortcut("+", modifiers: [.command, .option])
            Button("Smaller Message Text") { zoom = Reader.clampZoom(zoom - 0.1) }
                .keyboardShortcut("-", modifiers: [.command, .option])
            Button("Reset Message Text Size") { zoom = 1.0 }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(zoom == 1.0)
            Divider()
        }
    }

    /// ⌘P: последнее письмо треда, как печать открытого письма в Apple Mail.
    @MainActor private func printLatest() {
        guard let k = target, let d = store.details[k], let m = d.sentMessages.last ?? d.messages.last else { return }
        Task { await MessagePrinter.print([m], subject: m.subject.isEmpty ? d.subject : m.subject, account: k.account, store: store) }
    }
}
