import Foundation

/// Действия над несколькими тредами сразу, метки, отложение, заглушение, блок отправителя,
/// «прочитать всё» и недавние поиски. Всё сразу на экране, запросы в фоне, отмена через плашку Undo.
extension MailStore {
    static let snoozedBox = "SNOOZED_RV"
    var isSnoozedBox: Bool { mailbox.labelID == Self.snoozedBox && activeQuery.isEmpty }

    // MARK: Выделение

    var isMultiSelecting: Bool { multiSelection.count >= 2 }

    /// Выделенные треды в порядке списка.
    var orderedSelection: [ThreadKey] {
        let order = navigableKeys
        var out = order.filter { multiSelection.contains($0) }
        let rest = multiSelection.subtracting(out)
        out += rest.sorted { $0.string < $1.string }
        return out
    }

    /// К чему относится действие с клавиатуры или из меню: выделение, иначе открытый тред.
    var actionKeys: [ThreadKey] {
        if isMultiSelecting { return orderedSelection }
        return selectedThread.map { [$0] } ?? []
    }

    /// Ключи для меню строки: если строка внутри выделения, действие идёт на всё выделение.
    func menuKeys(for key: ThreadKey) -> [ThreadKey] {
        isMultiSelecting && multiSelection.contains(key) ? orderedSelection : [key]
    }

    /// ⌘-клик: добавить или убрать строку. Открытый тред становится частью выделения.
    func toggleInSelection(_ key: ThreadKey) {
        var sel = multiSelection
        if sel.isEmpty, let cur = selectedThread, cur != key { sel.insert(cur) }
        if sel.contains(key) { sel.remove(key) } else { sel.insert(key) }
        selectionAnchor = key
        commitSelection(sel)
    }

    /// Shift-клик: всё от точки отсчёта до строки. С ⌘ диапазон добавляется к выделению.
    func selectRange(to key: ThreadKey, additive: Bool) {
        let list = visibleThreads.map(\.key)
        let anchor = selectionAnchor ?? selectedThread ?? key
        guard let a = list.firstIndex(of: anchor), let b = list.firstIndex(of: key) else {
            toggleInSelection(key)
            return
        }
        var sel = additive ? multiSelection : []
        for k in list[min(a, b)...max(a, b)] { sel.insert(k) }
        if selectionAnchor == nil { selectionAnchor = anchor }
        commitSelection(sel)
    }

    func selectAllVisible() {
        let all = Set(visibleThreads.map(\.key))
        if all.count >= 2 { multiSelection = all } else if let only = all.first { selectedThread = only }
    }

    func clearSelection() {
        multiSelection = []
        selectionAnchor = nil
    }

    /// Обычный клик: выделение сбрасывается, тред открывается.
    func selectSingle(_ key: ThreadKey) {
        clearSelection()
        selectionAnchor = key
        selectedThread = key
    }

    private func commitSelection(_ sel: Set<ThreadKey>) {
        if sel.count >= 2 {
            multiSelection = sel
        } else {
            multiSelection = []
            if let only = sel.first, selectedThread != only { selectedThread = only }
        }
    }

    /// После действия в выделении остаются только строки, которые ещё видны.
    private func pruneSelection() {
        guard !multiSelection.isEmpty else { return }
        let live = Set(visibleThreads.map(\.key))
        let left = multiSelection.intersection(live)
        multiSelection = left.count >= 2 ? left : []
    }

    func summary(_ key: ThreadKey) -> ThreadSummary? {
        if let t = threads.first(where: { $0.key == key }) { return t }
        if let e = snoozes.first(where: { $0.key == key }) { return e.summary }
        for list in listCache.values { if let t = list.first(where: { $0.key == key }) { return t } }
        return nil
    }

    // MARK: Ядро: ярлыки на нескольких тредах

    struct LabelChange { var key: ThreadKey; var added: [String]; var removed: [String] }

