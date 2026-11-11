import Foundation
import Network
import Observation
import UniformTypeIdentifiers
import UserNotifications

@Observable
@MainActor
final class MailStore {
    var accounts: [Account] = [] { didSet { rebuildMe() } }
    var labels: [String: [MailLabel]] = [:]
    var mailbox: Mailbox = .inbox(nil) { didSet { if oldValue != mailbox { mailboxChanged(from: oldValue) } } }
    var threads: [ThreadSummary] = [] { didSet { people.ingest(threads, isMe: isMe) } }
    /// Адресная книга для подсказок в поиске.
    @ObservationIgnored let people = PeopleIndex()
    var selectedThread: ThreadKey? {
        didSet {
            guard oldValue != selectedThread else { return }
            // открытый тред остаётся в списке, даже если фильтр его уже не пропускает (прочитан в Unread)
            stickyKey = selectedThread
            openSelected()
        }
    }
    var details: [ThreadKey: ThreadDetail] = [:]
    /// Текст в поле поиска. В запрос он превращается только по Enter (refresh), а не на лету.
    var searchText = ""
    /// Поиск, который сейчас на экране. Его, а не недописанное поле, используют опрос, догрузка и смена папок.
    private(set) var activeQuery = ""
    /// Freeze the expanded query for pagination; new contacts must not change page-token semantics.
    private var activeGmailQuery = ""
    var filter = ListFilter.all
    enum ListFilter: String, CaseIterable { case all, unread, starred }

    let importance = Importance()
    var isImportantBox: Bool { mailbox.labelID == "IMPORTANT_RV" }

    /// Тред, который держится в отфильтрованном списке, пока он выбран.
    private var stickyKey: ThreadKey?

    var visibleThreads: [ThreadSummary] {
        let keep = stickyKey
        var base = isImportantBox && activeQuery.isEmpty ? threads.filter { $0.key == keep || importance.isImportant($0, isMe: isMe) } : threads
        // в Drafts строка это сам черновик: его время, его текст, свежие сверху (дата треда осталась бы от старого письма)
        if mailbox.labelID == "DRAFT" && activeQuery.isEmpty {
            base = base.map { t in
                var d = t
                if let dd = t.draftDate { d.date = dd }
                if let ds = t.draftSnippet, !ds.isEmpty { d.snippet = ds }
                return d
            }.sorted { $0.date > $1.date }
        }
        switch filter {
        case .all: return base
        case .unread: return base.filter { $0.unread || $0.key == keep }
        case .starred: return base.filter { $0.starred || $0.key == keep }
        }
    }

    /// Строки командной папки (Team). Их ставит экран хаба; по ним ходят J/K, пока открыт Team.
    var teamKeys: [ThreadKey] = []
    /// Порядок, по которому ходят J/K и стрелки: в Team это треды хаба, иначе видимый список.
    var navigableKeys: [ThreadKey] { mailbox.labelID == "TEAM" ? teamKeys : visibleThreads.map(\.key) }

    /// Непрочитанные важные во входящих (для счётчика в меню).
    var importantUnread: Int {
        let live = isImportantBox || mailbox == .inbox(nil)
        let src = live && activeQuery.isEmpty ? threads : (listCache[Mailbox.inbox(nil).key] ?? [])
        return src.filter { $0.unread && $0.labelIDs.contains("INBOX") && importance.isImportant($0, isMe: isMe) }.count
    }

    var isLoading = false
    var isLoadingMore = false
    /// Есть ли сеть. Без сети опросы стоят, ошибок не показываем, при возврате связи сразу обновляемся.
    var isOnline = true
    private let pathMonitor = NWPathMonitor()
    var error: String?
    var hasMore: Bool { nextTokens.values.contains { $0 != nil } }

    /// Ящики, где Google сбросил вход. Для них опрос стоит, в боковой панели кнопка «Sign in again».
    var expiredAccounts: Set<String> = []
    /// Адреса отправки каждого ящика (основной и псевдонимы из Send mail as).
    var aliases: [String: [Person]] = [:] { didSet { rebuildMe() } }
    private var sendAsList: [String: [SendAs]] = [:]

    /// Недописанные ответы по тредам: переживают переход к другому треду и перезапуск.
    var replyDrafts: [ThreadKey: ReplyDraft] = [:]
    /// Письмо, ждущее отправки несколько секунд (кнопка Undo).
    var pendingSend: PendingSend?

    /// Выделение нескольких тредов (⌘-клик, Shift-клик, ⌘A). Пусто или два и больше: один тред это selectedThread.
    var multiSelection: Set<ThreadKey> = []
    /// Точка отсчёта для Shift-клика.
    var selectionAnchor: ThreadKey?
    /// Открытое окно меток, переноса или отложения над списком.
    var listPopover: ListPopover?
    /// Отложенные треды (Snooze), живут в Application Support/snoozes.json.
    var snoozes: [SnoozeEntry] = []
    /// Заглушённые треды (ключ треда строкой): новые письма в них сами уходят в архив.
    var mutedThreads: Set<String> = []
    /// Заблокированные отправители: их новые письма сами уходят в корзину.
    var blockedSenders: [BlockedSender] = []
    /// Последние поиски, новые сверху, не больше десяти.
    var recentSearches: [String] = []
    /// Когда правило (заглушить, блок) последний раз применялось к треду: сбой не превращается в бесконечный повтор.
    @ObservationIgnored var ruleAppliedAt: [ThreadKey: Date] = [:]
    @ObservationIgnored var snoozeTimer: Task<Void, Never>?

    private var clients: [String: GmailClient] = [:]
    private var nextTokens: [String: String?] = [:]
    /// Все загруженные строки текущей папки по аккаунтам (первая страница и догруженные).
    var pageRows: [String: [ThreadSummary]] = [:]
    /// Для какой папки и какого поиска собраны pageRows и nextTokens.
    private var pagedFor: PageContext?
    var listCache: [String: [ThreadSummary]] = [:]
    /// Уже показанные уведомления: тред плюс число писем, чтобы новый ответ в старом треде тоже звенел.
    private var notified = Set<String>()
    private var pollTask: Task<Void, Never>?
    private var historyIDs: [String: String] = [:]
    private var loadGeneration = 0
    var labelsGen = 0
    /// Мои действия, ещё не дошедшие до Gmail: обновление списка их не перетирает.
    var pendingOps: [ThreadKey: PendingOp] = [:]
    private var inFlightDetails: Set<ThreadKey> = []
    @ObservationIgnored private var myAddresses: Set<String> = []
    @ObservationIgnored private var inlineCache: [String: String] = [:]
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var draftSyncTasks: [ThreadKey: Task<Void, Never>] = [:]

    struct PageContext: Equatable { var box: String; var query: String }

    struct PendingOp {
        /// Ярлыки, из папок которых тред убран ("*" значит отовсюду, кроме корзины).
        var removedFrom: Set<String> = []
        var unread: Bool?
        var starred: Bool?
        var until: Date = Date().addingTimeInterval(30)
    }

    /// Отложенная отправка: всё, что нужно для письма, и таймер.
    struct PendingSend: Identifiable {
        let id = UUID()
        let account: String
        let to: [Person], cc: [Person], bcc: [Person]
        let subject: String
        let body: String
        let bodyHTML: String?
        let replyTo: MailMessage?
        let threadID: String?
        let attachments: [URL]
        let forwardFrom: MailMessage?
        let from: Person?
        let draftID: String?
        let fireAt: Date
        fileprivate(set) var timer: Task<Void, Never>?

        var threadKey: ThreadKey? { threadID.map { ThreadKey(account: account, threadID: $0) } }
        var title: String { "Sending to \(to.first?.short ?? cc.first?.short ?? "recipients")" }
    }

