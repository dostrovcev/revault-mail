import SwiftUI

/// Список как в Missive: поиск сверху, группы по дням, строка из трёх линий,
/// выбранный тред залит чернилами, тред с обсуждением команды помечен полосой слева.
struct ThreadListView: View {
    @Environment(MailStore.self) private var store
    @Environment(AgentStore.self) private var agent
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @Environment(HubStore.self) private var hub
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var suggestionsShown = false
    @State private var personIndex = -1
    @FocusState private var searchFocused: Bool
    @AppStorage("showSidebar") private var showSidebar = true
    /// Верхняя видимая строка: при новых письмах список держится за неё и не прыгает под мышкой.
    @State private var topID: ThreadKey?
    private static let topAnchor = "rvm-list-top"

    /// В самое начало ленты, над заголовком первого дня. После раскладки, иначе новые строки ещё не на месте.
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        // topID не трогаем: в самом верху видна нулевая метка, у неё не ThreadKey, и scrollPosition сам даёт nil = «наверху»
        DispatchQueue.main.async { proxy.scrollTo(Self.topAnchor, anchor: .top) }
    }

    private var isTeam: Bool { store.mailbox.labelID == "TEAM" }
    private var typedQuery: String { store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var pendingSearch: Bool { !isTeam && typedQuery != store.activeQuery }
    private var scopeTitle: String { isTeam ? "Team" : (store.mailbox.account ?? "All accounts") }
    private var resultCount: Int { isTeam ? visibleTeamThreads.count : store.visibleThreads.count }
    private var visibleTeamThreads: [HubThreadInfo] {
        hub.threads.filter { t in
            let text = ([t.subject, t.account, t.last?.text ?? ""] + t.members).joined(separator: " ")
            return (typedQuery.isEmpty || text.localizedCaseInsensitiveContains(typedQuery)) && (store.filter != .unread || t.unread)
        }
    }
    private var searchStatus: String {
        if pendingSearch { return MailSearch.readyForAutomaticSearch(typedQuery) ? "Searching…" : "Finish typing your search" }
        if store.isLoading { return "Searching…" }
        return "\(resultCount) \(resultCount == 1 ? "conversation" : "conversations")\(store.hasMore && !isTeam ? "+" : "") · \(scopeTitle)"
    }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !showSidebar || ui.sidebarSqueezed {
                    Button {
                        // меню спрятала узкая ширина окна: освобождаем место, закрыв панель агента
                        if ui.sidebarSqueezed { settings.showAgentPanel = false }
                        showSidebar = true
                    } label: {
                        Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(Theme.ink2)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chip))
                    }
                    .buttonStyle(.plain)
                    .help("Show sidebar (⌃⌘S)")
                }
                HStack(spacing: 6) {
                    Button {
                        if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            searchFocused = true; suggestionsShown = true
                        } else { runSearch(store.searchText) }
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.muted)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Search automatically as you type · Enter to close suggestions").accessibilityLabel("Search mail")
                    TextField(isTeam ? "Search team conversations" : "Search all mail", text: $store.searchText)
                        .textFieldStyle(.plain).font(.g(14))
                        .focused($searchFocused)
                        .onSubmit {
                            if let p = pickedPerson { runSearch(SearchSuggestions.query(picking: p, in: store.searchText)); return }
                            runSearch(store.searchText)
                        }
                        .onKeyPress(.downArrow) { movePerson(1) }
                        .onKeyPress(.upArrow) { movePerson(-1) }
                        .onChange(of: store.searchText) { _, q in
                            personIndex = -1
                            if searchFocused { suggestionsShown = true }
                            if let t = PeopleIndex.term(in: q) { store.people.lookup(t, clients: store.searchClients) }
                        }
                        .onKeyPress(.escape) {
                            if suggestionsShown { suggestionsShown = false; personIndex = -1 }
                            else { runSearch("") }
                            return .handled
                        }
                    if !store.searchText.isEmpty {
                        Button { runSearch("") } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 4).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(searchFocused ? Theme.ink : Theme.border))
                .animation(Theme.motion(reduceMotion), value: searchFocused)
                Menu {
                    Picker("Show", selection: $store.filter) {
                        Text("All").tag(MailStore.ListFilter.all)
                        Text("Unread").tag(MailStore.ListFilter.unread)
                        Text("Starred").tag(MailStore.ListFilter.starred)
                    }
                    .pickerStyle(.inline)
                    if !isTeam && !store.isSnoozedBox {
                        Divider()
                        Button("Mark all as read") { store.markAllRead(store.mailbox) }
                    }
                    if !store.blockedSenders.isEmpty {
                        Menu("Blocked senders") {
                            ForEach(store.blockedSenders) { b in
                                Button("Unblock \(b.email)") { store.unblock(b) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13))
                        .foregroundStyle(store.filter == .all ? Theme.muted : Theme.blue)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                .help("Filter")
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .background {
                Button("") { searchFocused = true; suggestionsShown = true }.keyboardShortcut("k").opacity(0).allowsHitTesting(false)
                Button("") { searchFocused = true; suggestionsShown = true }.keyboardShortcut("f").opacity(0).allowsHitTesting(false)
            }
            if suggestionsShown && !isTeam {
                ScrollView {
                    SearchSuggestions(insert: insertOperator, run: runSearch, highlighted: personIndex)
                }
                .frame(height: suggestionHeight)
                .padding(.horizontal, 12).padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            }
            .background(Theme.page)
            .background(SearchDismissal(enabled: suggestionsShown, dismiss: dismissSuggestions))
            .animation(Theme.motion(reduceMotion), value: suggestionsShown)

            if !typedQuery.isEmpty || !store.activeQuery.isEmpty {
                HStack(spacing: 8) {
                    if store.isLoading || pendingSearch { ProgressView().controlSize(.mini) }
                    Text(searchStatus).lineLimit(1)
                        .font(.g(12)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                Picker("Conversations", selection: $store.filter) {
                    Text("All").tag(MailStore.ListFilter.all)
                    Text("Unread").tag(MailStore.ListFilter.unread)
                    if !isTeam { Text("Starred").tag(MailStore.ListFilter.starred) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel("Filter conversations")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            HLine()

            if store.isMultiSelecting && !isTeam {
                BulkActionBar().zIndex(1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    // заголовки дней не закрепляются: закреплённый «Today» ложился поверх строки, к которой
                    // прокручивала лента, и прятал её верх (отправителя), письмо приходилось двигать руками
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Color.clear.frame(height: 0).id(Self.topAnchor)
                        if isTeam {
                            teamList
                        } else {
                            ForEach(store.isSnoozedBox ? Self.snoozeGroups(store.visibleThreads, store: store) : Self.groups(store.visibleThreads), id: \.title) { g in
                                Section {
                                    ForEach(g.items, id: \.key) { t in
                                        let hk = HubStore.key(t.key)
                                        ThreadRow(thread: t, selected: isSelected(t.key),
                                                  showAccount: store.mailbox.account == nil && store.accounts.count > 1,
                                                  team: hub.threads.first { $0.key == hk },
                                                  wake: store.isSnoozedBox ? store.snoozeEntry(t.key)?.until : nil,
                                                  muted: store.isMuted(t.key))
                                            .id(t.key)
                                            .onTapGesture { click(t.key) }
                                            .contextMenu { menu(t) }
                                    }
                                } header: {
                                    Text(g.title).font(.g(12, .semibold)).foregroundStyle(Theme.faint)
                                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.white)
                                }
                            }
                            if store.hasMore, !store.threads.isEmpty, !pendingSearch {
                                Button(store.isLoadingMore ? "Loading..." : "Load more") { Task { await store.loadMore() } }
                                    .disabled(store.isLoading || store.isLoadingMore || !store.isOnline)
                                    .buttonStyle(.dash(.ghost, small: true))
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .onAppear { Task { await store.loadMore() } }
                            }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 10)
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $topID, anchor: .top)
                // выбор с клавиатуры (J/K, стрелки): лента сдвигается ровно настолько, чтобы строка была видна целиком
                .onChange(of: store.selectedThread) { _, k in if let k { proxy.scrollTo(k) } }
                .onChange(of: store.visibleThreads.first?.key) { old, _ in
                    // стоял в самом верху: показываем новые письма с заголовком дня; листал ниже: остаёмся на своей строке
                    if topID == nil || topID == old { scrollToTop(proxy) }
                }
                .onChange(of: store.mailbox) { _, _ in scrollToTop(proxy) }
            }
            .opacity(pendingSearch ? 0.25 : 1)
            .allowsHitTesting(!pendingSearch)
            .overlay {
                if !isTeam, store.visibleThreads.isEmpty, !store.isLoading, !pendingSearch {
                    VStack(spacing: 12) {
                        Image(systemName: store.error != nil ? "exclamationmark.circle" : "magnifyingglass").font(.system(size: 24)).foregroundStyle(Theme.muted)
                        Text(emptyText).font(.g(14)).foregroundStyle(Theme.sec).multilineTextAlignment(.center)
                        if store.error != nil { Button("Try again") { Task { await store.refresh() } }.buttonStyle(.dash) }
                        else if store.filter != .all { Button("Show all conversations") { store.filter = .all }.buttonStyle(.dash) }
                        else if !store.activeQuery.isEmpty { Button("Clear search") { runSearch("") }.buttonStyle(.dash) }
                    }.padding(24)
                }
                if store.isLoading, store.threads.isEmpty { ProgressView().controlSize(.small) }
            }
        }
        .background(Theme.white)
        .onChange(of: ui.searchFocusNonce) { _, _ in searchFocused = true; suggestionsShown = true }
        .onChange(of: searchFocused) { _, focused in
            ui.searchIsFocused = focused; suggestionsShown = focused; personIndex = -1
        }
        .onDisappear { ui.searchIsFocused = false }
        .task(id: store.searchText) {
            let q = typedQuery
            guard !isTeam, MailSearch.readyForAutomaticSearch(q), q != store.activeQuery else { return }
            do { try await Task.sleep(for: .milliseconds(q.isEmpty ? 0 : 450)) } catch { return }
            guard !Task.isCancelled, typedQuery == q, q != store.activeQuery else { return }
            await store.refresh(query: q, remember: false)
            if !Task.isCancelled, typedQuery == q { suggestionsShown = false; personIndex = -1 }
        }
        .onChange(of: visibleTeamThreads.map(\.key), initial: true) { _, _ in
            if isTeam { store.teamKeys = visibleTeamThreads.compactMap { hub.threadKey(from: $0.key) } }
        }
        .onChange(of: store.mailbox) { _, _ in
            dismissSuggestions()
            if isTeam && store.filter == .starred { store.filter = .all }
            if isTeam { store.teamKeys = visibleTeamThreads.compactMap { hub.threadKey(from: $0.key) } }
        }
        .onChange(of: store.selectedThread) { _, key in if key != nil { dismissSuggestions() } }
        .onAppear { if DevTools.isDemo, ProcessInfo.processInfo.environment["RVM_SEARCH"] != nil { suggestionsShown = true } }
    }

    /// Пустой список: говорим, почему он пуст, а не всегда «Inbox zero».
    private var emptyText: String {
        if !store.isOnline { return "You’re offline. Connect to search your mail." }
        if !store.expiredAccounts.isEmpty { return "A mailbox needs sign-in. Open Settings → Accounts to reconnect it." }
        if store.error != nil { return "Couldn't load. Press ⌘⇧N to retry" }
        if store.filter == .unread { return "No unread conversations in these results." }
        if store.filter == .starred { return "No starred conversations in these results." }
        if !store.activeQuery.isEmpty { return "No conversations found. Try another name, address or keyword." }
        if store.isSnoozedBox { return "Nothing snoozed. Press H on a conversation to snooze it" }

        switch store.filter {
        case .unread: return "No unread conversations"
        case .starred: return "No starred conversations"
        case .all: break
        }
        return store.mailbox.labelID == "INBOX" ? "Inbox zero" : "Nothing in \(store.mailbox.title)"
    }

    @ViewBuilder private var teamList: some View {
        if visibleTeamThreads.isEmpty {
            VStack(spacing: 6) {
                Text(typedQuery.isEmpty ? "No team conversations yet" : "No matching team conversations").font(.g(13, .medium)).foregroundStyle(Theme.sec)
                Text("Open any email and write in Chat with team below it. Mention @revolt or a teammate.")
                    .font(.g(12.5)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
            }
            .padding(30).frame(maxWidth: .infinity)
        }
        ForEach(visibleTeamThreads) { t in
            TeamRow(info: t, selected: store.selectedThread.map(HubStore.key) == t.key)
                .onTapGesture { if let k = hub.threadKey(from: t.key) { store.selectedThread = k } }
        }
    }

    struct Group { let title: String; let items: [ThreadSummary] }

    static func groups(_ list: [ThreadSummary]) -> [Group] {
        let cal = Calendar.current
        var out: [Group] = []
        func title(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Today" }
            if cal.isDateInYesterday(d) { return "Yesterday" }
            if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
                return d.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_US")))
            }
            return d.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))
        }
        for t in list {
            let k = title(t.date)
            if let i = out.firstIndex(where: { $0.title == k }) {
                out[i] = Group(title: k, items: out[i].items + [t])
            } else {
                out.append(Group(title: k, items: [t]))
            }
        }
        return out
    }

    private func isSelected(_ k: ThreadKey) -> Bool {
        store.isMultiSelecting ? store.multiSelection.contains(k) : store.selectedThread == k
    }

    /// Клик по строке: ⌘ добавляет к выделению, Shift выделяет диапазон, двойной клик открывает тред в своём окне.
    private func click(_ key: ThreadKey) {
        dismissSuggestions()
        let ev = NSApp.currentEvent
        let mods = ev?.modifierFlags ?? []
        if mods.contains(.shift) {
            store.selectRange(to: key, additive: mods.contains(.command))
            return
        }
        if mods.contains(.command) {
            store.toggleInSelection(key)
            return
        }
        if (ev?.clickCount ?? 1) >= 2 {
            openWindow(id: "reader", value: key)
            return
        }
        store.selectSingle(key)
        NSApp.keyWindow?.makeFirstResponder(nil)
        if store.mailbox.labelID == "DRAFT" {
            // черновик без писем в треде продолжается в окне нового письма
            Task { if await store.prepareStandaloneDraft(key), store.selectedThread == key { ui.showNewMessage = true } }
        }
    }

    private func insertOperator(_ token: String) {
        var t = store.searchText
        if !t.isEmpty && !t.hasSuffix(" ") { t += " " }
        store.searchText = t + token
        searchFocused = true
        suggestionsShown = true
    }

    private var suggestionHeight: CGFloat {
        let q = store.searchText.trimmingCharacters(in: .whitespaces)
        let recent = store.recentSearches.filter { q.isEmpty || ($0.localizedCaseInsensitiveContains(q) && $0 != q) }.count
        return min(240, CGFloat(suggestedPeople.count * 36 + (suggestedPeople.isEmpty ? 0 : 14) + 46 + (recent == 0 ? 0 : recent * 36 + 34)))
    }

    private func dismissSuggestions() {
        suggestionsShown = false
        searchFocused = false
        personIndex = -1
    }

    private var suggestedPeople: [Person] {
        guard let t = PeopleIndex.term(in: store.searchText) else { return [] }
        return store.people.matches(t)
    }

    private var pickedPerson: Person? {
        let list = suggestedPeople
        return list.indices.contains(personIndex) ? list[personIndex] : nil
    }

    private func movePerson(_ d: Int) -> KeyPress.Result {
        suggestionsShown = true
        let n = suggestedPeople.count
        guard n > 0 else { return .ignored }
        personIndex = max(-1, min(n - 1, personIndex + d))
        return .handled
    }

    private func runSearch(_ q: String) {
        personIndex = -1
        store.searchText = q
        suggestionsShown = false
        searchFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { await store.refresh(query: q) }
    }

    /// В папке Snoozed группы по сроку возврата, а не по дате письма.
    static func snoozeGroups(_ list: [ThreadSummary], store: MailStore) -> [Group] {
        let cal = Calendar.current
        var out: [Group] = []
        for t in list {
            let d = store.snoozeEntry(t.key)?.until ?? t.date
            let k: String
            if cal.isDateInToday(d) { k = "Later today" } else if cal.isDateInTomorrow(d) { k = "Tomorrow" }
            else if d.timeIntervalSinceNow < 7 * 86400 { k = "This week" } else { k = "Later" }
            if let i = out.firstIndex(where: { $0.title == k }) {
                out[i] = Group(title: k, items: out[i].items + [t])
            } else {
                out.append(Group(title: k, items: [t]))
            }
        }
        return out
    }

    @ViewBuilder private func menu(_ t: ThreadSummary) -> some View {
        let keys = store.menuKeys(for: t.key)
        let many = keys.count > 1
        let box = store.mailbox.labelID
        if many { Text("\(keys.count) conversations") }
        if !many {
            Button("Open in new window") { openWindow(id: "reader", value: t.key) }
            Divider()
        }
        Button("Archive") { store.archive(keys) }
        Button("Move to trash") { store.trash(keys) }
        if many {
            Button("Mark as read") { store.setUnread(keys, false) }
            Button("Mark as unread") { store.setUnread(keys, true) }
        } else {
            Button(t.unread ? "Mark as read" : "Mark as unread") { store.toggleUnread(t.key) }
        }
        Button(t.starred && !many ? "Unstar" : "Star") { store.toggleStar(keys) }
        Divider()
        Button("Labels...") { store.listPopover = ListPopover(kind: .labels, keys: keys) }
        Button("Move to...") { store.listPopover = ListPopover(kind: .move, keys: keys) }
        Button(store.isSnoozedBox ? "Change snooze..." : "Snooze...") { store.listPopover = ListPopover(kind: .snooze, keys: keys) }
        if store.isSnoozedBox { Button("Unsnooze now") { store.unsnooze(keys) } }
        Button(keys.allSatisfy(store.isMuted) ? "Unmute" : "Mute") { store.toggleMute(keys) }
        Divider()
        if box == "SPAM" {
            Button("Not spam") { store.notSpam(keys) }
        } else {
            Button("Report spam") { store.markSpam(keys) }
        }
        if box == "TRASH" {
            Button("Move to inbox") { keys.forEach { store.moveToInbox($0) } }
        }
        let senders = Set(keys.compactMap(store.blockableSender))
        if !senders.isEmpty {
            Button(senders.count == 1 ? "Block \(senders.first!)" : "Block \(senders.count) senders") { store.blockSenders(of: keys) }
        }
        if !many {
            Divider()
            let sender = (t.lastIncoming ?? t.lastFrom).email
            let domain = sender.split(separator: "@").last.map(String.init) ?? ""
            Button("Always important from \(sender)") { store.importance.set(sender, important: true) }
            Button("Not important from \(sender)") { store.importance.set(sender, important: false) }
            if !SenderAvatar.personal.contains(domain) {
                Button("Not important from anyone at \(domain)") { store.importance.set("@" + domain, important: false) }
            }
            Divider()
            Button("Ask Revolt") {
                store.selectSingle(t.key)
                ui.noteRequest = ("@revolt ", UUID())
            }
        }
    }
}

/// Логотип отправителя: значок домена компании, для личных ящиков инициалы.
struct SenderAvatar: View {
    let person: Person
    var size: CGFloat = 18
    static let personal: Set<String> = ["gmail.com", "googlemail.com", "yahoo.com", "outlook.com", "hotmail.com",
                                        "icloud.com", "me.com", "mail.ru", "yandex.ru", "proton.me", "protonmail.com", "live.com"]

    var domain: String? {
        guard let d = person.email.split(separator: "@").last.map(String.init), !Self.personal.contains(d) else { return nil }
        let parts = d.split(separator: ".")
        return parts.count > 2 ? parts.suffix(2).joined(separator: ".") : d
    }

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high) } else { initialsView }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
        .task(id: domain) {
            if let domain { image = await FaviconCache.shared.icon(for: domain) } else { image = nil }
        }
    }

    private var initialsView: some View {
        ZStack {
            Circle().fill(Color.avatar(for: person.email))
            Text(initials(person.short)).font(.g(size * 0.42, .semibold)).foregroundStyle(.white)
        }
    }
}