    /// Снять и поставить ярлыки нескольким тредам (у каждого ящика свои id меток).
    /// Строки, которые уходят из открытой папки, убираются сразу; отмена возвращает ровно то, что поменялось.
    @discardableResult
    func applyLabels(_ plan: [(key: ThreadKey, add: [String], remove: [String])], title: String?,
                     silent: Bool = false, extraUndo: (@MainActor () -> Void)? = nil) -> [LabelChange] {
        let box = mailbox
        let boxLabel = gmailLabel(box)
        let mine = Set(accounts.map(\.email))
        var changes: [LabelChange] = []
        var leaving = Set<ThreadKey>()
        let before = visibleThreads
        let snapshot = threads
        for p in plan where mine.contains(p.key.account) {
            let known = summary(p.key)
            let prior = Set(known?.labelIDs ?? [])
            let added = known == nil ? p.add : p.add.filter { !prior.contains($0) }
            let removed = known == nil ? p.remove : p.remove.filter { prior.contains($0) }
            if added.isEmpty && removed.isEmpty { continue }
            changes.append(LabelChange(key: p.key, added: added, removed: removed))
            let next = prior.subtracting(removed).union(added)
            var leaves = removed.contains(boxLabel) || removed.contains(box.labelID)
            if (added.contains("SPAM") && box.labelID != "SPAM") || (added.contains("TRASH") && box.labelID != "TRASH") { leaves = true }
            if box.labelID == Self.snoozedBox && added.contains("INBOX") { leaves = true }
            var op = pendingOps[p.key] ?? PendingOp()
            op.removedFrom.formUnion(removed)
            if leaves { op.removedFrom.insert(box.labelID) }
            if added.contains("UNREAD") { op.unread = true }
            if removed.contains("UNREAD") { op.unread = false }
            if added.contains("STARRED") { op.starred = true }
            if removed.contains("STARRED") { op.starred = false }
            op.until = Date().addingTimeInterval(30)
            pendingOps[p.key] = op
            let patch: (ThreadSummary) -> ThreadSummary = { t in
                var t = t
                t.labelIDs = Array(Set(t.labelIDs).subtracting(removed).union(added))
                if added.contains("UNREAD") { t.unread = true }
                if removed.contains("UNREAD") { t.unread = false }
                if added.contains("STARRED") { t.starred = true }
                if removed.contains("STARRED") { t.starred = false }
                return t
            }
            patchCaches(p.key, patch)
            if let i = threads.firstIndex(where: { $0.key == p.key }) {
                let t = patch(threads[i])
                threads[i] = t
            }
            if removed.contains("INBOX") || added.contains("SPAM") || added.contains("TRASH") {
                for k in [Mailbox.inbox(nil).key, Mailbox.inbox(p.key.account).key, "all|IMPORTANT_RV"] { listCache[k]?.removeAll { $0.key == p.key } }
            }
            let was = prior.contains("INBOX") && prior.contains("UNREAD") && !prior.contains("SPAM")
            let now = next.contains("INBOX") && next.contains("UNREAD") && !next.contains("SPAM")
            if known != nil, was != now { bumpInboxUnread(p.key.account, by: now ? 1 : -1) }
            if leaves { leaving.insert(p.key) }
        }
        guard !changes.isEmpty else { return [] }
        removeRows(leaving, visibleBefore: before)
        pruneSelection()
        let task = Task { await self.runModify(changes) }
        if !silent, let title {
            let rows = leaving.compactMap { k in snapshot.firstIndex { $0.key == k }.map { (snapshot[$0], $0) } }
            setUndo(title, key: changes[0].key, op: task) { [weak self] in
                self?.revert(changes, rows: rows, after: task)
                extraUndo?()
            }
        }
        return changes
    }

    /// Один и тот же набор ярлыков всем тредам.
    @discardableResult
    func applyLabels(_ keys: [ThreadKey], add: [String] = [], remove: [String] = [], title: String?,
                     silent: Bool = false, extraUndo: (@MainActor () -> Void)? = nil) -> [LabelChange] {
        applyLabels(keys.map { (key: $0, add: add, remove: remove) }, title: title, silent: silent, extraUndo: extraUndo)
    }

    /// Запросы threads.modify, по шесть за раз.
    private func runModify(_ changes: [LabelChange]) async {
        let jobs = changes.map { ($0, client($0.key.account)) }
        await withTaskGroup(of: (ThreadKey, Error?).self) { group in
            var it = jobs.makeIterator()
            func next() {
                guard let (ch, c) = it.next() else { return }
                group.addTask {
                    do { try await c.modifyThread(id: ch.key.threadID, add: ch.added, remove: ch.removed); return (ch.key, nil) }
                    catch { return (ch.key, error) }
                }
            }
            for _ in 0..<6 { next() }
            while let (key, err) = await group.next() {
                if let err { pendingOps[key] = nil; handle(err, account: key.account) }
                finishOp(key)
                next()
            }
        }
        await refreshLabels()
    }

    /// Отмена пакетного действия: строки возвращаются на свои места, ярлыки обратно.
    private func revert(_ changes: [LabelChange], rows: [(ThreadSummary, Int)], after task: Task<Void, Never>?) {
        for ch in changes { pendingOps[ch.key] = nil }
        restoreRows(rows)
        for ch in changes {
            let back: (ThreadSummary) -> ThreadSummary = { t in
                var t = t
                t.labelIDs = Array(Set(t.labelIDs).subtracting(ch.added).union(ch.removed))
                if ch.added.contains("UNREAD") { t.unread = false }
                if ch.removed.contains("UNREAD") { t.unread = true }
                if ch.added.contains("STARRED") { t.starred = false }
                if ch.removed.contains("STARRED") { t.starred = true }
                return t
            }
            if let i = threads.firstIndex(where: { $0.key == ch.key }) {
                let t = back(threads[i])
                threads[i] = t
            }
            patchCaches(ch.key, back)
        }
        let reversed = changes.map { LabelChange(key: $0.key, added: $0.removed, removed: $0.added) }
        Task {
            await task?.value
            await runModify(reversed)
        }
    }

