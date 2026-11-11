import SwiftUI

/// Меню в раскладке Missive: Inbox раскрывается по ящикам со счётчиками, ниже разделы почты,
/// команда (общие обсуждения), метки и агент; внизу карточка владельца.
struct SidebarView: View {
    @Binding var showSidebar: Bool
    @Environment(MailStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @Environment(HubStore.self) private var hub
    @Environment(\.openSettings) private var openSettings
    @AppStorage("inboxExpanded") private var inboxExpanded = true
    @AppStorage("labelsExpanded") private var labelsExpanded = true
    @State private var showAccounts = false
    /// Вход в Google идёт в браузере: держим задачу, чтобы его можно было отменить.
    @State private var signIn: Task<Void, Never>?
    @State private var signInID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 70)
                // на узкой панели логотип не сминается в «R…»: сначала знак «R:», потом ничего
                if Theme.p.sideIsDark {
                    ViewThatFits(in: .horizontal) {
                        Logo(size: 18, color: Theme.sideInk).fixedSize()
                        (Text("R").foregroundColor(Theme.sideInk) + Text(":").foregroundColor(Theme.accent))
                            .font(.g(18, .semibold)).fixedSize()
                        Color.clear.frame(width: 0)
                    }
                }
                Spacer(minLength: 0)
                IconButton("sidebar.left", help: "Hide sidebar (⌃⌘S)", onSide: true) { showSidebar = false }
                RefreshButton()
                Button { ui.showNewMessage = true } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sideInk)
                        .frame(width: 34, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sideCard))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.sideBorder))
                }
                .buttonStyle(.plain).help("New email (⌘N)")
            }
            .frame(height: 44)
            .padding(.trailing, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    MissiveRow(title: "Inbox", icon: "tray.fill", iconColor: Theme.p.sideIsDark ? Theme.sideInk : Theme.blue,
                               selected: store.mailbox.labelID == "INBOX" && store.mailbox.account == nil,
                               unread: store.unreadInbox(nil), total: store.totalInbox(nil),
                               disclosure: store.accounts.count > 1 ? inboxExpanded : nil,
                               toggle: { inboxExpanded.toggle() }) {
                        store.mailbox = Mailbox(account: nil, labelID: "INBOX", title: "Inbox")
                    }
                    .contextMenu { markAllMenu(Mailbox(account: nil, labelID: "INBOX", title: "Inbox")) }
                    if inboxExpanded && store.accounts.count > 1 {
                        ForEach(store.accounts) { a in
                            MissiveRow(title: a.email, icon: "tray", indent: 6,
                                       selected: store.mailbox.labelID == "INBOX" && store.mailbox.account == a.email,
                                       unread: store.unreadInbox(a.email), total: store.totalInbox(a.email)) {
                                store.mailbox = Mailbox(account: a.email, labelID: "INBOX", title: "Inbox")
                            }
                            .contextMenu { markAllMenu(Mailbox(account: a.email, labelID: "INBOX", title: "Inbox")) }
                        }
                    }
                    MissiveRow(title: "Important", icon: "bolt.fill", iconColor: Theme.accent,
                               selected: store.isImportantBox,
                               unread: store.importantUnread, total: 0) {
                        store.mailbox = Mailbox(account: nil, labelID: "IMPORTANT_RV", title: "Important")
                    }
                    .contextMenu { markAllMenu(Mailbox(account: nil, labelID: "IMPORTANT_RV", title: "Important")) }
                    MissiveRow(title: "Snoozed", icon: "clock.fill", iconColor: Theme.accentText,
                               selected: store.isSnoozedBox, unread: 0, total: snoozedCount) {
                        store.mailbox = Mailbox(account: store.mailbox.account, labelID: MailStore.snoozedBox, title: "Snoozed")
                    }
                    .help(nextWake.map { "Next comes back \(Fmt.snoozeTime($0))" } ?? "Snoozed conversations")
                    box("STARRED", "Starred", "star.fill")
                    box("DRAFT", "Drafts", "pencil")
                    box("SENT", "Sent", "paperplane.fill")
                    box("ALL", "All", "archivebox.fill")
                    box("SPAM", "Spam", "exclamationmark.octagon.fill")
                    box("TRASH", "Trash", "trash.fill")

                    if !hub.threads.isEmpty {
                        section("Team conversations")
                        ForEach(hub.threads.prefix(12)) { t in
                            MissiveRow(title: t.subject, icon: "bubble.left.and.bubble.right.fill", iconColor: Theme.sideIcon,
                                       selected: store.selectedThread.map(HubStore.key) == t.key,
                                       unread: t.unread ? 1 : 0, total: 0, dot: t.unread) {
                                if let k = hub.threadKey(from: t.key) { store.selectedThread = k }
                            }
                            .help(t.last.map { "\($0.author_name ?? ""): \($0.text)" } ?? t.subject)
                        }
                    }

                    let labels = labelList
                    if !labels.isEmpty {
                        Button { labelsExpanded.toggle() } label: {
                            HStack(spacing: 4) {
                                Text("Labels").font(.g(12, .medium)).foregroundStyle(Theme.sideFaint)
                                Image(systemName: labelsExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.sideFaint)
                            }
                            .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if labelsExpanded {
                            // id метки повторяется между ящиками (Label_1), поэтому ключ это ящик плюс id
                            ForEach(labels, id: \.key) { item in
                                let l = item.label, acc = item.account
                                MissiveRow(title: l.name, icon: "tag.fill", iconColor: Color(hexString: l.color) ?? Theme.sideMuted,
                                           selected: store.mailbox.labelID == l.id && store.mailbox.account == acc) {
                                    store.mailbox = Mailbox(account: acc, labelID: l.id, title: l.name)
                                }
                                .contextMenu { markAllMenu(Mailbox(account: acc, labelID: l.id, title: l.name)) }
                            }
                        }
                    }

                    if !agent.chats.isEmpty {
                        section("Revolt chats")
                        ForEach(agent.sortedChats.prefix(6)) { chat in
                            MissiveRow(title: chat.title, icon: "sparkle", iconColor: Theme.accent,
                                       selected: settings.showAgentPanel && agent.activeChatID == chat.id) {
                                agent.activeChatID = chat.id
                                settings.showAgentPanel = true
                                if let k = chat.threadKey { store.selectedThread = k }
                            }
                            .contextMenu { Button("Delete chat", role: .destructive) { agent.delete(chat.id) } }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            if signIn != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser").font(.g(12.5)).foregroundStyle(Theme.sideMuted).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Cancel") { signIn?.cancel(); signIn = nil }
                        .buttonStyle(.dash(.ghost, small: true))
                }
                .padding(.horizontal, 14).padding(.top, 8)
            }
            ownerCard.padding(10)
        }
        .background(Theme.side)
    }

    struct LabelItem { var key: String; var label: MailLabel; var account: String }

    /// Метки всех ящиков (в одном ящике только его).
    private var labelList: [LabelItem] {
        let accs = store.mailbox.account.map { [$0] } ?? store.accounts.map(\.email)
        // служебная метка отложенных живёт в своём пункте Snoozed, среди меток её не показываем
        return accs.flatMap { a in
            store.userLabels(a).filter { !MailStore.snoozeLabelNames.contains($0.name) }.prefix(12)
                .map { LabelItem(key: a + "/" + $0.id, label: $0, account: a) }
        }
    }

    private func box(_ id: String, _ title: String, _ icon: String) -> some View {
        MissiveRow(title: title, icon: icon, selected: store.mailbox.labelID == id) {
            store.mailbox = Mailbox(account: store.mailbox.account, labelID: id, title: title)
        }
        .contextMenu { markAllMenu(Mailbox(account: store.mailbox.account, labelID: id, title: title)) }
    }

    /// Меню папки: прочитать всё разом.
    @ViewBuilder private func markAllMenu(_ box: Mailbox) -> some View {
        Button("Mark all as read") { store.markAllRead(box) }
    }

    private var snoozedCount: Int {
        let accs = Set(store.mailbox.account.map { [$0] } ?? store.accounts.map(\.email))
        return store.snoozes.filter { accs.contains($0.key.account) }.count
    }

    private var nextWake: Date? { store.snoozes.map(\.until).min() }

    private func section(_ t: String) -> some View {
        Text(t).font(.g(12, .medium)).foregroundStyle(Theme.sideFaint)
            .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
    }

    private var ownerCard: some View {
        let a = store.accounts.first
        let name = (a?.displayName.isEmpty == false && a?.displayName != "Re:Vault") ? a!.displayName : "Your account"
        return Button { showAccounts.toggle() } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Text(initials(name)).font(.g(11, .semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Circle().fill(Theme.p.sideIsDark ? Theme.accent : Theme.ink))
                    Circle().fill(!store.expiredAccounts.isEmpty ? Theme.accent : (store.isOnline ? Theme.green : Theme.sideFaint))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.sideCard, lineWidth: 2))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.g(13, .medium)).foregroundStyle(Theme.sideInk).lineLimit(1)
                    Text(cardStatus).font(.g(11.5))
                        .foregroundStyle(store.isOnline && store.expiredAccounts.isEmpty ? Theme.sideFaint : Theme.accentText)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.sideFaint)
            }
            .padding(.horizontal, 10).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sideCard))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.sideBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAccounts, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if store.accounts.count > 1 {
                    NavRow(title: "All inboxes", icon: "tray.2", selected: store.mailbox == Mailbox(account: nil, labelID: "INBOX", title: "Inbox")) {
                        showAccounts = false
                        store.mailbox = Mailbox(account: nil, labelID: "INBOX", title: "Inbox")
                    }
                }
                ForEach(store.accounts) { a in
                    if store.expiredAccounts.contains(a.email) {
                        NavRow(title: "Sign in again: \(a.email)", icon: "exclamationmark.circle", selected: false, hot: true) {
                            showAccounts = false
                            startSignIn { await store.relogin(a.email) }
                        }
                    } else {
                        NavRow(title: a.email, icon: "envelope",
                               selected: store.mailbox.account == a.email && store.mailbox.labelID == "INBOX") {
                            showAccounts = false
                            store.mailbox = Mailbox(account: a.email, labelID: "INBOX", title: "Inbox")
                        }
                    }
                }
                HLine().padding(.vertical, 4)
                NavRow(title: "Add Google account", icon: "plus", selected: false) {
                    showAccounts = false
                    startSignIn { await store.addAccount() }
                }
                NavRow(title: "Refresh", icon: "arrow.clockwise", selected: false) {
                    showAccounts = false
                    Task { await store.refresh() }
                }
                NavRow(title: "Settings", icon: "gearshape", selected: false) {
                    showAccounts = false
                    openSettings()
                }
            }
            .padding(8).frame(width: 300).background(Theme.white)
        }
    }

    private var cardStatus: String {
        if !store.expiredAccounts.isEmpty { return store.expiredAccounts.count == 1 ? "Sign in again" : "\(store.expiredAccounts.count) inboxes need sign-in" }
        return store.isOnline ? "\(store.accounts.count) inboxes" : "Offline"
    }

    /// Вход в браузере с полосой «Finish signing in» и кнопкой отмены.
    private func startSignIn(_ work: @escaping @MainActor () async -> Void) {
        signIn?.cancel()
        let id = UUID()
        signInID = id
        signIn = Task { @MainActor in
            await work()
            if signInID == id { signIn = nil }
        }
    }
}