struct ThreadRow: View {
    let thread: ThreadSummary
    let selected: Bool
    let showAccount: Bool
    let team: HubThreadInfo?
    /// Срок возврата в папке Snoozed: показывается вместо даты письма.
    var wake: Date? = nil
    var muted = false
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var senders: String {
        let names = thread.participants.map { p in
            p.name.isEmpty ? p.email : p.name
        }
        return names.joined(separator: ", ")
    }

    private var fg: Color { selected ? .white : Theme.ink }
    private var fg2: Color { selected ? .white.opacity(0.75) : Theme.muted }

    /// Unread has a neutral gray surface and stronger type.
    private var rowFill: Color {
        if selected { return Theme.select }
        if thread.unread { return hover ? Theme.unreadHover : Theme.unreadBg }
        return hover ? Theme.hover : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                SenderAvatar(person: thread.lastFrom, size: 16)
                Text(senders).font(.g(14, thread.unread ? .bold : .regular)).foregroundStyle(fg).lineLimit(1)
                Spacer(minLength: 6)
                if muted { Image(systemName: "bell.slash").font(.system(size: 10)).foregroundStyle(fg2).help("Muted") }
                if let wake {
                    HStack(spacing: 3) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(Fmt.snoozeTime(wake)).font(.g(12)).monospacedDigit()
                    }
                    .foregroundStyle(selected ? .white : Theme.accentText)
                    .help("Comes back \(Fmt.snoozeTime(wake))")
                } else {
                    Text(Fmt.listDate(thread.date)).font(.g(12)).monospacedDigit().foregroundStyle(fg2)
                }
            }
            HStack(spacing: 6) {
                Text(thread.subject).font(.g(13.5, thread.unread ? .semibold : .regular)).foregroundStyle(fg).lineLimit(1)
                Spacer(minLength: 4)
                if thread.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(fg2) }
                if thread.starred { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(selected ? .white : Theme.accent) }
                if let team, team.comments > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.left.fill").font(.system(size: 9))
                        Text("\(team.comments)").font(.g(11, .medium))
                    }
                    .foregroundStyle(selected ? .white : (team.unread ? Theme.blueText : Theme.muted))
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).stroke(selected ? .white.opacity(0.5) : Theme.border))
                }
                if thread.messageCount > 1 {
                    Text("\(thread.messageCount)").font(.g(11, .medium)).foregroundStyle(fg2)
                        .padding(.horizontal, 5).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(selected ? .white.opacity(0.5) : Theme.border))
                }
            }
            if let last = team?.last {
                HStack(spacing: 5) {
                    Text(initials(last.author_name ?? "?")).font(.g(8, .semibold)).foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(last.kind == "agent" ? Theme.accent : Theme.ink2))
                    (Text((last.author_name ?? "") + " ").font(.g(13, .medium)) + Text(last.text.replacingOccurrences(of: "\n", with: " ")).font(.g(13)))
                        .foregroundStyle(fg2).lineLimit(1)
                }
            } else if !thread.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // письмо без текста не оставляет пустую строку в карточке
                Text(thread.snippet.replacingOccurrences(of: "\n", with: " ")).font(.g(13)).foregroundStyle(fg2).lineLimit(1)
            }
            if showAccount {
                Text(thread.account).font(.g(11)).foregroundStyle(selected ? .white.opacity(0.8) : Theme.muted)
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(rowFill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(thread.unread && !selected ? Theme.border : Color.clear))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(thread.unread ? "Unread" : "Read"): \(senders). \(thread.subject)")
        .accessibilityValue(selected ? "Selected" : "")
        .overlay(alignment: .leading) {
            if team != nil && !selected {
                RoundedRectangle(cornerRadius: 2).fill(Theme.blue).frame(width: 3).padding(.vertical, 10)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Theme.motion(reduceMotion), value: hover)
        .animation(Theme.motion(reduceMotion), value: selected)
    }
}

