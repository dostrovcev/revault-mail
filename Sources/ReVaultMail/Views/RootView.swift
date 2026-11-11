import SwiftUI

/// Каркас как в кабинете Re:Vault: меню слева, сверху строка пути и «Ask the agent»,
/// дальше плотный список, письмо и панель агента в духе Zed.
struct RootView: View {
    @Environment(MailStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @Environment(UIState.self) private var ui
    @Environment(AppSettings.self) private var settings
    @Environment(HubStore.self) private var hub
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("focusMode") private var focusMode = false
    // Ширины колонок запоминаются между запусками и обновлениями.
    @AppStorage("width.sidebar") private var sidebarWidth: Double = 250
    @AppStorage("width.list") private var listWidth: Double = 380
    @AppStorage("width.agent") private var agentWidth: Double = 360
    @State private var shortcuts = Shortcuts()
    /// Ширины во время перетаскивания: в настройки пишутся только в конце, а не на каждом кадре.
    @State private var live: [Int: Double] = [:]

    private func liveWidth(_ i: Int, _ stored: Binding<Double>) -> Binding<Double> {
        Binding(get: { live[i] ?? stored.wrappedValue }, set: { live[i] = $0 })
    }

    private func commitWidth(_ i: Int, _ stored: Binding<Double>) {
        if let v = live[i] { stored.wrappedValue = v }
        live[i] = nil
    }

    var body: some View {
        @Bindable var ui = ui
        Group {
            if !store.hasGoogleClient || store.accounts.isEmpty {
                WelcomeView()
            } else {
                if focusMode {
                    // режим «только письмо»: тред на всё окно
                    VStack(spacing: 0) { Color.clear.frame(height: 28); detail }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                GeometryReader { geo in
                    let l = Self.layout(total: geo.size.width, showSidebar: showSidebar, side: live[0] ?? sidebarWidth,
                                        list: live[1] ?? listWidth, showAgent: settings.showAgentPanel, agent: live[2] ?? agentWidth)
                    HStack(spacing: 0) {
                        if l.sidebar > 0 {
                            SidebarView(showSidebar: $showSidebar)
                                .frame(width: l.sidebar)
                            ResizeHandle(width: liveWidth(0, $sidebarWidth), shown: l.sidebar, range: 190...max(190, min(380, l.sidebar + l.spare)),
                                         defaultWidth: 250) { commitWidth(0, $sidebarWidth) }
                        }
                        VStack(spacing: 0) {
                            if l.sidebar == 0 { Color.clear.frame(height: 28) }   // место под кнопки окна
                            ThreadListView()
                        }
                        .frame(width: l.list)
                        ResizeHandle(width: liveWidth(1, $listWidth), shown: l.list, range: 280...max(280, min(720, l.list + l.spare)),
                                     defaultWidth: 380) { commitWidth(1, $listWidth) }
                        // ширина письма задана явно: содержимое, которому тесно, режется, а не раздвигает окно
                        detail
                            .frame(width: l.detail)
                            .clipped()
                        if l.agent > 0 {
                            ResizeHandle(width: liveWidth(2, $agentWidth), shown: l.agent, range: 280...max(280, min(760, l.agent + l.spare)),
                                         defaultWidth: 360, growsLeft: true) { commitWidth(2, $agentWidth) }
                            AgentPanel()
                                .frame(width: l.agent)
                        }
                        VLine()
                        RightRail()
                    }
                    .onAppear { ui.sidebarSqueezed = l.squeezed }
                    .onChange(of: l.squeezed) { _, v in ui.sidebarSqueezed = v }
                }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
        .ignoresSafeArea()
        .sheet(isPresented: $ui.showNewMessage) { ScaledComposeSheet() }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                UndoToast()
                SendUndoToast()
                if let err = store.error { ErrorToast(text: err) { store.error = nil } }
                if let n = hub.notice { ErrorToast(text: n) { hub.notice = nil } }
            }
            .padding(.bottom, 16)
            .animation(.easeOut(duration: 0.18), value: store.undo?.id)
            .animation(.easeOut(duration: 0.18), value: store.pendingSend?.id)
        }
        .overlay {
            // метки, перенос и отложение: своя панель поверх окна, а не системный поповер (тот молча не открывался)
            if let p = store.listPopover {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { store.listPopover = nil }
                    ListPopoverContent(popover: p)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
                        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                        .padding(.top, 110)
                }
            }
        }
        .overlay {
            if ui.showShortcuts {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { ui.showShortcuts = false }
                    ShortcutsSheet()
                }
            }
        }
        .background(WindowAccessor { w in if Shortcuts.mainWindow !== w { Shortcuts.mainWindow = w } })
        .onAppear {
            shortcuts.install(store: store, ui: ui, hub: hub)
            // фокус не в поле поиска: первые J/K после запуска должны листать список
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !Shortcuts.isTyping() && !ui.searchIsFocused { (Shortcuts.mainWindow ?? NSApp.keyWindow)?.makeFirstResponder(nil) } }
            if DevTools.isDemo, ProcessInfo.processInfo.environment["RVM_REPLY"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { ui.replyRequest = (.reply, nil, UUID()) }
            }
        }
        .onChange(of: store.selectedThread) { _, key in agent.focus(thread: key); hub.open(key) }
    }

    static let detailMin: Double = 380
    typealias Layout = InterfaceMetrics.Layout
    static func layout(total: Double, showSidebar: Bool, side: Double, list: Double, showAgent: Bool, agent: Double) -> Layout {
        InterfaceMetrics.layout(total: total, showSidebar: showSidebar, side: side, list: list, showAgent: showAgent, agent: agent)
    }

    @ViewBuilder private var detail: some View {
        if store.isMultiSelecting && store.mailbox.labelID != "TEAM" { MultiSelectionDetail() }
        else if store.selectedThread != nil { ThreadView() } else { EmptyDetail() }
    }
}