/// Строка меню как в Missive: иконка, имя, справа счётчики (непрочитанные плашкой и всего).
struct MissiveRow: View {
    let title: String
    let icon: String
    var iconColor: Color = Theme.icon
    var indent: CGFloat = 0
    let selected: Bool
    var unread = 0
    var total = 0
    var dot = false
    var disclosure: Bool? = nil
    var toggle: (() -> Void)? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            if let disclosure {
                Button { toggle?() } label: {
                    Image(systemName: disclosure ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.sideFaint).frame(width: 14, height: 28)
                }.buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14)
            }
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 14)).foregroundStyle(iconColor).frame(width: 20)
                    // тесно: сначала уходит счётчик «всего», потом адрес сокращается до имени до @, и только потом многоточие
                    // ящики под Inbox всегда коротким именем (одинаково у обоих), полный адрес в подсказке
                    let name = title.contains("@") ? shortTitle : title
                    ViewThatFits(in: .horizontal) {
                        line(name, total: total)
                        line(name, total: 0)
                        line(name, total: 0, truncate: true)
                    }
                }
                .help(title.contains("@") ? title : "")
                .padding(.horizontal, 8).frame(height: 34)
                .overlay(alignment: .leading) {
                    if selected { RoundedRectangle(cornerRadius: 1.5).fill(Theme.sideMark).frame(width: 3).padding(.vertical, 7) }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.sideNavOn : (hover ? Theme.sideNavHover : .clear)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
        .padding(.leading, indent)
    }

    private var shortTitle: String {
        guard let at = title.firstIndex(of: "@"), at > title.startIndex else { return title }
        return String(title[..<at])
    }

    @ViewBuilder
    private func line(_ text: String, total: Int, truncate: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.g(indent > 0 ? 13 : 14, selected ? .medium : .regular)).foregroundStyle(Theme.sideInk)
                .lineLimit(1).truncationMode(.tail)
                .fixedSize(horizontal: !truncate, vertical: false)
            Spacer(minLength: 4)
            if dot { Circle().fill(Theme.dot).frame(width: 7, height: 7) }
            else { Counters(unread: unread, total: total).fixedSize() }
        }
    }
}