    private static let accountsURL = AppPaths.file("accounts.json")
    private static let listCacheURL = AppPaths.cacheDir.appendingPathComponent("lists2.json")
    private static let replyDraftsURL = AppPaths.file("reply_drafts.json")
    private static let detailsDir: URL = {
        let dir = AppPaths.cacheDir.appendingPathComponent("details", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        if DevTools.isDemo {
            let d = DevTools.demo()
            accounts = d.accounts; threads = d.threads; details = d.details; labels = d.labels
            // RVM_DEMO_THREAD=<файл из cache/details>: настоящий тред первым и выбранным, чтобы снять вёрстку живого письма
            if let path = ProcessInfo.processInfo.environment["RVM_DEMO_THREAD"],
               let t = JSONFile.load(ThreadDetail.self, from: URL(fileURLWithPath: path)), let last = t.messages.last {
                details[t.key] = t
                threads.insert(ThreadSummary(account: t.account, id: t.id, subject: t.subject, snippet: last.snippet,
                                             participants: t.messages.map(\.from), lastFrom: last.from, date: last.date,
                                             messageCount: t.messages.count, unread: false, starred: false, hasAttachments: false,
                                             labelIDs: t.labelIDs, bulk: false, toMe: true, lastIncoming: last.from), at: 0)
            }
            if ProcessInfo.processInfo.environment["RVM_SELECT"] != nil { selectedThread = threads.first?.key }
            people.ingest(threads, isMe: isMe)
            if let q = ProcessInfo.processInfo.environment["RVM_SEARCH"] { searchText = q }
            if ProcessInfo.processInfo.environment["RVM_SNOOZE"] != nil, let k = threads.first?.key {
                listPopover = ListPopover(kind: .snooze, keys: [k])
            }
            return
        }
        accounts = JSONFile.load([Account].self, from: Self.accountsURL) ?? []
        loadLocalRules()
        listCache = JSONFile.load([String: [ThreadSummary]].self, from: Self.listCacheURL) ?? [:]
        let savedDrafts = JSONFile.load([String: ReplyDraft].self, from: Self.replyDraftsURL) ?? [:]
        for (k, v) in savedDrafts {
            let parts = k.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 { replyDrafts[ThreadKey(account: parts[0], threadID: parts[1])] = v }
        }
        for a in accounts { clients[a.email] = GmailClient(account: a.email) }
        for list in listCache.values { people.ingest(list, isMe: isMe) }
        threads = listCache[mailbox.key] ?? []
        notified = Set(threads.filter(\.unread).map(notifyTag))
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }
        startPolling()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                if online && !self.isOnline { self.isOnline = true; await self.reload() } else if !online { self.isOnline = false }
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        importance.refreshContacts(accounts.map { client($0.email) })
        Self.pruneDetailCache()
        Task {
            await loadSendAs()
            for (i, a) in accounts.enumerated() where a.displayName.isEmpty {
                let name = await client(a.email).senderName()
                if !name.isEmpty, accounts.indices.contains(i) { accounts[i].displayName = name }
            }
            saveAccounts()
            await reload()
            startSnoozeTimer()
        }
    }

    var hasGoogleClient: Bool { DevTools.isDemo || GoogleClientConfig.load() != nil }

    func client(_ account: String) -> GmailClient {
        if let c = clients[account] { return c }
        let c = GmailClient(account: account)
        clients[account] = c
        return c
    }

    var selectedSummary: ThreadSummary? { threads.first { $0.key == selectedThread } }
    var selectedDetail: ThreadDetail? { selectedThread.flatMap { details[$0] } }

    private func saveAccounts() {
        let copy = accounts
        let url = Self.accountsURL
        DiskQueue.write { JSONFile.save(copy, to: url) }
    }

    func saveListCache() {
        let copy = listCache
        let url = Self.listCacheURL
        DiskQueue.write { JSONFile.save(copy, to: url) }
    }

    // MARK: Аккаунты

    func addAccount() async {
        guard let cfg = GoogleClientConfig.load() else { error = OAuthError.noClient.errorDescription; return }
        do {
            let (email, tokens) = try await GoogleOAuth.signIn(config: cfg)
            await finishSignIn(email: email, tokens: tokens)
        } catch {
            reportSignInError(error)
        }
    }

    /// Повторный вход в конкретный ящик (Google сбросил вход). Google сразу предлагает нужный адрес.
    func relogin(_ account: String) async {
        guard let cfg = GoogleClientConfig.load() else { error = OAuthError.noClient.errorDescription; return }
        do {
            let (email, tokens) = try await GoogleOAuth.signIn(config: cfg, loginHint: account)
            await finishSignIn(email: email, tokens: tokens)
            if email != account.lowercased() {
                error = "You signed in as \(email), not \(account). \(account) still needs to sign in again."
            }
        } catch {
            reportSignInError(error)
        }
    }

    private func finishSignIn(email: String, tokens: OAuthTokens) async {
        Keychain.save(tokens, for: email)
        if let c = clients[email] { await c.reloadTokens() } else { clients[email] = GmailClient(account: email) }
        expiredAccounts.remove(email)
        historyIDs[email] = nil
        if error?.contains(email) == true { error = nil }
        if !accounts.contains(where: { $0.email == email }) {
            let name = await client(email).senderName()
            accounts.append(Account(email: email, displayName: name))
            saveAccounts()
            importance.refreshContacts([client(email)])
        }
        await loadSendAs(email)
        await reload()
    }

    private func reportSignInError(_ error: Error) {
        // отмена человеком это не ошибка
        if error is CancellationError { return }
        if let e = error as? OAuthError, case .cancelled = e { return }
        self.error = error.localizedDescription
    }

    /// Ошибка вызова Gmail: истёкший вход помечает ящик и говорит об этом один раз, а не на каждом опросе.
    func handle(_ error: Error, account: String?) {
        if let g = error as? GmailError, g.needsLogin, let account {
            if !expiredAccounts.contains(account) {
                expiredAccounts.insert(account)
                self.error = g.localizedDescription
            }
            return
        }
        if error is URLError || error is CancellationError { return }
        self.error = error.localizedDescription
    }

    func removeAccount(_ email: String) {
        accounts.removeAll { $0.email == email }
        clients[email] = nil
        labels[email] = nil
        aliases[email] = nil
        sendAsList[email] = nil
        nextTokens[email] = nil
        pageRows[email] = nil
        historyIDs[email] = nil
        expiredAccounts.remove(email)
        Keychain.delete(for: email)
        saveAccounts()
        threads.removeAll { $0.account == email }
        details = details.filter { $0.key.account != email }
        replyDrafts = replyDrafts.filter { $0.key.account != email }
        persistReplyDrafts()
        for k in listCache.keys { listCache[k]?.removeAll { $0.account == email } }
        listCache = listCache.filter { !$0.key.hasPrefix(email + "|") }
        saveListCache()
        if selectedThread?.account == email { selectedThread = nil }
        multiSelection = multiSelection.filter { $0.account != email }
        if multiSelection.count < 2 { multiSelection = [] }
        snoozes.removeAll { $0.key.account == email }
        mutedThreads = mutedThreads.filter { !$0.hasPrefix(email + "/") }
        saveLocalRules()
        if mailbox.account == email { mailbox = .inbox(nil) }
    }

    func setDisplayName(_ name: String, for email: String) {
        guard let i = accounts.firstIndex(where: { $0.email == email }) else { return }
        accounts[i].displayName = name
        saveAccounts()
    }

    func me(_ account: String) -> Person {
        let name = accounts.first { $0.email == account }?.displayName ?? ""
        return Person(name: name, email: account)
    }

    /// Я это любой мой ящик и любой его псевдоним (Send mail as), с учётом точек и плюс-хвостов Gmail.
    func isMe(_ email: String) -> Bool {
        if myAddresses.isEmpty { rebuildMe() }
        return myAddresses.contains(Person.normalized(email))
    }

    private func rebuildMe() {
        var set = Set(accounts.map { Person.normalized($0.email) })
        for list in aliases.values { list.forEach { set.insert(Person.normalized($0.email)) } }
        if set != myAddresses {
            myAddresses = set
            importance.invalidate()
        }
    }

