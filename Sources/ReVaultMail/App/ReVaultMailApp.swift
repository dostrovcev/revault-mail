import AppKit
import SwiftUI
import UserNotifications

enum ReplyMode: String { case reply, replyAll, forward }

/// Мелкие команды между меню, списком, письмом и агентом.
@Observable
@MainActor
final class UIState {
    var showNewMessage = false
    var newMessagePrefill: (to: String, subject: String, body: String)?
    var replyRequest: (mode: ReplyMode, messageID: String?, nonce: UUID)?
    var agentFocusNonce = UUID()
    /// Открыть заметку в треде с готовым началом (например «@revolt »).
    var noteRequest: (text: String, nonce: UUID)?
    var showSettings = false
    var searchFocusNonce = UUID()
    var searchIsFocused = false
    var showShortcuts = false
    /// Окно слишком узкое: меню слева спрятано раскладкой, хотя пользователь его не закрывал.
    var sidebarSqueezed = false

    /// UIState главного окна: у окна-читалки своё, а новое письмо (mailto отписки) открывается в главном.
    static weak var main: UIState?
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Куда вести клик по уведомлению: ставит приложение при старте окна.
    @MainActor static weak var store: MailStore?
    @MainActor static weak var hub: HubStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let snapshot = ProcessInfo.processInfo.environment["RVM_SNAPSHOT"] != nil
        NSApp.setActivationPolicy(snapshot ? .accessory : .regular)
        if !snapshot { NSApp.activate(ignoringOtherApps: true) }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        MainActor.assumeIsolated { DevTools.scheduleSnapshot() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Уведомления команды показываем и при открытом приложении, почтовые как раньше: только в фоне.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix(HubStore.notificationPrefix) ? [.banner, .sound] : [])
    }

    /// Клик по уведомлению открывает тот тред.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if id.hasPrefix(HubStore.notificationPrefix) {
                let hubKey = String(id.dropFirst(HubStore.notificationPrefix.count))
                if let k = Self.hub?.threadKey(from: hubKey) { Self.store?.selectedThread = k }
            } else if let slash = id.lastIndex(of: "/"), id.contains("@") {
                Self.store?.selectedThread = ThreadKey(account: String(id[..<slash]), threadID: String(id[id.index(after: slash)...]))
            }
            completionHandler()
        }
    }
}

@main
struct ReVaultMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = MailStore()

    init() { Theme.registerFonts() }
    @State private var agent = AgentStore()
    @State private var translator = Translator()
    @State private var ui = UIState()
    @State private var hub = HubStore()
    @State private var settings = AppSettings.shared
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("theme") private var theme = Theme.Kind.vault.rawValue

    var body: some Scene {
        let _ = (Theme.kind = Theme.Kind(rawValue: theme) ?? .vault)
        WindowGroup("Re:Vault Mail", id: "main") {
            RootView()
                .modifier(InterfaceScale())
                .id(theme)
                .environment(store)
                .environment(agent)
                .environment(translator)
                .environment(ui)
                .environment(settings)
                .environment(hub)
                .task {
                    hub.attach(store); agent.hub = hub; store.importance.hub = hub
                    // отложенная отправка и напоминания «если не ответят» работают с запуска, а не с первого черновика
                    if !DevTools.isDemo {
                        ScheduledSendStore.shared.start(store: store)
                        FollowUpStore.shared.start(store: store)
                    }
                    Translator.hub = hub
                    AppDelegate.store = store; AppDelegate.hub = hub
                    UIState.main = ui
                }
                .frame(minWidth: 1100, minHeight: 640)
                .font(.g(13.5))
                .foregroundStyle(Theme.ink)
                .tint(Theme.ink)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1500, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Email") { ui.showNewMessage = true }.keyboardShortcut("n")
            }
            CommandGroup(before: .toolbar) {
                Button(showSidebar && !ui.sidebarSqueezed ? "Hide Sidebar" : "Show Sidebar") { toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            InterfaceScaleCommands()
            MessageCommands(store: store, ui: ui)
            ReaderCommands(store: store)
            CommandMenu("Agent") {
                Button("Show or Hide Agent Panel") { settings.showAgentPanel.toggle() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Ask Revolt") {
                    settings.showAgentPanel = true
                    ui.agentFocusNonce = UUID()
                }.keyboardShortcut("j")
                Button("New Chat") {
                    settings.showAgentPanel = true
                    agent.newChat(thread: store.selectedDetail)
                    ui.agentFocusNonce = UUID()
                }.keyboardShortcut("t", modifiers: [.command, .option])
            }
        }

        // Тред в отдельном окне: двойной клик в списке, ⌘O, кнопка в шапке письма.
        WindowGroup("Email", id: Reader.windowID, for: ThreadKey.self) { $key in
            ReaderWindow(key: key)
                .modifier(InterfaceScale())
                .frame(minWidth: 1008, minHeight: 728)
                .id(theme)
                .environment(store)
                .environment(agent)
                .environment(translator)
                .environment(settings)
                .environment(hub)
        }
        .defaultSize(width: 1040, height: 820)
        .defaultSize(width: 900, height: 860)

        Settings {
            SettingsView()
                .font(.g(13.5))
                .preferredColorScheme(.light)
                .environment(store)
                .environment(settings)
                .environment(hub)
                .environment(agent)
        }
    }

    /// Меню слева: если его спрятала узкая ширина окна, освобождаем место, закрыв панель агента.
    @MainActor private func toggleSidebar() {
        if ui.sidebarSqueezed {
            showSidebar = true
            settings.showAgentPanel = false
        } else {
            showSidebar.toggle()
        }
    }
}

