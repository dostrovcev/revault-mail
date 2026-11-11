import AppKit
import SwiftUI

/// Клавиши как в Spark и Gmail: одна буква, работают везде, кроме полей ввода.
@MainActor
final class Shortcuts {
    static let list: [(keys: String, title: String)] = [
        ("J  ↓", "Next conversation"), ("K  ↑", "Previous conversation"),
        ("E", "Archive"), ("#", "Move to trash"), ("Z", "Undo"),
        ("R", "Reply"), ("A", "Reply all"), ("F", "Forward"),
        ("S", "Star"), ("U", "Read / unread"),
        ("L", "Labels"), ("V", "Move to label"), ("H", "Snooze"), ("!", "Report spam"),
        ("⌘-click", "Select several"), ("⇧-click", "Select a range"), ("⌘A", "Select all"),
        ("C", "New email"), ("M", "Chat with team"), ("/", "Search"),
        ("Esc", "Clear selection / close"), ("?", "This list"),
        ("⌘+ / ⌘−", "Interface size"), ("⌘0", "Interface at 100%"),
        ("⌘K / ⌘F", "Search mail"),
        ("⌘J", "Revolt panel"), ("⌘↩", "Send"),
    ]

    private var monitor: Any?
    /// Главное окно почты. Клавиши работают только в нём: не в настройках, не в поповерах и не в листах.
    static weak var mainWindow: NSWindow?