/// Узкая панель иконок справа, как в Missive.
struct RightRail: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MailStore.self) private var store
    @Environment(UIState.self) private var ui
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 8)
            IconButton("sparkle", help: "Revolt chat (⇧⌘J)", active: settings.showAgentPanel) {
                settings.showAgentPanel.toggle()
                if settings.showAgentPanel { ui.agentFocusNonce = UUID() }
            }
            IconButton("square.and.pencil", help: "New email (⌘N)") { ui.showNewMessage = true }
            Spacer()
            IconButton("gearshape", help: "Settings (⌘,)") { openSettings() }
                .padding(.bottom, 10)
        }
        .frame(width: 44)
        .background(Theme.side)
    }
}

/// Строка пути, как «Re:Vault (pilot) / Today» в кабинете.
struct TopBar: View {
    @Binding var showSidebar: Bool
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 12) {
            if !showSidebar {
                Color.clear.frame(width: 64)
                IconButton("sidebar.left", help: "Show sidebar") { showSidebar = true }
            }
            HStack(spacing: 6) {
                Text(store.mailbox.account ?? "All inboxes").foregroundStyle(Theme.muted)
                Text("/").foregroundStyle(Theme.ghost)
                Text(store.mailbox.title).foregroundStyle(Theme.ink)
                if let s = store.selectedSummary {
                    Text("/").foregroundStyle(Theme.ghost)
                    Text(s.subject).foregroundStyle(Theme.ink).lineLimit(1)
                }
            }
            .font(.g(13))
            .lineLimit(1)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("Search mail", text: $store.searchText)
                    .textFieldStyle(.plain).font(.g(13))
                    .focused($searchFocused)
                    .onSubmit { Task { await store.refresh() } }
                if store.searchText.isEmpty { Kbd("⌘K") } else {
                    Button { store.searchText = ""; Task { await store.refresh() } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.ghost)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).frame(width: 260, height: 32)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            Button {
                settings.showAgentPanel.toggle()
                if settings.showAgentPanel { ui.agentFocusNonce = UUID() }
            } label: {
                HStack(spacing: 8) { Text("Ask the agent"); Kbd("⌘J") }
            }
            .buttonStyle(.dash)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Theme.page)
        .overlay(alignment: .bottom) { HLine() }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("k").opacity(0).allowsHitTesting(false)
        }
    }
}