/// Меню «Message». Если впереди окно-читалка, ответ, архив и корзина работают по его треду.
struct MessageCommands: Commands {
    let store: MailStore
    let ui: UIState
    @FocusedValue(\.readerThread) private var readerThread
    @FocusedValue(\.readerUI) private var readerUI

    /// Команда над письмом: только в главном окне и не во время набора текста.
    @MainActor private func mailCommandAllowed() -> Bool {
        !Shortcuts.isTyping() && Shortcuts.mainWindowIsKey()
    }

    /// Окно-читалка впереди и в нём не печатают.
    @MainActor private var readerActive: Bool { readerUI != nil && readerThread != nil && !Shortcuts.isTyping() }

    @MainActor private func reply(_ m: ReplyMode) {
        if let r = readerUI, readerThread != nil {
            if !Shortcuts.isTyping() { r.replyRequest = (m, nil, UUID()) }
        } else if mailCommandAllowed() {
            ui.replyRequest = (m, nil, UUID())
        }
    }

    /// Тред под командой архива или корзины; окно-читалка после неё закрывается.
    @MainActor private func act(_ f: (ThreadKey) -> Void) {
        if readerActive, let k = readerThread {
            guard store.isMe(k.account) else { return }
            f(k)
            NSApp.keyWindow?.performClose(nil)
            return
        }
        guard mailCommandAllowed(), let k = store.selectedThread, store.isMe(k.account) else { return }
        f(k)
    }

    var body: some Commands {
        CommandMenu("Message") {
            Button("Refresh") { Task { await store.refresh() } }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            // Пока курсор в поле ввода, команды над письмом не срабатывают: иначе ⌘R, ⌘E, ⌘⌫
            // в окне ответа выбрасывают черновик.
            Button("Reply") { reply(.reply) }.keyboardShortcut("r")
            Button("Reply All") { reply(.replyAll) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { reply(.forward) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Archive") { act { store.archive($0) } }.keyboardShortcut("e")
            Button("Move to Trash") {
                if Shortcuts.isTyping() {
                    // ⌘⌫ в тексте это «стереть до начала строки», отдаём его полю
                    NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                    return
                }
                act { store.trash($0) }
            }.keyboardShortcut(.delete)
            Button("Mark as Read / Unread") {
                if readerActive, let k = readerThread { store.toggleUnread(k) }
                else if mailCommandAllowed(), let k = store.selectedThread { store.toggleUnread(k) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Star") {
                if readerActive, let k = readerThread { store.toggleStar(k) }
                else if mailCommandAllowed(), let k = store.selectedThread { store.toggleStar(k) }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