    /// Подпись (HTML) для ящика или его псевдонима: у рабочего своя, у остальных из Gmail. nil, если подписи нет.
    func signature(for account: String) -> String? {
        let e = account.lowercased()
        for list in sendAsList.values {
            if let s = list.first(where: { $0.email == e }), !s.signature.isEmpty { return s.signature }
        }
        if let list = sendAsList[e] {
            let def = list.first { $0.isDefault } ?? list.first { $0.isPrimary }
            if let sig = def?.signature, !sig.isEmpty { return sig }
        }
        return nil
    }

    /// Адрес «От» по умолчанию: псевдоним, на который пришло письмо, иначе адрес по умолчанию из Gmail.
    func defaultFrom(account: String, replyingTo m: MailMessage? = nil) -> Person {
        let list = sendAsList[account] ?? []
        if let m {
            let rcpt = Set((m.to + m.cc).map { Person.normalized($0.email) })
            if let hit = list.first(where: { rcpt.contains(Person.normalized($0.email)) }) {
                return Person(name: hit.displayName.isEmpty ? me(account).name : hit.displayName, email: hit.email)
            }
        }
        if let def = list.first(where: { $0.isDefault }), def.email != account.lowercased() {
            return Person(name: def.displayName.isEmpty ? me(account).name : def.displayName, email: def.email)
        }
        return me(account)
    }

    private func loadSendAs(_ only: String? = nil) async {
        for acc in only.map({ [$0] }) ?? accounts.map(\.email) {
            let list = await client(acc).sendAs(force: only != nil)
            guard !list.isEmpty, accounts.contains(where: { $0.email == acc }) else { continue }
            sendAsList[acc] = list
            let people = list.map { Person(name: $0.displayName, email: $0.email) }
            if aliases[acc] != people { aliases[acc] = people }
        }
    }

    // MARK: Список

    private func mailboxChanged(from old: Mailbox) {
        if DevTools.isDemo { return }
        // живой список уходящей папки (прочитанное, архивированное) запоминается, чтобы возврат не показал старое
        if old.labelID != "TEAM", activeQuery.isEmpty, pagedFor?.box == old.key {
            listCache[old.key] = Array(threads.prefix(80))
        }
        searchText = ""
        activeQuery = ""
        activeGmailQuery = ""
        nextTokens = [:]
        pageRows = [:]
        pagedFor = nil
        stickyKey = nil
        multiSelection = []
        selectionAnchor = nil
        listPopover = nil
        loadGeneration += 1
        isLoading = false
        if mailbox.labelID == "TEAM" { return }
        if mailbox.labelID == Self.snoozedBox {
            selectedThread = nil
            refreshSnoozedList()
            return
        }
        threads = applyPending(listCache[mailbox.key] ?? [], box: mailbox)
        selectedThread = nil
        Task { await reload() }
    }

    /// Ящики, у которых можно спросить людей для подсказок поиска.
    var searchClients: [GmailClient] {
        DevTools.isDemo ? [] : accounts.map(\.email).filter { !expiredAccounts.contains($0) }.map { client($0) }
    }

    private var targetAccounts: [String] { mailbox.account.map { [$0] } ?? accounts.map(\.email) }

    func gmailLabel(_ box: Mailbox) -> String { MailSearch.label(mailbox: box.labelID, query: activeQuery) }