/// Строка общего обсуждения (раздел Team).
struct TeamRow: View {
    let info: HubThreadInfo
    let selected: Bool
    @State private var hover = false
    var body: some View {
        let fg: Color = selected ? .white : Theme.ink
        let fg2: Color = selected ? .white.opacity(0.75) : Theme.muted
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 11)).foregroundStyle(selected ? .white : Theme.ink2)
                Text(info.subject).font(.g(14, info.unread ? .semibold : .medium)).foregroundStyle(fg).lineLimit(1)
                Spacer()
                Text(Fmt.listDate(Date(timeIntervalSince1970: info.updated))).font(.g(12)).foregroundStyle(fg2)
            }
            if let last = info.last {
                (Text((last.author_name ?? "") + " ").font(.g(13, .medium)) + Text(last.text.replacingOccurrences(of: "\n", with: " ")).font(.g(13)))
                    .foregroundStyle(fg2).lineLimit(2)
            }
            Text(info.members.isEmpty ? info.account : "with " + info.members.map { $0.components(separatedBy: "@").first ?? $0 }.joined(separator: ", "))
                .font(.g(11.5)).foregroundStyle(selected ? .white.opacity(0.6) : Theme.faint)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.select : (hover ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Значки доменов: настоящий значок только если сервер отдал его с кодом 200, иначе инициалы.
/// Память процесса, без диска: значков в почте немного.
actor FaviconCache {
    static let shared = FaviconCache()
    private var cache: [String: NSImage?] = [:]
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    func icon(for domain: String) async -> NSImage? {
        if let hit = cache[domain] { return hit }
        if let t = inflight[domain] { return await t.value }
        let t = Task<NSImage?, Never> {
            guard let url = URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico"),
                  let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data), img.size.width >= 16 else { return nil }
            return img
        }
        inflight[domain] = t
        let img = await t.value
        cache[domain] = img
        inflight[domain] = nil
        return img
    }
}