    /// Убрать строки из видимого списка. Открытый тред переходит на следующий оставшийся, без каскада открытий.
    private func removeRows(_ keys: Set<ThreadKey>, visibleBefore vis: [ThreadSummary]) {
        guard !keys.isEmpty else { return }
        var next: ThreadKey?
        if let sel = selectedThread, keys.contains(sel), let vi = vis.firstIndex(where: { $0.key == sel }) {
            next = vis[(vi + 1)...].first { !keys.contains($0.key) }?.key ?? vis[..<vi].last { !keys.contains($0.key) }?.key
        }
        threads.removeAll { keys.contains($0.key) }
        for acc in Set(keys.map(\.account)) {
            if var rows = pageRows[acc] { rows.removeAll { keys.contains($0.key) }; pageRows[acc] = rows }
        }
        if let sel = selectedThread, keys.contains(sel) {
            // много строк ушло сразу: следующую не открываем, если человек работал с выделением
            selectedThread = keys.count > 1 ? nil : next
        }
    }

    private func restoreRows(_ rows: [(ThreadSummary, Int)]) {
        for (t, i) in rows.sorted(by: { $0.1 < $1.1 }) where !threads.contains(where: { $0.key == t.key }) {
            threads.insert(t, at: min(i, threads.count))
            pageRows[t.account, default: []].append(t)
        }
    }