/// Обновить почту сейчас (⇧⌘N): пока идёт загрузка, иконка крутится.
struct RefreshButton: View {
    @Environment(MailStore.self) private var store
    @State private var hover = false

    var body: some View {
        Button { Task { await store.refresh() } } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? Theme.sideInk : Theme.sideMuted)
                .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                .animation(store.isLoading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: store.isLoading)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.sideNavHover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(store.isLoading)
        .help("Refresh and get new mail (⇧⌘N)")
    }
}

/// Две плашки как в Missive: непрочитанные акцентом, всего серым.
struct Counters: View {
    let unread: Int
    let total: Int
    var body: some View {
        HStack(spacing: 0) {
            if unread > 0 {
                Text(Self.fmt(unread)).font(.g(11.5, .semibold)).foregroundStyle(Theme.sideUnreadText)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6,
                                                       bottomTrailingRadius: total > 0 ? 0 : 6, topTrailingRadius: total > 0 ? 0 : 6)
                        .fill(Theme.sideUnreadBg))
            }
            if total > 0 {
                Text(Self.fmt(total)).font(.g(11.5, .medium)).foregroundStyle(Theme.sideCountText)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(UnevenRoundedRectangle(topLeadingRadius: unread > 0 ? 0 : 6, bottomLeadingRadius: unread > 0 ? 0 : 6,
                                                       bottomTrailingRadius: 6, topTrailingRadius: 6)
                        .fill(Theme.sideCountBg))
            }
        }
    }
    static func fmt(_ n: Int) -> String { n > 999 ? "999+" : "\(n)" }
}

extension Color {
    init?(hexString: String?) {
        guard var s = hexString?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard let v = UInt32(s, radix: 16), s.count == 6 else { return nil }
        self.init(hex: v)
    }
}

/// Простая строка меню для всплывающих списков.
struct NavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    var badge = 0
    var hot = false
    var trailing: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.icon)
                    .frame(width: 18)
                Text(title).font(.g(13.5, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2).lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 { Text("\(badge)").font(.g(12, .medium)).foregroundStyle(hot ? Theme.accent : Theme.muted) }
                if let trailing { Text(trailing).font(.g(12)).foregroundStyle(Theme.muted) }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.navOn : (hover ? Theme.navHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