    /// Обновить список по действию человека: Enter в поиске, кнопка, сочетание клавиш.
    /// Текст поля поиска становится запросом именно здесь.
    func refresh(query submitted: String? = nil, remember: Bool = true) async {
        let query = (submitted ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = query != activeQuery
        activeQuery = query
        if changed {
            activeGmailQuery = MailSearch.gmailQuery(query, matchingEmails: people.matches(query).map(\.email))
            loadGeneration += 1
            isLoading = false
            nextTokens = [:]; pageRows = [:]; pagedFor = nil
            multiSelection = []; selectionAnchor = nil; stickyKey = nil
            selectedThread = nil
            // Do not present the old query's results as matches for the new query.
            if !DevTools.isDemo { threads = query.isEmpty ? (listCache[mailbox.key] ?? []) : [] }
            error = nil
        }
        if remember, !activeQuery.isEmpty { addRecentSearch(activeQuery) }
        await reload()
    }

    /// Перечитать текущую папку с текущим запросом.
    func reload() async {
        guard !accounts.isEmpty, !DevTools.isDemo, mailbox.labelID != "TEAM", isOnline else { return }
        if mailbox.labelID == Self.snoozedBox && activeQuery.isEmpty { refreshSnoozedList(); return }
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        defer { if gen == loadGeneration { isLoading = false } }
        let box = mailbox
        let query = activeQuery
        let gmailQuery = activeGmailQuery
        let ctx = PageContext(box: box.key, query: query)
        let same = pagedFor == ctx
        let label = gmailLabel(box)
        // догруженные строки перечитываются тем же объёмом: прочитанное и архивированное на телефоне не залипает
        var want: [String: Int] = [:]
        let accs = targetAccounts.filter { !expiredAccounts.contains($0) }
        for acc in accs { want[acc] = same ? min(200, max(40, pageRows[acc]?.count ?? 0)) : 40 }

        typealias Res = (acc: String, result: Result<([ThreadSummary], String?), Error>, history: String?)
        var results: [Res] = []
        await withTaskGroup(of: Res.self) { group in
            for acc in accs {
                let c = client(acc)
                let n = want[acc] ?? 40
                group.addTask {
                    // точка отсчёта опроса берётся до списка: что придёт после, опрос увидит
                    let hid = try? await c.historyID()
                    do {
                        let r = try await c.listThreads(labelID: label, query: gmailQuery, pageToken: nil, max: n)
                        return (acc, .success(r), hid)
                    } catch {
                        return (acc, .failure(error), hid)
                    }
                }
            }
            for await r in group { results.append(r) }
        }
        guard !Task.isCancelled, gen == loadGeneration, box == mailbox, query == activeQuery else { return }

        var rows: [String: [ThreadSummary]] = same ? pageRows : [:]
        var tokens: [String: String?] = same ? nextTokens : [:]
        var shownError: String?
        for r in results {
            if let h = r.history { historyIDs[r.acc] = h }
            switch r.result {
            case .success(let (list, next)):
                var fresh = list
                // строки старше перечитанного окна (догружали больше 200) оставляем, пока у аккаунта есть ещё страницы
                if same, next != nil, let oldest = list.map(\.date).min() {
                    let keys = Set(list.map(\.key))
                    fresh += (pageRows[r.acc] ?? []).filter { $0.date < oldest && !keys.contains($0.key) }
                }
                rows[r.acc] = fresh
                tokens[r.acc] = next
                expiredAccounts.remove(r.acc)
            case .failure(let e):
                // упавший аккаунт остаётся с тем, что было на экране
                if !same {
                    rows[r.acc] = query.isEmpty ? threads.filter { $0.account == r.acc } : []
                    tokens[r.acc] = .some(nil)
                }
                if let g = e as? GmailError, g.needsLogin { handle(e, account: r.acc) }
                else if !(e is CancellationError), shownError == nil { shownError = e.localizedDescription }
                AppLog.write("refresh list \(r.acc): \(e.localizedDescription)")
            }
        }
        // ящик с истёкшим входом не опрашивается, но его строки остаются на экране до повторного входа
        for acc in targetAccounts where expiredAccounts.contains(acc) && rows[acc] == nil {
            rows[acc] = query.isEmpty ? threads.filter { $0.account == acc } : []
            tokens[acc] = .some(nil)
        }
        // ящики вне выборки (вышли из аккаунта, другая папка) сюда не попадают
        let allowed = Set(targetAccounts)
        rows = rows.filter { allowed.contains($0.key) }
        tokens = tokens.filter { allowed.contains($0.key) }
        pageRows = rows
        nextTokens = tokens
        pagedFor = ctx
        let merged = composeThreads(box: box)
        if merged != threads { threads = merged }
        enforceLocalRules(merged)
        if let shownError, error != shownError { error = shownError }
        if query.isEmpty {
            let top = Array(merged.prefix(80))
            if listCache[box.key] != top {
                listCache[box.key] = top
                if box.labelID == "INBOX" && box.account == nil { listCache[Mailbox(account: nil, labelID: "IMPORTANT_RV", title: "Important").key] = top }
                if box.labelID == "IMPORTANT_RV" && box.account == nil { listCache[Mailbox.inbox(nil).key] = top }
                saveListCache()
            }
        }
        if (box.labelID == "INBOX" || box.labelID == "IMPORTANT_RV") && query.isEmpty {
            notifyNew(merged)
            importance.evaluate(merged, isMe: { [weak self] e in self?.isMe(e) ?? false })
            importance.writeReport(merged, isMe: isMe)
            prefetchTop()
        }
        Task { await refreshLabels() }
        // открытый тред тоже мог получить новое письмо
        if let sel = selectedThread, let s = merged.first(where: { $0.key == sel }),
           let d = details[sel], d.sentMessages.count != s.messageCount {
            await loadDetail(sel)
        }
    }

    /// Самая новая дата, до которой список полный: ниже неё у какого-то аккаунта ещё не загружена страница.
    /// Строки старше этой даты держим в запасе, чтобы догрузка добавляла письма только снизу.
    private func horizon() -> Date {
        var h = Date.distantPast
        for (acc, rows) in pageRows where (nextTokens[acc] ?? nil) != nil {
            if let oldest = rows.map(\.date).min() { h = max(h, oldest) }
        }
        return h
    }

    private func composeThreads(box: Mailbox) -> [ThreadSummary] {
        let h = horizon()
        var seen = Set<ThreadKey>()
        var out: [ThreadSummary] = []
        for rows in pageRows.values {
            for t in rows where t.date >= h && !seen.contains(t.key) {
                seen.insert(t.key)
                out.append(t)
            }
        }
        out.sort { $0.date > $1.date }
        return applyPending(out, box: box)
    }

    /// Наложить мои ещё не дошедшие до Gmail действия на свежие данные сервера.
    private func applyPending(_ list: [ThreadSummary], box: Mailbox) -> [ThreadSummary] {
        let now = Date()
        pendingOps = pendingOps.filter { $0.value.until > now }
        guard !pendingOps.isEmpty else { return list }
        return list.compactMap { t in
            guard let op = pendingOps[t.key] else { return t }
            if (activeQuery.isEmpty && op.removedFrom.contains(box.labelID)) || (op.removedFrom.contains("*") && box.labelID != "TRASH") { return nil }
            if activeQuery.isEmpty, op.removedFrom.contains("INBOX"), box.labelID == "IMPORTANT_RV" { return nil }
            var t = t
            if let u = op.unread { t.unread = u }
            if let s = op.starred { t.starred = s }
            return t
        }
    }

    func loadMore() async {
        guard !isLoading, isOnline, !isLoadingMore, hasMore, !DevTools.isDemo, mailbox.labelID != "TEAM" else { return }
        let box = mailbox
        let query = activeQuery
        let gmailQuery = activeGmailQuery
        let ctx = PageContext(box: box.key, query: query)
        guard pagedFor == ctx else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let h = horizon()
        // догружаем только те ящики, что держат горизонт; остальные и так глубже
        let targets: [(String, String)] = nextTokens.compactMap { acc, tok in
            guard let tok, accounts.contains(where: { $0.email == acc }), !expiredAccounts.contains(acc) else { return nil }
            let oldest = pageRows[acc]?.map(\.date).min() ?? .distantFuture
            return oldest >= h ? (acc, tok) : nil
        }
        guard !targets.isEmpty else { return }
        let label = gmailLabel(box)
        var results: [(String, String, Result<([ThreadSummary], String?), Error>)] = []
        await withTaskGroup(of: (String, String, Result<([ThreadSummary], String?), Error>).self) { group in
            for (acc, tok) in targets {
                let c = client(acc)
                group.addTask {
                    do { return (acc, tok, .success(try await c.listThreads(labelID: label, query: gmailQuery, pageToken: tok))) }
                    catch { return (acc, tok, .failure(error)) }
                }
            }
            for await r in group { results.append(r) }
        }
        // пока грузили, человек ушёл в другую папку или сменил поиск: чужое не вклеиваем
        guard box == mailbox, query == activeQuery, pagedFor == ctx else { return }
        for (acc, tok, r) in results {
            // токен успел смениться (папку перечитали): эта страница уже не по адресу
            guard (nextTokens[acc] ?? nil) == tok else { continue }
            switch r {
            case .success(let (list, next)):
                let known = Set((pageRows[acc] ?? []).map(\.key))
                pageRows[acc, default: []] += list.filter { !known.contains($0.key) }
                nextTokens[acc] = next
            case .failure(let e):
                handle(e, account: acc)
            }
        }
        let merged = composeThreads(box: box)
        if merged != threads { threads = merged }
    }

    func refreshLabels() async {
        labelsGen += 1
        let g = labelsGen
        var got: [String: [MailLabel]] = [:]
        await withTaskGroup(of: (String, [MailLabel]?).self) { group in
            for acc in accounts.map(\.email) where !expiredAccounts.contains(acc) {
                let c = client(acc)
                group.addTask { (acc, try? await c.labels()) }
            }
            for await (acc, l) in group { if let l { got[acc] = l } }
        }
        // ответ устарел: пока он шёл, был запрос новее или счётчик поменялся на экране
        guard g == labelsGen else { return }
        for (acc, l) in got where labels[acc] != l { labels[acc] = l }
    }

    /// Счётчик непрочитанного во «Входящих» сразу на экране, не дожидаясь Gmail.
    func bumpInboxUnread(_ account: String, by delta: Int) {
        // читать и писать одно наблюдаемое свойство в одном выражении нельзя: Swift падает (exclusivity)
        guard var list = labels[account], let i = list.firstIndex(where: { $0.id == "INBOX" }) else { return }
        list[i].unread = max(0, list[i].unread + delta)
        labels[account] = list
        labelsGen += 1   // уже летящий ответ со старым числом не перетрёт
    }

    func totalInbox(_ account: String?) -> Int {
        if let account { return labels[account]?.first { $0.id == "INBOX" }?.total ?? 0 }
        return accounts.reduce(0) { $0 + totalInbox($1.email) }
    }

    func unreadInbox(_ account: String?) -> Int {
        if let account { return labels[account]?.first { $0.id == "INBOX" }?.unread ?? 0 }
        return accounts.reduce(0) { $0 + unreadInbox($1.email) }
    }

    func userLabels(_ account: String) -> [MailLabel] {
        (labels[account] ?? []).filter { $0.type == "user" }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Лёгкий опрос: раз в 20 секунд один запрос history на ящик, список перекачивается только при изменениях
    /// и раз в 10 минут на всякий случай. Работает при любой открытой папке и при любом тексте в поиске.
    private func startPolling() {
        pollTask = Task { [weak self] in
            var lastFull = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                guard let self, !self.accounts.isEmpty, self.isOnline else { continue }
                var changed = Date().timeIntervalSince(lastFull) > 600
                for acc in self.accounts.map(\.email) where !self.expiredAccounts.contains(acc) {
                    let c = self.client(acc)
                    if let since = self.historyIDs[acc] {
                        do {
                            let (diff, newID) = try await c.hasChanges(since: since)
                            self.historyIDs[acc] = newID
                            if diff { changed = true }
                        } catch is URLError {
                            // нет связи: точку отсчёта не теряем, изменения увидим, когда сеть вернётся
                        } catch {
                            if let g = error as? GmailError, g.needsLogin { self.handle(error, account: acc); continue }
                            // старый historyId (Mac спал) или сбой: перечитываем список, иначе всё между ними потеряется
                            self.historyIDs[acc] = try? await c.historyID()
                            changed = true
                        }
                    } else if let id = try? await c.historyID() {
                        self.historyIDs[acc] = id
                        changed = true
                    }
                }
                if changed {
                    lastFull = Date()
                    await self.pollRefresh()
                }
            }
        }
    }

    /// Что делает опрос при изменениях: видимую папку обновляет, если это не поиск и не Team,
    /// а входящие всех ящиков читает всегда, ради уведомлений и счётчиков.
    private func pollRefresh() async {
        let visibleUnifiedInbox = (mailbox == .inbox(nil) || (isImportantBox && mailbox.account == nil)) && activeQuery.isEmpty
        if mailbox.labelID != "TEAM", activeQuery.isEmpty { await reload() }
        if !visibleUnifiedInbox { await refreshInboxInBackground() }
    }

    /// Входящие всех ящиков в фоне: в кэш, в уведомления и в счётчик «Важного». Видимый список не трогается.
    private func refreshInboxInBackground() async {
        guard !DevTools.isDemo, isOnline else { return }
        let key = Mailbox.inbox(nil).key
        let accs = accounts.map(\.email).filter { !expiredAccounts.contains($0) }
        var got: [String: [ThreadSummary]] = [:]
        await withTaskGroup(of: (String, Result<[ThreadSummary], Error>).self) { group in
            for acc in accs {
                let c = client(acc)
                group.addTask {
                    do { return (acc, .success(try await c.listThreads(labelID: "INBOX", query: "", pageToken: nil).0)) }
                    catch { return (acc, .failure(error)) }
                }
            }
            for await (acc, r) in group {
                switch r {
                case .success(let l): got[acc] = l
                case .failure(let e): handle(e, account: acc)
                }
            }
        }
        guard !got.isEmpty else { return }
        let old = listCache[key] ?? []
        var merged = got.values.flatMap { $0 }
        // упавшие ящики остаются в кэше с прежними строками
        let live = Set(accounts.map(\.email))
        merged += old.filter { got[$0.account] == nil && live.contains($0.account) }
        merged.sort { $0.date > $1.date }
        let list = applyPending(Array(merged.prefix(80)), box: .inbox(nil))
        if listCache[key] != list {
            listCache[key] = list
            listCache[Mailbox(account: nil, labelID: "IMPORTANT_RV", title: "Important").key] = list
            saveListCache()
        }
        notifyNew(list)
        importance.evaluate(list, isMe: { [weak self] e in self?.isMe(e) ?? false })
        enforceLocalRules(list)
    }

    private func notifyTag(_ t: ThreadSummary) -> String { "\(t.key.string)#\(t.messageCount)" }

    private func notifyNew(_ list: [ThreadSummary]) {
        let unread = list.filter(\.unread)
        let fresh = unread.filter {
            !notified.contains(notifyTag($0)) && Date().timeIntervalSince($0.date) < 3600
                && !isMe($0.lastFrom.email) && $0.key != selectedThread && !hitsLocalRule($0)
        }
        notified.formUnion(unread.map(notifyTag))
        if notified.count > 5000 { notified = Set(unread.map(notifyTag)) }
        guard Bundle.main.bundleIdentifier != nil else { return }
        for t in fresh.prefix(3) {
            let c = UNMutableNotificationContent()
            c.title = t.lastFrom.short
            c.subtitle = t.subject
            c.body = t.snippet
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notifyTag(t), content: c, trigger: nil))
        }
    }

    // MARK: Тред

    private func openSelected() {
        guard let key = selectedThread, !DevTools.isDemo, accounts.contains(where: { $0.email == key.account }) else { return }
        // прочитано сразу на экране, запрос в фоне
        if let t = threads.first(where: { $0.key == key }), t.unread { setUnread(key, false) }
        Task {
            if details[key] == nil, let d = await Self.loadDetailFromDisk(key), details[key] == nil { details[key] = d }
            // письмо уже предзагружено и не менялось: сеть не трогаем
            let summary = threads.first { $0.key == key }
            if let d = details[key], let summary, d.sentMessages.count == summary.messageCount {
                prefetchNeighbors(of: key)
                return
            }
            await loadDetail(key)
            prefetchNeighbors(of: key)
        }
    }

    /// Пока читаешь письмо, три следующих (и одно предыдущее) тихо подгружаются: J/K открывают мгновенно.
    private func prefetchNeighbors(of key: ThreadKey) {
        let list = visibleThreads
        guard let i = list.firstIndex(where: { $0.key == key }) else { return }
        let around = [i + 1, i + 2, i + 3, i - 1].filter { list.indices.contains($0) }.map { list[$0] }
        for t in around { prefetch(t) }
        trimDetails(keeping: key)
    }

    /// Первые двадцать писем входящих (непрочитанные первыми) подгружаются заранее, по три за раз.
    private func prefetchTop() {
        let top = visibleThreads.prefix(30)
        let ordered = (top.filter(\.unread) + top.filter { !$0.unread }).prefix(20)
        let todo = ordered.filter { t in
            !inFlightDetails.contains(t.key) && (details[t.key].map { $0.sentMessages.count != t.messageCount } ?? true)
        }
        guard !todo.isEmpty else { return }
        Task {
            var it = Array(todo).makeIterator()
            await withTaskGroup(of: Void.self) { group in
                func next() {
                    guard let t = it.next() else { return }
                    group.addTask { await self.fetchDetail(t) }
                }
                for _ in 0..<3 { next() }
                while await group.next() != nil { next() }
            }
        }
    }

    private func prefetch(_ t: ThreadSummary) {
        guard !inFlightDetails.contains(t.key), accounts.contains(where: { $0.email == t.account }) else { return }
        if let d = details[t.key], d.sentMessages.count == t.messageCount { return }
        Task { await fetchDetail(t) }
    }

    /// Тред с диска, если там свежая версия, иначе из сети. Один запрос на тред за раз.
    private func fetchDetail(_ t: ThreadSummary) async {
        guard !inFlightDetails.contains(t.key) else { return }
        inFlightDetails.insert(t.key)
        defer { inFlightDetails.remove(t.key) }
        if details[t.key] == nil, let d = await Self.loadDetailFromDisk(t.key), d.sentMessages.count == t.messageCount {
            if details[t.key] == nil { details[t.key] = d }
            return
        }
        if let d = try? await client(t.account).thread(id: t.id) {
            if details[t.key] != d { details[t.key] = d }
            Self.saveDetailToDisk(d)
        }
    }

    private func trimDetails(keeping key: ThreadKey) {
        guard details.count > 200 else { return }   // память не копим: держим ближайшие
        let keep = Set(visibleThreads.prefix(60).map(\.key)).union([key]).union(selectedThread.map { [$0] } ?? [])
        details = details.filter { keep.contains($0.key) }
    }

    func loadDetail(_ key: ThreadKey) async {
        do {
            let d = try await client(key.account).thread(id: key.threadID)
            if details[key] != d { details[key] = d }
            Self.saveDetailToDisk(d)
        } catch is URLError {
            // без сети остаётся то, что уже загружено (или лежит на диске)
            if details[key] == nil, let d = await Self.loadDetailFromDisk(key) { details[key] = d }
        } catch {
            handle(error, account: key.account)
        }
    }

    private static func detailURL(_ key: ThreadKey) -> URL {
        let safe = (key.account + "_" + key.threadID).replacingOccurrences(of: "[^A-Za-z0-9@._-]", with: "_", options: .regularExpression)
        return detailsDir.appendingPathComponent(safe + ".json")
    }

    private static func saveDetailToDisk(_ d: ThreadDetail) {
        let url = detailURL(d.key)
        DiskQueue.write { JSONFile.save(d, to: url) }
    }

    private static func loadDetailFromDisk(_ key: ThreadKey) async -> ThreadDetail? {
        let url = detailURL(key)
        return await Task.detached(priority: .userInitiated) { JSONFile.load(ThreadDetail.self, from: url) }.value
    }

    /// Тела старше 30 дней с диска убираются, чтобы кэш не рос бесконечно.
    private static func pruneDetailCache() {
        let dir = detailsDir
        DiskQueue.write {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let limit = Date().addingTimeInterval(-30 * 86400)
            for f in files {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if d < limit { try? fm.removeItem(at: f) }
            }
        }
    }

    // MARK: Действия

    /// Последнее действие, которое можно отменить (z или кнопка Undo в плашке).
    struct UndoAction {
        let title: String
        let thread: ThreadSummary?
        let index: Int
        let key: ThreadKey
        let kind: String
        /// Был ли тред во «Входящих» до действия: отмена возвращает ровно это, а не кладёт во «Входящие» всегда.
        let wasInInbox: Bool
        /// Убрана ли строка из списка (в All mail или Sent архив её не убирает).
        let removed: Bool
        /// Сам запрос действия: отмена ждёт его, иначе два запроса придут в Gmail в любом порядке.
        let op: Task<Void, Never>?
        /// Своя отмена (пакетные действия): если есть, undoLast вызывает только её.
        var custom: (@MainActor () -> Void)? = nil
        let id = UUID()
    }
    var undo: UndoAction?

    func undoLast() {
        guard let u = undo else { return }
        undo = nil
        if let custom = u.custom { custom(); return }
        pendingOps[u.key] = nil
        if u.removed, let t = u.thread, !threads.contains(where: { $0.key == u.key }) {
            threads.insert(t, at: min(u.index, threads.count))
            pageRows[t.account, default: []].append(t)
            patchCaches(u.key) { _ in t }
        } else if let t = u.thread, let i = threads.firstIndex(where: { $0.key == u.key }) {
            threads[i].labelIDs = t.labelIDs
        }
        selectedThread = u.key
        let c = client(u.key.account)
        Task {
            await u.op?.value
            do {
                if u.kind == "trash" { try await c.untrashThread(id: u.key.threadID) }
                if u.wasInInbox { try await c.modifyThread(id: u.key.threadID, add: ["INBOX"]) }
            } catch { handle(error, account: u.key.account) }
            await refreshLabels()
        }
    }

    private func remember(_ title: String, _ key: ThreadKey, _ kind: String, removed: Bool, op: Task<Void, Never>) {
        let i = threads.firstIndex { $0.key == key } ?? 0
        let t = threads.first { $0.key == key }
        undo = UndoAction(title: title, thread: t, index: i, key: key, kind: kind,
                          wasInInbox: t?.labelIDs.contains("INBOX") ?? (mailbox.labelID == "INBOX" || isImportantBox),
                          removed: removed, op: op)
        let stamp = undo?.id
        Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if undo?.id == stamp { undo = nil } }
    }

    /// Поменять строку треда во всех местах, где она лежит: список, загруженные страницы, кэш входящих и «Важного».
    /// nil из замыкания убирает строку.
    func patchCaches(_ key: ThreadKey, _ change: (ThreadSummary) -> ThreadSummary?) {
        for k in [Mailbox.inbox(nil).key, Mailbox.inbox(key.account).key, "all|IMPORTANT_RV"] {
            guard var list = listCache[k], let i = list.firstIndex(where: { $0.key == key }) else { continue }
            if let n = change(list[i]) { list[i] = n } else { list.remove(at: i) }
            listCache[k] = list
        }
        if var rows = pageRows[key.account], let i = rows.firstIndex(where: { $0.key == key }) {
            if let n = change(rows[i]) { rows[i] = n } else { rows.remove(at: i) }
            pageRows[key.account] = rows
        }
    }

    private func removeFromList(_ key: ThreadKey) {
        let vis = visibleThreads
        let vi = vis.firstIndex { $0.key == key }
        threads.removeAll { $0.key == key }
        if var rows = pageRows[key.account] { rows.removeAll { $0.key == key }; pageRows[key.account] = rows }
        if selectedThread == key {
            // следующий по видимому списку, а не по скрытому фильтром
            var next: ThreadKey?
            if let vi {
                if vis.indices.contains(vi + 1) { next = vis[vi + 1].key } else if vi > 0 { next = vis[vi - 1].key }
            }
            selectedThread = next
        }
    }

    func finishOp(_ key: ThreadKey) {
        // запрос дошёл: даём Gmail пару секунд и дальше верим серверу
        if pendingOps[key] != nil { pendingOps[key]?.until = Date().addingTimeInterval(5) }
    }

    func archive(_ key: ThreadKey) {
        let box = mailbox.labelID
        // в All mail, Sent, Starred и ярлыках архив не убирает тред из папки, только снимает «Входящие»
        let leaves = box == "INBOX" || box == "IMPORTANT_RV"
        let wasUnreadInInbox = threads.first { $0.key == key }.map { $0.unread && $0.labelIDs.contains("INBOX") } ?? false
        var op = pendingOps[key] ?? PendingOp()
        op.removedFrom.insert("INBOX")
        op.until = Date().addingTimeInterval(30)
        pendingOps[key] = op
        let c = client(key.account)
        let task = Task {
            do { try await c.modifyThread(id: key.threadID, remove: ["INBOX"]) } catch { pendingOps[key] = nil; handle(error, account: key.account) }
            finishOp(key)
            await refreshLabels()
        }
        remember("Conversation archived", key, "archive", removed: leaves, op: task)
        patchCaches(key) { t in
            var t = t
            t.labelIDs.removeAll { $0 == "INBOX" }
            return t
        }
        for k in [Mailbox.inbox(nil).key, Mailbox.inbox(key.account).key, "all|IMPORTANT_RV"] { listCache[k]?.removeAll { $0.key == key } }
        if wasUnreadInInbox { bumpInboxUnread(key.account, by: -1) }
        if leaves {
            removeFromList(key)
        } else if let i = threads.firstIndex(where: { $0.key == key }) {
            threads[i].labelIDs.removeAll { $0 == "INBOX" }
        }
    }

    func trash(_ key: ThreadKey) {
        let wasUnreadInInbox = threads.first { $0.key == key }.map { $0.unread && $0.labelIDs.contains("INBOX") } ?? false
        var op = pendingOps[key] ?? PendingOp()
        op.removedFrom.insert("*")
        op.until = Date().addingTimeInterval(30)
        pendingOps[key] = op
        let c = client(key.account)
        let task = Task {
            do { try await c.trashThread(id: key.threadID) } catch { pendingOps[key] = nil; handle(error, account: key.account) }
            finishOp(key)
            await refreshLabels()
        }
        remember("Moved to trash", key, "trash", removed: mailbox.labelID != "TRASH", op: task)
        patchCaches(key) { _ in nil }
        if wasUnreadInInbox { bumpInboxUnread(key.account, by: -1) }
        if mailbox.labelID != "TRASH" { removeFromList(key) }
    }

    /// Прочитано / не прочитано: сразу везде на экране и в счётчике, затем запрос.
    private func setUnread(_ key: ThreadKey, _ unread: Bool) {
        guard let i = threads.firstIndex(where: { $0.key == key }) else { return }
        let inInbox = threads[i].labelIDs.contains("INBOX")
        let was = threads[i].unread
        threads[i].unread = unread
        patchCaches(key) { t in var t = t; t.unread = unread; return t }
        var op = pendingOps[key] ?? PendingOp()
        op.unread = unread
        op.until = Date().addingTimeInterval(30)
        pendingOps[key] = op
        if inInbox, was != unread { bumpInboxUnread(key.account, by: unread ? 1 : -1) }
        let c = client(key.account)
        Task {
            do {
                try await c.modifyThread(id: key.threadID, add: unread ? ["UNREAD"] : [], remove: unread ? [] : ["UNREAD"])
            } catch {
                pendingOps[key]?.unread = nil
                handle(error, account: key.account)
            }
            finishOp(key)
            await refreshLabels()
        }
    }

    func toggleUnread(_ key: ThreadKey) {
        guard let t = threads.first(where: { $0.key == key }) else { return }
        setUnread(key, !t.unread)
    }

    func toggleStar(_ key: ThreadKey) {
        guard let i = threads.firstIndex(where: { $0.key == key }) else { return }
        threads[i].starred.toggle()
        let starred = threads[i].starred
        patchCaches(key) { t in var t = t; t.starred = starred; return t }
        var op = pendingOps[key] ?? PendingOp()
        op.starred = starred
        op.until = Date().addingTimeInterval(30)
        pendingOps[key] = op
        let c = client(key.account)
        Task {
            do {
                try await c.modifyThread(id: key.threadID, add: starred ? ["STARRED"] : [], remove: starred ? [] : ["STARRED"])
            } catch {
                pendingOps[key]?.starred = nil
                handle(error, account: key.account)
            }
            finishOp(key)
        }
    }

    func moveToInbox(_ key: ThreadKey) {
        var op = pendingOps[key] ?? PendingOp()
        op.removedFrom.formUnion(["SPAM", "TRASH"])
        op.until = Date().addingTimeInterval(30)
        pendingOps[key] = op
        removeFromList(key)
        let c = client(key.account)
        Task {
            do { try await c.modifyThread(id: key.threadID, add: ["INBOX"], remove: ["SPAM", "TRASH"]) } catch { handle(error, account: key.account) }
            finishOp(key)
        }
    }

    // MARK: Недописанные ответы

    func saveReplyDraft(_ key: ThreadKey, _ d: ReplyDraft) {
        guard replyDrafts[key] != d else { return }
        let old = replyDrafts[key]
        replyDrafts[key] = d
        persistReplyDrafts()
        // в Gmail черновик уходит через 3 секунды тишины; смена одного только id черновика синхронизации не требует
        var a = d, b = old
        a.gmailDraftID = nil; b?.gmailDraftID = nil
        if a != b { scheduleDraftSync(key) }
    }

    func discardReplyDraft(_ key: ThreadKey) {
        draftSyncTasks[key]?.cancel()
        draftSyncTasks[key] = nil
        let gid = replyDrafts[key]?.gmailDraftID
        replyDrafts[key] = nil
        persistReplyDrafts()
        if let gid {
            let c = client(key.account)
            Task {
                try? await c.deleteDraft(id: gid)
                await loadDetail(key)
            }
        }
    }

    /// Запись черновиков на диск не чаще раза в секунду.
    private func persistReplyDrafts() {
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            let copy = Dictionary(uniqueKeysWithValues: replyDrafts.map { ($0.key.string, $0.value) })
            let url = Self.replyDraftsURL
            DiskQueue.write { JSONFile.save(copy, to: url) }
        }
    }

    private func scheduleDraftSync(_ key: ThreadKey) {
        draftSyncTasks[key]?.cancel()
        draftSyncTasks[key] = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await syncDraftToGmail(key)
        }
    }

    /// Недописанный ответ лежит и в Gmail: виден с телефона и в Gmail web. Один черновик на тред, обновляется на месте.
    private func syncDraftToGmail(_ key: ThreadKey) async {
        guard let d = replyDrafts[key], isOnline else { return }
        // текст стёрли: черновик в Gmail со старым текстом не оставляем, иначе он всплывает в треде и на телефоне
        if d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let gid = d.gmailDraftID {
                try? await client(key.account).deleteDraft(id: gid)
                if replyDrafts[key]?.gmailDraftID == gid { replyDrafts[key]?.gmailDraftID = nil; persistReplyDrafts() }
                await loadDetail(key)
            }
            return
        }
        let target = d.replyToMessageID.flatMap { id in details[key]?.messages.first { $0.id == id } }
        let raw = MIMEBuilder.build(from: defaultFrom(account: key.account, replyingTo: target),
                                    to: Person.parseList(d.to), cc: Person.parseList(d.cc), bcc: Person.parseList(d.bcc),
                                    subject: d.subject, body: d.text, inReplyTo: target, quoteOriginal: target != nil && d.mode != "forward",
                                    signatureHTML: signature(for: key.account))
        do {
            let id = try await client(key.account).saveDraft(raw: raw, threadID: key.threadID, draftID: d.gmailDraftID)
            if replyDrafts[key] == nil {
                // пока сохраняли, ответ отправили или выбросили: черновик в Gmail не оставляем
                try? await client(key.account).deleteDraft(id: id)
            } else if replyDrafts[key]?.gmailDraftID != id {
                replyDrafts[key]?.gmailDraftID = id
                persistReplyDrafts()
            }
        } catch {
            AppLog.write("draft sync \(key.string): \(error.localizedDescription)")
        }
    }

    /// Текст черновика из Gmail для редактора: без подписи и без цитаты.
    func editableText(ofDraft m: MailMessage) -> String {
        // Gmail отдаёт текст с CR LF: без нормализации каждая пустая строка в редакторе удваивалась
        rawEditableText(ofDraft: m).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private func rawEditableText(ofDraft m: MailMessage) -> String {
        if let h = m.html {
            var s = HTMLText.stripQuoted(html: h)
            if let r = s.range(of: "<div[^>]*class=\"[^\"]*gmail_signature[^\"]*\"[\\s\\S]*$", options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(r)
            }
            return HTMLText.toPlain(s)
        }
        let plain = HTMLText.stripQuoted(plain: m.readableText)
        if let r = plain.range(of: "\n-- \n") { return String(plain[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return plain
    }

    /// Черновик, у которого в треде нет отправленных писем, продолжается в окне нового письма.
    /// Возвращает true, если окно надо открыть (ComposeBus уже заряжен). Черновик с вложениями
    /// остаётся в треде: окно нового письма их не подхватит и при автосохранении стёрло бы.
    func prepareStandaloneDraft(_ key: ThreadKey) async -> Bool {
        if details[key] == nil { await loadDetail(key) }
        guard let d = details[key], d.sentMessages.isEmpty, let m = d.latestDraft, isMe(key.account) else { return false }
        if m.attachments.contains(where: { !$0.inline }) { return false }
        let gid = await client(key.account).draftID(forMessage: m.id)
        let from = isMe(m.from.email) ? m.from : nil
        ComposeBus.shared.restoreNew = PendingSend(account: key.account, to: m.to, cc: m.cc, bcc: [], subject: m.subject,
                                                   body: editableText(ofDraft: m), bodyHTML: nil, replyTo: nil, threadID: nil, attachments: [],
                                                   forwardFrom: nil, from: from, draftID: gid, fireAt: Date(), timer: nil)
        return true
    }

    /// Исходник письма (Show original). nil при ошибке, ошибка уходит в плашку.
    func rawSource(_ m: MailMessage, account: String) async -> String? {
        do { return try await client(account).rawSource(messageID: m.id) } catch {
            handle(error, account: account)
            return nil
        }
    }

    // MARK: Отправка

    /// Отправка или черновик. draftOnly возвращает id черновика Gmail (тот же черновик обновляется, а не плодится),
    /// обычная отправка возвращает id письма и убирает черновик треда. Подпись Gmail добавляется сама.
    /// attachments это файлы с диска; forwardFrom пересылает письмо целиком, с оригиналом в HTML и его вложениями.
    @discardableResult
    func send(account: String, to: [Person], cc: [Person], bcc: [Person], subject: String, body: String,
              bodyHTML: String? = nil, replyTo: MailMessage?, threadID: String?, draftOnly: Bool = false,
              attachments: [URL] = [], forwardFrom: MailMessage? = nil,
              from: Person? = nil, draftID: String? = nil) async throws -> String? {
        let all = to + cc + bcc
        if !draftOnly {
            if all.isEmpty { throw GmailError.invalidAddress("add at least one recipient") }
            if let bad = all.first(where: { !$0.isValidEmail }) { throw GmailError.invalidAddress(bad.email.isEmpty ? bad.name : bad.email) }
        }
        let key = threadID.map { ThreadKey(account: account, threadID: $0) }
        let sender = from ?? defaultFrom(account: account, replyingTo: replyTo)
        let files = try await loadFiles(attachments)
        var parts = files
        if let f = forwardFrom {
            parts += try await originalAttachments(f, account: account)
        }
        let total = parts.reduce(0) { $0 + $1.data.count }
        if total > 25 * 1024 * 1024 { throw GmailError.tooLarge(total / (1024 * 1024)) }
        let raw = MIMEBuilder.build(from: sender, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                                    bodyHTML: bodyHTML, inReplyTo: replyTo, quoteOriginal: replyTo != nil && forwardFrom == nil,
                                    signatureHTML: signature(for: sender.email) ?? signature(for: account),
                                    attachments: parts, forwardOf: forwardFrom)
        let c = client(account)
        // автосохранение не должно создать черновик поверх уже отправленного
        if let key {
            draftSyncTasks[key]?.cancel()
            draftSyncTasks[key] = nil
        }
        let existingDraft = draftID ?? key.flatMap { replyDrafts[$0]?.gmailDraftID }
        let result: String?
        do {
            if draftOnly {
                let id = try await c.saveDraft(raw: raw, threadID: threadID, draftID: existingDraft)
                if let key, replyDrafts[key] != nil, replyDrafts[key]?.gmailDraftID != id {
                    replyDrafts[key]?.gmailDraftID = id
                    persistReplyDrafts()
                }
                result = id
            } else {
                result = try await c.send(raw: raw, threadID: threadID)
                if let existingDraft { try? await c.deleteDraft(id: existingDraft) }
                if let key, replyDrafts[key] != nil {
                    replyDrafts[key] = nil
                    persistReplyDrafts()
                }
            }
        } catch {
            if let g = error as? GmailError, g.needsLogin { expiredAccounts.insert(account) }
            throw error
        }
        if let key { await loadDetail(key) }
        Task { await reload() }
        return result
    }

    /// Отправка с паузой: письмо уходит через delay секунд, до этого cancelPendingSend() его возвращает.
    /// Адреса проверяются сразу. Новое письмо в очереди отправляет предыдущее немедленно.
    func sendWithUndo(account: String, to: [Person], cc: [Person], bcc: [Person], subject: String, body: String,
                      bodyHTML: String? = nil,
                      replyTo: MailMessage?, threadID: String?, draftOnly: Bool = false,
                      attachments: [URL] = [], forwardFrom: MailMessage? = nil,
                      from: Person? = nil, draftID: String? = nil, delay: TimeInterval = 5) throws {
        if draftOnly {
            Task {
                do {
                    try await send(account: account, to: to, cc: cc, bcc: bcc, subject: subject, body: body, bodyHTML: bodyHTML, replyTo: replyTo,
                                   threadID: threadID, draftOnly: true, attachments: attachments, forwardFrom: forwardFrom,
                                   from: from, draftID: draftID)
                } catch { self.error = error.localizedDescription }
            }
            return
        }
        let all = to + cc + bcc
        if all.isEmpty { throw GmailError.invalidAddress("add at least one recipient") }
        if let bad = all.first(where: { !$0.isValidEmail }) { throw GmailError.invalidAddress(bad.email.isEmpty ? bad.name : bad.email) }
        flushPendingSend()
        var p = PendingSend(account: account, to: to, cc: cc, bcc: bcc, subject: subject, body: body, bodyHTML: bodyHTML, replyTo: replyTo,
                            threadID: threadID, attachments: attachments, forwardFrom: forwardFrom, from: from, draftID: draftID,
                            fireAt: Date().addingTimeInterval(delay), timer: nil)
        let id = p.id
        p.timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pendingSend?.id == id else { return }
            self.firePendingSend()
        }
        pendingSend = p
    }

    /// Отменить отложенную отправку. Возвращает письмо, чтобы редактор мог его вернуть; черновик треда не тронут.
    @discardableResult
    func cancelPendingSend() -> PendingSend? {
        guard let p = pendingSend else { return nil }
        p.timer?.cancel()
        pendingSend = nil
        return p
    }

    /// Отправить ожидающее письмо сейчас (новое письмо в очереди, закрытие окна).
    func flushPendingSend() {
        guard pendingSend != nil else { return }
        firePendingSend()
    }

    private func firePendingSend() {
        guard let p = pendingSend else { return }
        p.timer?.cancel()
        pendingSend = nil
        Task {
            do {
                try await send(account: p.account, to: p.to, cc: p.cc, bcc: p.bcc, subject: p.subject, body: p.body, bodyHTML: p.bodyHTML,
                               replyTo: p.replyTo, threadID: p.threadID, attachments: p.attachments,
                               forwardFrom: p.forwardFrom, from: p.from, draftID: p.draftID)
            } catch {
                self.error = "Not sent: \(error.localizedDescription)"
            }
        }
    }

    private func loadFiles(_ urls: [URL]) async throws -> [MIMEAttachment] {
        guard !urls.isEmpty else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            try urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                return MIMEAttachment(filename: url.lastPathComponent, mimeType: mime, data: data)
            }
        }.value
    }

    /// Вложения пересылаемого письма, включая картинки в тексте (с прежним Content-ID, чтобы HTML их нашёл).
    private func originalAttachments(_ m: MailMessage, account: String) async throws -> [MIMEAttachment] {
        var out: [MIMEAttachment] = []
        let c = client(account)
        for a in m.attachments {
            let data = try await c.attachment(messageID: a.messageID, id: a.id)
            out.append(MIMEAttachment(filename: a.filename, mimeType: a.mimeType, data: data, contentID: a.contentID, inline: a.inline))
        }
        return out
    }

    // MARK: Вложения

    /// Картинки внутри письма (cid:) как data: URL для подстановки в HTML. Скачиваются один раз.
    func inlineImages(for message: MailMessage, account: String) async -> [String: String] {
        var out: [String: String] = [:]
        let c = client(account)
        for a in message.attachments {
            guard let cid = a.contentID, a.size < 8 * 1024 * 1024 else { continue }
            let ck = account + "|" + message.id + "|" + cid
            if let hit = inlineCache[ck] { out[cid] = hit; continue }
            guard let data = try? await c.attachment(messageID: a.messageID, id: a.id), !data.isEmpty else { continue }
            let mime = a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType
            let url = "data:\(mime);base64,\(data.base64EncodedString())"
            if inlineCache.count > 300 { inlineCache.removeAll() }
            inlineCache[ck] = url
            out[cid] = url
        }
        return out
    }

    /// Имя файла без символов, которые ломают путь или Finder.
    static func safeFilename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        var s = String(String.UnicodeScalarView(name.unicodeScalars.map { bad.contains($0) ? "_" : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "attachment" }
        if s.count > 200 {
            let ext = (s as NSString).pathExtension
            s = String(s.prefix(190)) + (ext.isEmpty ? "" : "." + ext)
        }
        return s
    }

    /// Вложение во временной папке (для просмотра Quick Look и перетаскивания). Скачивается один раз.
    func attachmentFile(_ a: Attachment, account: String) async -> URL? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReVaultMail-attachments", isDirectory: true)
        let dir = root.appendingPathComponent(Self.safeFilename(a.messageID) + "-" + String(a.size), isDirectory: true)
        let url = dir.appendingPathComponent(Self.safeFilename(a.filename))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            let data = try await client(account).attachment(messageID: a.messageID, id: a.id)
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }.value
            return url
        } catch {
            handle(error, account: account)
            return nil
        }
    }

    func downloadAttachment(_ a: Attachment, account: String) async -> URL? {
        do {
            let data = try await client(account).attachment(messageID: a.messageID, id: a.id)
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let name = Self.safeFilename(a.filename)
            return try await Task.detached(priority: .userInitiated) {
                var url = dir.appendingPathComponent(name)
                var n = 1
                while FileManager.default.fileExists(atPath: url.path) {
                    let ext = (name as NSString).pathExtension
                    let base = (name as NSString).deletingPathExtension
                    url = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
                    n += 1
                }
                try data.write(to: url)
                return url
            }.value
        } catch {
            handle(error, account: account)
            return nil
        }
    }
}