    func install(store: MailStore, ui: UIState, hub: HubStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Self.handle(event, store: store, ui: ui, hub: hub) ? nil : event }
        }
    }

    /// Фокус в поле ввода: буквы и меню-команды не трогаем.
    static func isTyping() -> Bool {
        if NSApp.keyWindow === mainWindow, UIState.main?.searchIsFocused == true { return true }
        guard let r = NSApp.keyWindow?.firstResponder else { return false }
        return r is NSText || r is NSTextView || r is NSTextField
    }

    /// Ключевое окно это главное окно почты, без открытого листа поверх.
    static func mainWindowIsKey() -> Bool {
        guard let w = NSApp.keyWindow else { return false }
        if let main = mainWindow { guard w === main else { return false } }
        return w.attachedSheet == nil && w.sheetParent == nil
    }

    /// Фокус внутри тела письма (WKWebView): стрелки должны прокручивать письмо.
    private static func focusInWebView() -> Bool {
        var v = NSApp.keyWindow?.firstResponder as? NSView
        while let cur = v {
            if String(describing: type(of: cur)).hasPrefix("WK") { return true }
            v = cur.superview
        }
        return false
    }

    // Физические клавиши (kVK_ANSI_*): работают и в русской раскладке.
    private enum Key {
        static let a: UInt16 = 0, s: UInt16 = 1, f: UInt16 = 3, h: UInt16 = 4, z: UInt16 = 6, c: UInt16 = 8, v: UInt16 = 9
        static let one: UInt16 = 18, l: UInt16 = 37
        static let e: UInt16 = 14, r: UInt16 = 15, three: UInt16 = 20, u: UInt16 = 32
        static let j: UInt16 = 38, k: UInt16 = 40, slash: UInt16 = 44, m: UInt16 = 46
        static let esc: UInt16 = 53, down: UInt16 = 125, up: UInt16 = 126
    }

    /// Окно треда закрывается и главное окно выходит вперёд: из читалки всегда есть путь обратно.
    static func backToInbox(closing w: NSWindow?) {
        if let main = mainWindow {
            main.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        _ = w
    }

    private static func isReaderWindow(_ w: NSWindow?) -> Bool {
        guard let w, w !== mainWindow else { return false }
        return w.identifier?.rawValue.hasPrefix(Reader.windowID) == true
    }

    private static func handle(_ e: NSEvent, store: MailStore, ui: UIState, hub: HubStore) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        // Esc в окне треда закрывает его (не в поле ввода и не под листом)
        if mods.isEmpty, e.keyCode == Key.esc, !isTyping(), isReaderWindow(NSApp.keyWindow),
           NSApp.keyWindow?.attachedSheet == nil {
            let w = NSApp.keyWindow
            backToInbox(closing: w)
            w?.close()
            return true
        }
        // ⌘A выделяет все видимые треды, но только когда курсор не в поле ввода
        if mods == [.command], e.keyCode == Key.a, !e.modifierFlags.contains(.shift), !isTyping(), mainWindowIsKey(),
           store.mailbox.labelID != "TEAM", !focusInWebView() {
            if let main = mainWindow, e.window !== main { return false }
            store.selectAllVisible()
            return true
        }
        guard mods.isEmpty, !isTyping(), mainWindowIsKey() else { return false }
        if let main = mainWindow, e.window !== main { return false }
        let shift = e.modifierFlags.contains(.shift)
        // В разделе Team ходим по обсуждениям, а не по скрытому списку писем.
        let keys = store.navigableKeys
        let idx = store.selectedThread.flatMap { k in keys.firstIndex(of: k) }
        func move(_ d: Int) {
            guard !keys.isEmpty else { return }
            store.clearSelection()
            let n = idx.map { max(0, min(keys.count - 1, $0 + d)) } ?? 0
            if keys.indices.contains(n) { store.selectedThread = keys[n] }
        }
        let sel = store.selectedThread
        // действия идут на всё выделение, иначе на открытый тред; чужие ящики (Team) не трогаем
        let targets = store.actionKeys.filter { store.isMe($0.account) }
        switch e.keyCode {
        case Key.down:
            if focusInWebView() { return false }
            move(1)
        case Key.up:
            if focusInWebView() { return false }
            move(-1)
        case Key.esc:
            if ui.showShortcuts { ui.showShortcuts = false }
            else if store.listPopover != nil { store.listPopover = nil }
            else if store.isMultiSelecting { store.clearSelection() }
            else if sel != nil { store.selectedThread = nil } else { return false }
        case Key.j: move(1)
        case Key.k: move(-1)
        case Key.e: if !targets.isEmpty { store.archive(targets) }
        case Key.three:
            guard shift else { return false }   // ⇧3 это #
            if !targets.isEmpty { store.trash(targets) }
        case Key.one:
            guard shift else { return false }   // ⇧1 это !, спам как в Gmail
            if !targets.isEmpty { store.mailbox.labelID == "SPAM" ? store.notSpam(targets) : store.markSpam(targets) }
        case Key.l: if !targets.isEmpty { store.listPopover = ListPopover(kind: .labels, keys: targets) } else { return false }
        case Key.v: if !targets.isEmpty { store.listPopover = ListPopover(kind: .move, keys: targets) } else { return false }
        case Key.h: if !targets.isEmpty { store.listPopover = ListPopover(kind: .snooze, keys: targets) } else { return false }
        case Key.z:
            if store.pendingSend != nil { ComposeBus.undoPendingSend(store: store, ui: ui) } else { store.undoLast() }
        case Key.r: if sel != nil, !store.isMultiSelecting { ui.replyRequest = (.reply, nil, UUID()) }
        case Key.a: if sel != nil, !store.isMultiSelecting { ui.replyRequest = (.replyAll, nil, UUID()) }
        case Key.f: if sel != nil, !store.isMultiSelecting { ui.replyRequest = (.forward, nil, UUID()) }
        case Key.s:
            if store.isMultiSelecting { store.toggleStar(targets) } else if let k = sel { store.toggleStar(k) }
        case Key.u:
            if store.isMultiSelecting { store.toggleUnread(targets) } else if let k = sel { store.toggleUnread(k) }
        case Key.c: ui.showNewMessage = true
        case Key.m: if sel != nil { ui.noteRequest = ("", UUID()) }
        case Key.slash:
            if shift { ui.showShortcuts.toggle() } else { ui.searchFocusNonce = UUID() }   // ⇧/ это ?
        default: return false
        }
        return true
    }
}

/// Запоминает окно, в котором стоит вид: так клавиши знают главное окно почты.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}

/// Плашка «Conversation archived · Undo», как в Missive.
struct UndoToast: View {
    @Environment(MailStore.self) private var store
    var body: some View {
        if let u = store.undo {
            HStack(spacing: 16) {
                Text(u.title).font(.g(13.5)).foregroundStyle(.white)
                Button("Undo") { store.undoLast() }.buttonStyle(.plain).font(.g(13.5, .semibold)).foregroundStyle(.white)
                Text("Z").font(.g(11)).foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 5).overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.3)))
                Button { store.undo = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7)) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x2B2F36)))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Шпаргалка по клавишам (?).
struct ShortcutsSheet: View {
    @Environment(UIState.self) private var ui
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.g(16, .semibold))
                Spacer()
                Button { ui.showShortcuts = false } label: { Image(systemName: "xmark").foregroundStyle(Theme.muted) }.buttonStyle(.plain)
            }
            .padding(.bottom, 12)
            let cols = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                ForEach(Shortcuts.list, id: \.title) { s in
                    HStack(spacing: 10) {
                        Text(s.keys).font(.g(12, .semibold)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 7).frame(minWidth: 34, minHeight: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
                        Text(s.title).font(.g(13.5)).foregroundStyle(Theme.ink2)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.white))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
    }
}