    func setUndo(_ title: String, key: ThreadKey, op: Task<Void, Never>?, custom: @escaping @MainActor () -> Void) {
        undo = UndoAction(title: title, thread: nil, index: 0, key: key, kind: "custom", wasInInbox: false,
                          removed: false, op: op, custom: custom)
        let stamp = undo?.id
        Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if undo?.id == stamp { undo = nil } }
    }

    private static func plural(_ n: Int, _ one: String) -> String { n == 1 ? "1 conversation \(one)" : "\(n) conversations \(one)" }

    // MARK: Действия над выделением

    func archive(_ keys: [ThreadKey]) {
        if keys.count == 1 { archive(keys[0]); return }
        applyLabels(keys, remove: ["INBOX"], title: Self.plural(keys.count, "archived"))
    }

    func trash(_ keys: [ThreadKey]) {
        if keys.count == 1 { trash(keys[0]); dropSnoozes(keys); return }
        bulkTrash(keys, title: Self.plural(keys.count, "moved to trash"))
    }

    func setUnread(_ keys: [ThreadKey], _ unread: Bool) {
        applyLabels(keys, add: unread ? ["UNREAD"] : [], remove: unread ? [] : ["UNREAD"],
                    title: keys.count > 1 ? (unread ? "Marked as unread" : "Marked as read") : nil)
    }

    /// U на выделении: если есть непрочитанные, всё становится прочитанным, иначе наоборот.
    func toggleUnread(_ keys: [ThreadKey]) {
        if keys.count == 1 { toggleUnread(keys[0]); return }
        let anyUnread = keys.contains { summary($0)?.unread == true }
        setUnread(keys, !anyUnread)
    }

    /// S на выделении: если хоть одна без звезды, звезду получают все, иначе звёзды снимаются.
    func toggleStar(_ keys: [ThreadKey]) {
        if keys.count == 1 { toggleStar(keys[0]); return }
        let allStarred = keys.allSatisfy { summary($0)?.starred == true }
        applyLabels(keys, add: allStarred ? [] : ["STARRED"], remove: allStarred ? ["STARRED"] : [],
                    title: allStarred ? "Stars removed" : "Starred")
    }

    func markSpam(_ keys: [ThreadKey]) {
        dropSnoozes(keys)
        applyLabels(keys, add: ["SPAM"], remove: ["INBOX"], title: keys.count == 1 ? "Marked as spam" : Self.plural(keys.count, "marked as spam"))
    }

    func notSpam(_ keys: [ThreadKey]) {
        applyLabels(keys, add: ["INBOX"], remove: ["SPAM"], title: keys.count == 1 ? "Moved to inbox" : Self.plural(keys.count, "moved to inbox"))
    }

    /// Корзина для нескольких тредов: threads.trash по одному, отмена через untrash.
    func bulkTrash(_ keys: [ThreadKey], title: String, silent: Bool = false, extraUndo: (@MainActor () -> Void)? = nil) {
        let mine = Set(accounts.map(\.email))
        let keys = keys.filter { mine.contains($0.account) }
        guard !keys.isEmpty else { return }
        let before = visibleThreads
        let snapshot = threads
        var hadInbox: [ThreadKey: Bool] = [:]
        for k in keys {
            let t = summary(k)
            hadInbox[k] = t?.labelIDs.contains("INBOX") ?? (mailbox.labelID == "INBOX" || isImportantBox)
            if let t, t.unread, t.labelIDs.contains("INBOX") { bumpInboxUnread(k.account, by: -1) }
            var op = pendingOps[k] ?? PendingOp()
            op.removedFrom.insert("*")
            op.until = Date().addingTimeInterval(30)
            pendingOps[k] = op
            patchCaches(k) { _ in nil }
        }
        let leaving = mailbox.labelID == "TRASH" ? Set<ThreadKey>() : Set(keys)
        removeRows(leaving, visibleBefore: before)
        pruneSelection()
        dropSnoozes(keys)
        let task = Task {
            let jobs = keys.map { ($0, self.client($0.account)) }
            await withTaskGroup(of: (ThreadKey, Error?).self) { group in
                var it = jobs.makeIterator()
                func next() {
                    guard let (k, c) = it.next() else { return }
                    group.addTask {
                        do { try await c.trashThread(id: k.threadID); return (k, nil) } catch { return (k, error) }
                    }
                }
                for _ in 0..<6 { next() }
                while let (k, err) = await group.next() {
                    if let err { pendingOps[k] = nil; handle(err, account: k.account) }
                    finishOp(k)
                    next()
                }
            }
            await refreshLabels()
        }
        guard !silent else { return }
        let rows = leaving.compactMap { k in snapshot.firstIndex { $0.key == k }.map { (snapshot[$0], $0) } }
        setUndo(title, key: keys[0], op: task) { [weak self] in
            guard let self else { return }
            for k in keys { self.pendingOps[k] = nil }
            self.restoreRows(rows)
            Task {
                await task.value
                for k in keys {
                    let c = self.client(k.account)
                    do {
                        try await c.untrashThread(id: k.threadID)
                        if hadInbox[k] == true { try await c.modifyThread(id: k.threadID, add: ["INBOX"]) }
                    } catch { self.handle(error, account: k.account) }
                }
                await self.refreshLabels()
            }
            extraUndo?()
        }
    }

    // MARK: Метки

    /// Метки пользователя по имени из всех ящиков, где лежат треды (в общем ящике одна строка на имя).
    func labelNames(for keys: [ThreadKey]) -> [String] {
        let accs = Set(keys.map(\.account))
        let source = accs.isEmpty ? Set(mailbox.account.map { [$0] } ?? accounts.map(\.email)) : accs
        var names = Set<String>()
        for a in source { userLabels(a).forEach { names.insert($0.name) } }
        return names.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    func labelID(named name: String, account: String) -> String? {
        userLabels(account).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    /// Сколько тредов из набора несут метку: для галочек (все, часть, ни одного).
    func labelCoverage(_ name: String, keys: [ThreadKey]) -> (have: Int, total: Int) {
        var have = 0
        for k in keys {
            if let id = labelID(named: name, account: k.account), summary(k)?.labelIDs.contains(id) == true { have += 1 }
        }
        return (have, keys.count)
    }

    /// Метка в ящике: найти или создать (POST /labels). Новая сразу видна в меню.
    func ensureLabel(named name: String, account: String) async -> String? {
        if labels[account] == nil, let l = try? await client(account).labels() { labels[account] = l }
        if let id = labelID(named: name, account: account) { return id }
        do {
            let l = try await client(account).createLabel(name: name)
            var list = labels[account] ?? []
            if !list.contains(where: { $0.id == l.id }) { list.append(l) }
            labels[account] = list
            labelsGen += 1
            return l.id
        } catch {
            handle(error, account: account)
            return nil
        }
    }

    /// Поставить или снять метку на тредах. Если метки в каком-то ящике нет, она создаётся.
    func setLabel(_ name: String, on keys: [ThreadKey], apply: Bool) {
        Task {
            var ids: [String: String] = [:]
            for acc in Set(keys.map(\.account)) {
                if apply { ids[acc] = await ensureLabel(named: name, account: acc) } else { ids[acc] = labelID(named: name, account: acc) }
            }
            let plan = keys.compactMap { k -> (key: ThreadKey, add: [String], remove: [String])? in
                guard let id = ids[k.account] else { return nil }
                return (k, apply ? [id] : [], apply ? [] : [id])
            }
            applyLabels(plan, title: apply ? "Label \(name) added" : "Label \(name) removed")
        }
    }

    /// «Move to»: метка ставится, тред уходит из текущей папки (входящие или метка, в которой он лежит).
    func move(_ keys: [ThreadKey], toLabel name: String) {
        let box = mailbox
        Task {
            var ids: [String: String] = [:]
            for acc in Set(keys.map(\.account)) { ids[acc] = await ensureLabel(named: name, account: acc) }
            let plan = keys.compactMap { k -> (key: ThreadKey, add: [String], remove: [String])? in
                guard let id = ids[k.account] else { return nil }
                var remove = ["INBOX"]
                if box.labelID.hasPrefix("Label_"), box.labelID != id { remove.append(box.labelID) }
                return (k, [id], remove)
            }
            applyLabels(plan, title: keys.count == 1 ? "Moved to \(name)" : Self.plural(keys.count, "moved to \(name)"))
        }
    }

    /// Новая метка из окна меток: создаётся во всех ящиках выделения и сразу ставится.
    func createAndApplyLabel(_ name: String, on keys: [ThreadKey]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if keys.isEmpty {
            let acc = mailbox.account ?? accounts.first?.email
            if let acc { Task { _ = await ensureLabel(named: clean, account: acc) } }
            return
        }
        setLabel(clean, on: keys, apply: true)
    }

    // MARK: Прочитать всё

    /// «Mark all as read» для папки: messages.batchModify по всем непрочитанным письмам (по 1000 за запрос).
    /// В «Важном» и в поиске читаются только видимые строки: это подмножество, а не вся папка.
    func markAllRead(_ box: Mailbox) {
        guard box.labelID != "TEAM", box.labelID != Self.snoozedBox else { return }
        if box.labelID == "IMPORTANT_RV" || (box == mailbox && !activeQuery.isEmpty) {
            let keys = visibleThreads.filter(\.unread).map(\.key)
            if !keys.isEmpty { applyLabels(keys, remove: ["UNREAD"], title: "Marked all as read") }
            return
        }
        let query = box == mailbox ? activeQuery : ""
        let accs = (box.account.map { [$0] } ?? accounts.map(\.email)).filter { !expiredAccounts.contains($0) }
        let label: String? = box.labelID == "ALL" ? nil : box.labelID
        // на экране сразу
        var wasUnread: [ThreadKey] = []
        if box == mailbox {
            for i in threads.indices where threads[i].unread {
                var t = threads[i]
                t.unread = false
                t.labelIDs.removeAll { $0 == "UNREAD" }
                threads[i] = t
                wasUnread.append(t.key)
                var op = pendingOps[t.key] ?? PendingOp()
                op.unread = false
                op.until = Date().addingTimeInterval(30)
                pendingOps[t.key] = op
                patchCaches(t.key) { r in var r = r; r.unread = false; r.labelIDs.removeAll { $0 == "UNREAD" }; return r }
            }
        }
        var oldInbox: [String: Int] = [:]
        if box.labelID == "INBOX" && query.isEmpty {
            for acc in accs {
                guard var list = labels[acc], let i = list.firstIndex(where: { $0.id == "INBOX" }) else { continue }
                oldInbox[acc] = list[i].unread
                list[i].unread = 0
                labels[acc] = list
            }
            labelsGen += 1
        }
        let marked = MarkedIDs()
        let task = Task {
            for acc in accs {
                let c = client(acc)
                do {
                    let ids = try await c.messageIDs(labelID: label, query: query.isEmpty ? "is:unread" : "is:unread " + query)
                    guard !ids.isEmpty else { continue }
                    try await c.batchModifyMessages(ids: ids, remove: ["UNREAD"])
                    marked.byAccount[acc] = ids
                } catch { handle(error, account: acc) }
            }
            for k in wasUnread { finishOp(k) }
            await refreshLabels()
        }
        setUndo("Marked all as read", key: wasUnread.first ?? ThreadKey(account: accs.first ?? "", threadID: ""), op: task) { [weak self] in
            guard let self else { return }
            for k in wasUnread {
                self.pendingOps[k] = nil
                if let i = self.threads.firstIndex(where: { $0.key == k }) {
                    var t = self.threads[i]
                    t.unread = true
                    if !t.labelIDs.contains("UNREAD") { t.labelIDs.append("UNREAD") }
                    self.threads[i] = t
                }
                self.patchCaches(k) { r in var r = r; r.unread = true; return r }
            }
            for (acc, n) in oldInbox {
                guard var list = self.labels[acc], let i = list.firstIndex(where: { $0.id == "INBOX" }) else { continue }
                list[i].unread = n
                self.labels[acc] = list
            }
            self.labelsGen += 1
            Task {
                await task.value
                for (acc, ids) in marked.byAccount {
                    do { try await self.client(acc).batchModifyMessages(ids: ids, add: ["UNREAD"]) } catch { self.handle(error, account: acc) }
                }
                await self.refreshLabels()
            }
        }
    }

    // MARK: Отложить (Snooze)

    private static let snoozesURL = AppPaths.file("snoozes.json")
    private static let mutedURL = AppPaths.file("muted.json")
    private static let blockedURL = AppPaths.file("blocked.json")
    private static let recentKey = "recentSearches"
    /// Имя метки отложенных в Gmail. Если Gmail не даёт это имя (оно у него зарезервировано), берётся запасное.
    static let snoozeLabelNames = ["Snoozed", "RV Snoozed"]

    func loadLocalRules() {
        snoozes = JSONFile.load([SnoozeEntry].self, from: Self.snoozesURL) ?? []
        mutedThreads = Set(JSONFile.load([String].self, from: Self.mutedURL) ?? [])
        blockedSenders = JSONFile.load([BlockedSender].self, from: Self.blockedURL) ?? []
        recentSearches = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    }

    func saveLocalRules() {
        let s = snoozes, m = Array(mutedThreads).sorted(), b = blockedSenders
        let su = Self.snoozesURL, mu = Self.mutedURL, bu = Self.blockedURL
        DiskQueue.write {
            JSONFile.save(s, to: su)
            JSONFile.save(m, to: mu)
            JSONFile.save(b, to: bu)
        }
    }

    /// Варианты как в Gmail и Spark. nil у «Pick date»: дату выбирает человек.
    static func snoozePresets(now: Date = Date()) -> [(title: String, date: Date)] {
        let cal = Calendar.current
        func at(_ day: Date, _ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: day) ?? day }
        var out: [(String, Date)] = []
        let today18 = at(now, 18)
        if today18 > now.addingTimeInterval(30 * 60) { out.append(("Later today", today18)) }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        out.append(("Tomorrow", at(tomorrow, 8)))
        // суббота: ближайшая будущая (в саму субботу после 9 утра уже следующая)
        var sat = now
        for _ in 0..<8 {
            if cal.component(.weekday, from: sat) == 7, at(sat, 9) > now { break }
            sat = cal.date(byAdding: .day, value: 1, to: sat) ?? sat
        }
        if cal.component(.weekday, from: now) != 1 { out.append(("This weekend", at(sat, 9))) }
        var mon = cal.date(byAdding: .day, value: 1, to: now) ?? now
        while cal.component(.weekday, from: mon) != 2 { mon = cal.date(byAdding: .day, value: 1, to: mon) ?? mon }
        out.append(("Next week", at(mon, 8)))
        return out
    }

    func snoozeEntry(_ key: ThreadKey) -> SnoozeEntry? { snoozes.first { $0.key == key } }

    /// Отложить: тред уходит из входящих с меткой Snoozed и возвращается в срок (непрочитанным, наверх).
    func snooze(_ keys: [ThreadKey], until: Date) {
        let mine = Set(accounts.map(\.email))
        let keys = keys.filter { mine.contains($0.account) }
        guard !keys.isEmpty else { return }
        let old = snoozes
        var list = snoozes.filter { e in !keys.contains(e.key) }
        for k in keys {
            guard let t = summary(k) else { continue }
            list.append(SnoozeEntry(key: k, until: until, snoozedAt: Date(), summary: t))
        }
        snoozes = list
        saveLocalRules()
        let when = Fmt.snoozeTime(until)
        let title = keys.count == 1 ? "Snoozed until \(when)" : "\(keys.count) conversations snoozed until \(when)"
        let changes = applyLabels(keys, remove: ["INBOX"], title: title) { [weak self] in
            guard let self else { return }
            self.snoozes = old
            self.saveLocalRules()
            Task { await self.removeSnoozeLabel(keys) }
            if self.isSnoozedBox { self.refreshSnoozedList() }
        }
        if changes.isEmpty {
            // уже не во входящих (например, перенос срока в папке Snoozed): плашка всё равно нужна
            setUndo(title, key: keys[0], op: nil) { [weak self] in
                guard let self else { return }
                self.snoozes = old
                self.saveLocalRules()
                if self.isSnoozedBox { self.refreshSnoozedList() }
            }
        }
        if isSnoozedBox { refreshSnoozedList() }
        Task {
            for acc in Set(keys.map(\.account)) {
                guard let id = await ensureSnoozeLabel(acc) else { continue }
                for k in keys where k.account == acc {
                    try? await client(acc).modifyThread(id: k.threadID, add: [id])
                }
            }
        }
    }

    /// Вернуть сейчас.
    func unsnooze(_ keys: [ThreadKey]) {
        var list = snoozes
        for i in list.indices where keys.contains(list[i].key) { list[i].until = Date() }
        snoozes = list
        Task { await wakeDueSnoozes() }
    }

    func dropSnoozes(_ keys: [ThreadKey]) {
        guard snoozes.contains(where: { keys.contains($0.key) }) else { return }
        snoozes.removeAll { keys.contains($0.key) }
        saveLocalRules()
        Task { await removeSnoozeLabel(keys) }
        if isSnoozedBox { refreshSnoozedList() }
    }

    private func snoozeLabelID(_ account: String) async -> String? {
        if labels[account] == nil, let l = try? await client(account).labels() { labels[account] = l }
        for n in Self.snoozeLabelNames { if let id = labelID(named: n, account: account) { return id } }
        return nil
    }

    private func ensureSnoozeLabel(_ account: String) async -> String? {
        if let id = await snoozeLabelID(account) { return id }
        for n in Self.snoozeLabelNames {
            do {
                let l = try await client(account).createLabel(name: n)
                var list = labels[account] ?? []
                list.append(l)
                labels[account] = list
                return l.id
            } catch {
                AppLog.write("snooze label \(n) \(account): \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func removeSnoozeLabel(_ keys: [ThreadKey]) async {
        for acc in Set(keys.map(\.account)) {
            guard let id = await snoozeLabelID(acc) else { continue }
            for k in keys where k.account == acc { try? await client(acc).modifyThread(id: k.threadID, remove: [id]) }
        }
    }

    /// Раз в минуту и при запуске: подошедшие треды возвращаются во входящие непрочитанными.
    func startSnoozeTimer() {
        guard snoozeTimer == nil, !DevTools.isDemo else { return }
        snoozeTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.wakeDueSnoozes()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    func wakeDueSnoozes() async {
        guard isOnline else { return }
        let now = Date()
        let due = snoozes.filter { $0.until <= now && !expiredAccounts.contains($0.key.account) }
        guard !due.isEmpty else { return }
        var done = Set<ThreadKey>()
        for e in due {
            let acc = e.key.account
            guard accounts.contains(where: { $0.email == acc }) else { done.insert(e.key); continue }
            let label = await snoozeLabelID(acc)
            do {
                try await client(acc).modifyThread(id: e.key.threadID, add: ["INBOX", "UNREAD"], remove: label.map { [$0] } ?? [])
                done.insert(e.key)
            } catch GmailError.http(404, _) {
                done.insert(e.key)   // тред удалён: возвращать нечего
            } catch {
                if !(error is URLError) { AppLog.write("wake snooze \(e.key.string): \(error.localizedDescription)") }
            }
        }
        guard !done.isEmpty else { return }
        snoozes.removeAll { done.contains($0.key) }
        saveLocalRules()
        if isSnoozedBox { refreshSnoozedList() } else { await reload() }
        await refreshLabels()
    }

    /// Папка Snoozed собирается из локального списка: строка треда на момент отложения, по сроку возврата.
    func refreshSnoozedList() {
        guard isSnoozedBox else { return }
        let accs = Set(mailbox.account.map { [$0] } ?? accounts.map(\.email))
        let list = snoozes.filter { accs.contains($0.key.account) }.sorted { $0.until < $1.until }.map(\.summary)
        if list != threads { threads = list }
    }

    // MARK: Заглушить и заблокировать

    func isMuted(_ key: ThreadKey) -> Bool { mutedThreads.contains(key.string) }

    /// Заглушить: тред уходит в архив, и новые письма в нём туда же. Повтор снимает заглушение.
    func toggleMute(_ keys: [ThreadKey]) {
        let all = keys.allSatisfy(isMuted)
        var set = mutedThreads
        if all {
            keys.forEach { set.remove($0.string) }
            mutedThreads = set
            saveLocalRules()
            let title = keys.count == 1 ? "Conversation unmuted" : "\(keys.count) conversations unmuted"
            setUndo(title, key: keys[0], op: nil) { [weak self] in
                guard let self else { return }
                var s = self.mutedThreads
                keys.forEach { s.insert($0.string) }
                self.mutedThreads = s
                self.saveLocalRules()
            }
            return
        }
        keys.forEach { set.insert($0.string) }
        mutedThreads = set
        saveLocalRules()
        let title = keys.count == 1 ? "Conversation muted" : "\(keys.count) conversations muted"
        let changes = applyLabels(keys, remove: ["INBOX"], title: title) { [weak self] in
            guard let self else { return }
            var s = self.mutedThreads
            keys.forEach { s.remove($0.string) }
            self.mutedThreads = s
            self.saveLocalRules()
        }
        if changes.isEmpty {
            setUndo(title, key: keys[0], op: nil) { [weak self] in
                guard let self else { return }
                var s = self.mutedThreads
                keys.forEach { s.remove($0.string) }
                self.mutedThreads = s
                self.saveLocalRules()
            }
        }
    }

    /// Отправитель для блока: последний входящий, не я.
    func blockableSender(_ key: ThreadKey) -> String? {
        guard let t = summary(key) else { return nil }
        let p = t.lastIncoming ?? t.lastFrom
        return p.email.isEmpty || isMe(p.email) ? nil : p.email.lowercased()
    }

    func isBlocked(_ email: String, account: String) -> Bool {
        let e = Person.normalized(email)
        return blockedSenders.contains { Person.normalized($0.email) == e && ($0.account == nil || $0.account == account) }
    }

    /// Блок отправителя: правило на будущее и корзина для его тредов на экране. Undo снимает и то и другое.
    func blockSenders(of keys: [ThreadKey]) {
        let emails = Set(keys.compactMap(blockableSender))
        guard !emails.isEmpty else { return }
        let old = blockedSenders
        var list = blockedSenders
        for e in emails where !list.contains(where: { $0.email == e && $0.account == nil }) {
            list.append(BlockedSender(email: e, account: nil, since: Date()))
        }
        blockedSenders = list
        saveLocalRules()
        // его треды на экране тоже уходят, но только те, где последнее письмо от него
        var targets = keys
        for t in threads where !targets.contains(t.key) && emails.contains(t.lastFrom.email.lowercased()) { targets.append(t.key) }
        let title = emails.count == 1 ? "Blocked \(emails.first!)" : "Blocked \(emails.count) senders"
        bulkTrash(targets, title: title) { [weak self] in
            guard let self else { return }
            self.blockedSenders = old
            self.saveLocalRules()
        }
    }

    func unblock(_ sender: BlockedSender) {
        blockedSenders.removeAll { $0.id == sender.id }
        saveLocalRules()
    }

    /// Тред попадает под локальное правило: заглушён или последнее письмо от заблокированного.
    func hitsLocalRule(_ t: ThreadSummary) -> Bool {
        if isMuted(t.key) { return true }
        let from = t.lastFrom.email
        return !from.isEmpty && !isMe(from) && isBlocked(from, account: t.account)
    }

    /// После каждого обновления: заглушённые во входящих уходят в архив, заблокированные в корзину. Без плашки.
    func enforceLocalRules(_ list: [ThreadSummary]) {
        guard !mutedThreads.isEmpty || !blockedSenders.isEmpty else { return }
        let now = Date()
        var mute: [ThreadKey] = []
        var block: [ThreadKey] = []
        for t in list where t.labelIDs.contains("INBOX") {
            if let at = ruleAppliedAt[t.key], now.timeIntervalSince(at) < 300 { continue }
            if isMuted(t.key) { mute.append(t.key) } else if hitsLocalRule(t) { block.append(t.key) }
        }
        guard !mute.isEmpty || !block.isEmpty else { return }
        for k in mute + block { ruleAppliedAt[k] = now }
        if ruleAppliedAt.count > 2000 { ruleAppliedAt = ruleAppliedAt.filter { now.timeIntervalSince($0.value) < 300 } }
        if !mute.isEmpty { applyLabels(mute, remove: ["INBOX"], title: nil, silent: true) }
        if !block.isEmpty { bulkTrash(block, title: "", silent: true) }
    }

    // MARK: Недавние поиски

    func addRecentSearch(_ q: String) {
        let clean = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        list.insert(clean, at: 0)
        list = Array(list.prefix(10))
        recentSearches = list
        UserDefaults.standard.set(list, forKey: Self.recentKey)
    }

    func removeRecentSearch(_ q: String) {
        let list = recentSearches.filter { $0 != q }
        recentSearches = list
        UserDefaults.standard.set(list, forKey: Self.recentKey)
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }
}

/// id писем, прочитанных «Mark all as read»: отмена возвращает им UNREAD.
@MainActor
final class MarkedIDs {
    var byAccount: [String: [String]] = [:]
}

extension Fmt {
    /// Срок отложения: «Tue 08:00», сегодня «18:00», дальше недели «Nov 3, 08:00».
    static func snoozeTime(_ d: Date) -> String {
        let en = Locale(identifier: "en_US")
        let cal = Calendar.current
        let time = d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
        if cal.isDateInToday(d) { return time }
        if cal.isDateInTomorrow(d) { return "tomorrow " + time }
        if d.timeIntervalSinceNow < 6 * 86400 { return d.formatted(.dateTime.weekday(.abbreviated).locale(en)) + " " + time }
        return d.formatted(.dateTime.month(.abbreviated).day().locale(en)) + ", " + time
    }
}