struct Kbd: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.g(11)).foregroundStyle(Theme.faint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
    }
}

struct HLine: View { var body: some View { Rectangle().fill(Theme.line).frame(height: 1) } }
struct VLine: View { var body: some View { Rectangle().fill(Theme.line).frame(width: 1) } }

struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Nothing selected").font(.g(14, .medium)).foregroundStyle(Theme.sec)
            HStack(spacing: 6) {
                Kbd("J"); Kbd("K"); Text("navigate").foregroundStyle(Theme.faint)
                Kbd("E"); Text("archive").foregroundStyle(Theme.faint)
                Kbd("R"); Text("reply").foregroundStyle(Theme.faint)
            }
            .font(.g(12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.white)
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    var active = false
    var onSide = false
    let action: () -> Void
    @State private var hover = false

    init(_ icon: String, help: String, active: Bool = false, onSide: Bool = false, action: @escaping () -> Void) {
        self.icon = icon; self.help = help; self.active = active; self.onSide = onSide; self.action = action
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(onSide ? (active || hover ? Theme.sideInk : Theme.sideMuted) : (active || hover ? Theme.ink : Theme.muted))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(onSide ? (active ? Theme.sideNavOn : (hover ? Theme.sideNavHover : .clear))
                                                                         : (active ? Theme.navOn : (hover ? Theme.navHover : .clear))))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.motion(reduceMotion), value: hover)
        .accessibilityLabel(help)
        .help(help)
    }
}

struct ErrorToast: View {
    let text: String
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Theme.red).frame(width: 7, height: 7).padding(.top, 5)
            Text(text).font(.g(13)).foregroundStyle(Theme.ink).textSelection(.enabled).lineLimit(4)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Theme.muted) }.buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .shadow(color: Color(hex: 0x14282B).opacity(0.08), radius: 10, y: 4)
        .task(id: text) {
            do { try await Task.sleep(for: .seconds(12)); close() } catch { }
        }
    }
}

struct Avatar: View {
    let person: Person
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27).fill(Theme.ink)
            Text(initials(person.short)).font(.g(size * 0.42, .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Разделитель колонок: тянешь мышкой, ширина пишется в настройки в конце перетаскивания и переживает перезапуск.
/// growsLeft для колонки справа от разделителя (панель агента растёт при движении влево).
/// shown это ширина, которую колонка сейчас реально занимает (раскладка могла её ужать под окно).
struct ResizeHandle: View {
    @Binding var width: Double
    var shown: Double? = nil
    let range: ClosedRange<Double>
    var defaultWidth: Double? = nil
    var growsLeft = false
    /// Конец перетаскивания или двойной клик: сохранить ширину.
    var onEnd: () -> Void = {}
    @State private var start: Double?
    @State private var hover = false
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(hover || start != nil ? Theme.blue.opacity(0.5) : Theme.line)
            .frame(width: hover || start != nil ? 2 : 1)
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { pushCursor() } else if start == nil { popCursor() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if start == nil { start = shown ?? width; pushCursor() }
                        let delta = growsLeft ? -g.translation.width : g.translation.width
                        let w = min(max((start ?? width) + delta, range.lowerBound), range.upperBound)
                        if abs(w - width) >= 1 { width = w }
                    }
                    .onEnded { _ in
                        start = nil
                        if !hover { popCursor() }
                        onEnd()
                    }
            )
            .onTapGesture(count: 2) {
                let d = defaultWidth ?? (range.lowerBound + range.upperBound) / 2
                width = min(max(d, range.lowerBound), range.upperBound)
                onEnd()
            }
            .help("Drag to resize. Double-click to reset")
            .onDisappear { popCursor() }
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        NSCursor.resizeLeftRight.push()
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}
