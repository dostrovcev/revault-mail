import QuickLook
import SwiftUI

/// Тред как в Missive: сверху участники обсуждения и действия, письма карточками на сером фоне,
/// между ними чат команды пузырями (люди и Револт), внизу «Chat with team».
/// HTML (тяжёлый WKWebView) рисуется только по кнопке, по умолчанию чистый текст.
struct ThreadView: View {
    @Environment(MailStore.self) private var store
    @Environment(Translator.self) private var translator
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @Environment(HubStore.self) private var hub
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var showInvite = false
    @AppStorage(Reader.focusKey) private var focusMode = false
    /// Тред окна-читалки. nil значит главное окно: показываем выбранный в списке.
    var pinnedKey: ThreadKey? = nil

    private var threadKey: ThreadKey? { pinnedKey ?? store.selectedThread }
    private var inReader: Bool { pinnedKey != nil }

    /// Звезда: в главном окне по строке списка (обновляется сразу), в окне-читалке по ярлыкам треда.
    private func starred(_ d: ThreadDetail) -> Bool {
        if !inReader, let s = store.selectedSummary { return s.starred }
        return d.labelIDs.contains("STARRED")
    }

    private var currentDetail: ThreadDetail? {
        guard let k = threadKey else { return nil }
        if let d = store.details[k] { return d }
        return hub.snapshotDetail(k)
    }

    var body: some View {
        Group {
            if let d = currentDetail {
                content(d)
            } else {
                VStack { ProgressView().controlSize(.small) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.page)
            }
        }
        // открытый тред живой: свежая версия при открытии и каждые 8 секунд, пока окно на виду
        .task(id: threadKey) {
            guard let k = threadKey, store.isMe(k.account), !DevTools.isDemo else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
                if NSApp.isActive, store.isOnline { await store.loadDetail(k) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let k = threadKey, store.isMe(k.account), !DevTools.isDemo { Task { await store.loadDetail(k) } }
        }
    }

    @ViewBuilder
    private func content(_ d: ThreadDetail) -> some View {
        let canReply = store.isMe(d.account)
        GeometryReader { geo in
        VStack(spacing: 0) {
            toolbar(d, canReply: canReply)
            HLine()
            subjectRow(d)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let items = timeline(d)
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            if let sep = separator(before: i, in: items) {
                                Text(sep).font(.g(11.5, .medium)).foregroundStyle(Theme.faint)
                                    .frame(maxWidth: .infinity).padding(.top, 4)
                            }
                            switch item.kind {
                            case .mail(let m, let idx):
                                MailCard(message: m, account: d.account, canReply: canReply,
                                         isLast: idx == d.sentMessages.count - 1,
                                         startExpanded: idx == d.sentMessages.count - 1 || m.unread || d.sentMessages.count <= 2)
                                    .id(item.id)
                            case .comment(let c):
                                TeamBubble(comment: c, isMe: hub.me?.email == c.author, threadKey: d.key).id(item.id)
                            }
                        }
                        if let st = hub.agentStatus[HubStore.key(d.key)] {
                            HStack(spacing: 8) {
                                RevoltBadge(size: 26)
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text(st == "queued" ? "Revolt is reading the thread" : "Revolt is writing")
                                        .font(.g(13)).foregroundStyle(Theme.accentText)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.agentBg))
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: 1040)
                    .frame(maxWidth: .infinity)
                    .background(alignment: .top) { Color.clear.frame(height: 1).id("top") }
                }
                .id(d.key)
                // как в Spark: открываем на начале последнего письма, не на дне треда
                .onAppear {
                    let target = d.sentMessages.count > 1 ? d.sentMessages.last?.id : nil
                    DispatchQueue.main.async {
                        if let target { proxy.scrollTo(target, anchor: .top) } else { proxy.scrollTo("top", anchor: .top) }
                    }
                }
                // вниз прокручиваем только на НОВОЕ после открытия: пришло письмо, реплика или Револт начал отвечать.
                // Первая загрузка чата (nil -> 0) и подгрузка треда прокрутку не трогают.
                .onChange(of: d.sentMessages.count) { old, new in
                    if old > 0, new > old, let last = d.sentMessages.last?.id { withAnimation { proxy.scrollTo(last, anchor: .top) } }
                    hub.syncIfDiscussed(d)
                }
                .onChange(of: hub.comments[HubStore.key(d.key)]?.count) { old, new in
                    if let old, let new, new > old { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                }
                .onChange(of: hub.agentStatus[HubStore.key(d.key)]) { old, new in
                    if old == nil, new != nil { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                }
            }
            ComposerView(detail: d, available: geo.size.height)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.page)
    }

    // MARK: Шапка

    /// Шапка подстраивается под ширину: сначала всё, потом без подписей, потом остальное уходит в меню «...».
    private func toolbar(_ d: ThreadDetail, canReply: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(d, canReply: canReply, level: 0).fixedSize(horizontal: true, vertical: false)
            toolbarRow(d, canReply: canReply, level: 1).fixedSize(horizontal: true, vertical: false)
            toolbarRow(d, canReply: canReply, level: 2)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Theme.white)
        .clipped()
    }

    /// level 0: полная, 1: без подписей на кнопках, 2: минимум, всё прочее в меню.
    private func toolbarRow(_ d: ThreadDetail, canReply: Bool, level: Int) -> some View {
        return HStack(spacing: 6) {
            Text("Conversation").font(.g(12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Button {
                settings.showAgentPanel = true
                ui.agentFocusNonce = UUID()
            } label: {
                if level == 0 { Label("Ask AI", systemImage: "sparkle") } else { Image(systemName: "sparkle") }
            }.buttonStyle(.dash(.normal, small: true))
            if canReply {
                IconButton("arrowshape.turn.up.left", help: "Reply (R)") { ui.replyRequest = (.reply, nil, UUID()) }
            }
            if level < 2 { IconButton("character.bubble", help: "Перевести на \(settings.translateTarget) последнее и непрочитанные письма") {
                // весь тред не переводим: свёрнутые старые письма никто не читает, а перевод платный
                var targets = d.messages.filter(\.unread)
                if let last = d.messages.last, !targets.contains(where: { $0.id == last.id }) { targets.append(last) }
                for m in targets { translator.translate(id: m.id, text: m.ownText, to: settings.translateTarget) }
            } }
            if canReply {
                IconButton("archivebox", help: "Archive (E)") { store.archive(d.key); if inReader { dismiss() } }
                IconButton("trash", help: "Trash (#)") { store.trash(d.key); if inReader { dismiss() } }
                if !inReader {
                    IconButton("clock", help: "Snooze (H)") { store.listPopover = ListPopover(kind: .snooze, keys: [d.key]) }
                }
            }
            if inReader {
                IconButton("xmark", help: "Close window (Esc)") { Shortcuts.backToInbox(closing: NSApp.keyWindow); dismiss() }
            }
            if !inReader, level < 2 {
                IconButton("macwindow.badge.plus", help: "Open in New Window (⌘O)") { openWindow(id: Reader.windowID, value: d.key) }
                IconButton(focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           help: focusMode ? "Exit focus (⌃⌘F)" : "Focus on message (⌃⌘F)", active: focusMode) { focusMode.toggle() }
            }
            Menu {
                if canReply {
                    Button(starred(d) ? "Unstar" : "Star") { store.toggleStar(d.key) }
                    Button("Mark as unread") { store.toggleUnread(d.key) }
                    Button("Reply all") { ui.replyRequest = (.replyAll, nil, UUID()) }
                    Button("Forward") { ui.replyRequest = (.forward, nil, UUID()) }
                    Divider()
                }
                if level >= 2, hub.isOwner { Button("Invite a colleague") { showInvite = true } }
                if level >= 2 {
                    Button("Translate the thread") {
                        var targets = d.messages.filter(\.unread)
                        if let last = d.messages.last, !targets.contains(where: { $0.id == last.id }) { targets.append(last) }
                        for m in targets { translator.translate(id: m.id, text: m.ownText, to: settings.translateTarget) }
                    }
                }
                if !inReader { Button("Open in New Window") { openWindow(id: Reader.windowID, value: d.key) } }
                Button("Print Conversation") {
                    Task { await MessagePrinter.print(d.sentMessages, subject: d.subject, account: d.account, store: store) }
                }
            } label: { Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(Theme.muted) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
        }
    }

    private func subjectRow(_ d: ThreadDetail) -> some View {
        HStack(spacing: 8) {
            Text(d.subject).font(.g(17, .semibold)).foregroundStyle(Theme.ink).lineLimit(1).textSelection(.enabled)
            ForEach(d.labelIDs.filter { $0.hasPrefix("Label_") }.prefix(3), id: \.self) { l in
                let label = store.labels[d.account]?.first { $0.id == l }
                Text(label?.name ?? l).font(.g(11.5, .medium))
                    .foregroundStyle(Color(hexString: label?.color) ?? Theme.sec)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill((Color(hexString: label?.color) ?? Theme.sec).opacity(0.12)))
            }
            Spacer(minLength: 8)
            if store.isMe(d.account) {
                Button { store.toggleStar(d.key) } label: {
                    Image(systemName: starred(d) ? "star.fill" : "star")
                        .font(.system(size: 13)).foregroundStyle(starred(d) ? Theme.accent : Theme.muted)
                }.buttonStyle(.plain).help("Star (S)")
            }
        }
        .padding(.horizontal, 20).frame(height: 48)
        .background(Theme.white)
        .overlay(alignment: .bottom) { HLine() }
    }

    // MARK: Лента

    struct TimelineItem: Identifiable {
        enum Kind { case mail(MailMessage, Int), comment(HubComment) }
        let id: String
        let date: Date
        let kind: Kind
    }

    /// Письма и чат команды одной лентой по времени.
    private func timeline(_ d: ThreadDetail) -> [TimelineItem] {
        var items = d.sentMessages.enumerated().map { TimelineItem(id: $0.element.id, date: $0.element.date, kind: .mail($0.element, $0.offset)) }
        for c in hub.comments[HubStore.key(d.key)] ?? [] {
            items.append(TimelineItem(id: "c\(c.id)", date: c.date, kind: .comment(c)))
        }
        return items.sorted { $0.date < $1.date }
    }

    /// Разделитель времени перед репликой чата, если с прошлого события прошло больше 20 минут.
    private func separator(before i: Int, in items: [TimelineItem]) -> String? {
        guard case .comment = items[i].kind else { return nil }
        if i > 0, items[i].date.timeIntervalSince(items[i - 1].date) < 1200 { return nil }
        return Fmt.fullDate(items[i].date)
    }
}

struct PersonDot: View {
    let name: String
    let color: Color
    var size: CGFloat = 26
    var sparkle = false
    var body: some View {
        ZStack {
            Circle().fill(color)
            if sparkle {
                Image(systemName: "sparkle").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(initials(name)).font(.g(size * 0.38, .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Theme.white, lineWidth: 2))
    }
}

struct RevoltBadge: View {
    var size: CGFloat = 28
    var body: some View { PersonDot(name: "R", color: Theme.accent, size: size, sparkle: true) }
}

/// Реплика команды пузырём, как чат в Missive: имя жирным в начале текста.
struct TeamBubble: View {
    let comment: HubComment
    let isMe: Bool
    let threadKey: ThreadKey?

    var body: some View {
        if comment.kind == "system" {
            Text("\(comment.name) \(comment.text)").font(.g(12)).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity)
        } else if comment.isAgent {
            HStack(alignment: .top, spacing: 8) {
                RevoltBadge(size: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Revolt").font(.g(13.5, .semibold)).foregroundStyle(Theme.accentText)
                    AgentMessageView(message: AgentMessage(role: .assistant, text: comment.text), threadKey: threadKey)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.agentBg))
                .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 40)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                PersonDot(name: comment.name, color: Color.avatar(for: comment.author), size: 28)
                (Text(comment.name + " ").font(.g(14, .semibold)) + Text(CommentRow.highlighted(comment.text)))
                    .font(.g(14)).lineSpacing(2).foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16).fill(isMe ? Theme.chip : Theme.bubble))
                    .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 40)
            }
            .help(Fmt.fullDate(comment.date))
        }
    }
}

/// Разобранное письмо: цитата, чистый текст, режим показа. Считается один раз на письмо,
/// а не на каждую перерисовку треда (долгие треды и набор в чате команды не тормозят).
@MainActor
final class MessageRender {
    let message: MailMessage
    /// Рассылка по категории Gmail: подвал режется смелее.
    let bulk: Bool
    /// Ответ в треде (есть References): только у ответов есть цитата, которую стоит прятать.
    let isReply: Bool

    private init(_ m: MailMessage) {
        message = m
        bulk = m.labelIDs.contains { $0.hasPrefix("CATEGORY_") && $0 != "CATEGORY_PERSONAL" }
        isReply = !m.references.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static var cache: [String: MessageRender] = [:]
    private static var order: [String] = []

    static func of(_ m: MailMessage) -> MessageRender {
        let key = m.id + "|" + String(m.html?.utf8.count ?? 0) + "|" + String(m.plain?.utf8.count ?? 0)
        if let r = cache[key] { return r }
        let r = MessageRender(m)
        cache[key] = r
        order.append(key)
        if order.count > 300 { cache[order.removeFirst()] = nil }
        return r
    }

    private var plainEmpty: Bool { (message.plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Рассылка с вёрсткой, встроенные картинки или скриншоты: открываем как задумано.
    /// Рассылка с вёрсткой: ей нужна вся ширина карточки. Обычное письмо с картинкой в подписи идёт с теми же отступами, что и текст.
    /// Считается по своей части письма: картинки и таблицы из цитаты прошлых писем вёрсткой не делают.
    lazy var isRichLayout: Bool = CleanText.isRich(html: strippedHTML)
    lazy var defaultHTML: Bool = isRichLayout || CleanText.hasEmbeddedImages(html: strippedHTML)
    lazy var hasCIDImages: Bool = message.html?.range(of: "cid:", options: .caseInsensitive) != nil
    /// Приглашение в календарь: ссылки ответа Google или файл .ics.
    lazy var invite: InviteInfo? = InviteInfo.of(message)

    lazy var strippedHTML: String? = message.html.map { isReply ? HTMLText.stripQuoted(html: $0) : $0 }
    var htmlHasQuote: Bool { strippedHTML != nil && strippedHTML != message.html }

    /// Весь текст письма с цитатой; у HTML-only ссылки сохраняются чипами.
    lazy var fullText: String = {
        if plainEmpty, let h = message.html { return HTMLText.toPlain(h, keepLinks: true) }
        return message.readableText
    }()

    /// Только своё, без хвостовой цитаты.
    lazy var ownText: String = {
        let own: String
        if !isReply && plainEmpty { return fullText }
        if plainEmpty, let h = strippedHTML { own = HTMLText.toPlain(h, keepLinks: true) }
        else { own = HTMLText.stripQuoted(plain: fullText) }
        return own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fullText : own
    }()
    var textHasQuote: Bool { ownText != fullText }

    lazy var cleanOwn: CleanText.Result = CleanText.make(ownText, bulk: bulk)
    lazy var cleanFull: CleanText.Result = CleanText.make(fullText, bulk: bulk)

    private var resolved: (key: String, html: String)?

    /// HTML для показа: с цитатой или без, cid: заменены на data-адреса встроенных картинок.
    func html(quoted: Bool, inline: [String: String]) -> String? {
        guard let base = quoted ? message.html : strippedHTML else { return nil }
        guard !inline.isEmpty else { return base }
        let key = "\(quoted)|\(inline.count)"
        if let r = resolved, r.key == key { return r.html }
        var out = base
        for (cid, data) in inline {
            let id = cid.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            guard !id.isEmpty else { continue }
            out = out.replacingOccurrences(of: "cid:" + id, with: data, options: .caseInsensitive)
            if let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), enc != id {
                out = out.replacingOccurrences(of: "cid:" + enc, with: data, options: .caseInsensitive)
            }
        }
        resolved = (key, out)
        return out
    }
}

/// Письмо карточкой: логотип отправителя, имя и домен, адресаты, время; свёрнутое в одну строку.
struct MailCard: View {
    let message: MailMessage
    let account: String
    let canReply: Bool
    let isLast: Bool
    let startExpanded: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @Environment(MailStore.self) private var store
    @State private var expanded: Bool?
    @State private var showQuoted = false
    @State private var showHTML: Bool?
    @State private var showOriginal = false
    @State private var showFooter = false
    @State private var inline: [String: String] = [:]
    @State private var inlineLoaded = false
    @State private var showDetails = false
    @State private var showSource = false

    var isExpanded: Bool { expanded ?? startExpanded }
    private var render: MessageRender { MessageRender.of(message) }
    /// Рассылка с вёрсткой и письма с картинками внутри открываются как задуманы, переписка чистым текстом.
    private var htmlMode: Bool { showHTML ?? render.defaultHTML }

    private var domain: String { message.from.email.split(separator: "@").last.map(String.init) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SenderAvatar(person: message.from, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if isExpanded {
                            // как в Apple Mail: клик по отправителю показывает все заголовки
                            Button { showDetails = true } label: { senderLine }
                                .buttonStyle(.plain)
                                .help("Show details")
                                .popover(isPresented: $showDetails, arrowEdge: .bottom) { MessageDetailsPopover(message: message) }
                            UnsubscribePill(message: message, account: account)
                        } else {
                            senderLine
                        }
                    }
                    if isExpanded {
                        Button { showDetails = true } label: {
                            HStack(spacing: 3) {
                                Text("to " + (message.to + message.cc).map(\.short).joined(separator: ", "))
                                    .font(.g(13)).foregroundStyle(Theme.muted).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.faint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show details")
                    } else {
                        Text(message.snippet).font(.g(13)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // время на одной строке с действиями: под ними оно висело отдельной строкой и раздувало свёрнутое письмо
                HStack(spacing: 8) {
                    Text(Fmt.listDate(message.date)).font(.g(12)).monospacedDigit().foregroundStyle(Theme.faint)
                    HStack(spacing: 2) {
                        if canReply {
                            IconButton("arrowshape.turn.up.left", help: "Reply") { ui.replyRequest = (.reply, message.id, UUID()) }
                        }
                        Menu {
                            TranslateMenuItem(message: message, showOriginal: $showOriginal)
                            if message.html != nil { Button(htmlMode ? "Clean text" : "Original layout") { showHTML = !htmlMode } }
                            Button(showQuoted ? "Hide quote" : "Show quote") { showQuoted.toggle() }
                            Button("Copy text") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.readableText, forType: .string)
                            }
                            Divider()
                            Button("Message details") { showDetails = true }
                            Button("Show Original") { showSource = true }
                            Button("Print") {
                                Task { await MessagePrinter.print([message], subject: message.subject, account: account, store: store) }
                            }
                        } label: { Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(Theme.muted) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded = !isExpanded }

            if isExpanded, let invite = render.invite {
                InviteBar(info: invite, account: account).padding(.leading, 48)
            }

            if isExpanded {
                MailCardBody(message: message, render: render, htmlMode: htmlMode,
                             html: htmlMode && (inlineLoaded || !render.hasCIDImages)
                                 ? render.html(quoted: showQuoted, inline: inline) : nil,
                             waitingImages: htmlMode && render.hasCIDImages && !inlineLoaded,
                             showQuoted: $showQuoted, showOriginal: $showOriginal, showFooter: $showFooter)

                let files = message.attachments.filter { !$0.inline }
                if !files.isEmpty { AttachmentChips(attachments: files, account: account).padding(.leading, 48) }
                if files.count >= 2 {
                    DownloadAllButton(files: files, subject: message.subject, account: account).padding(.leading, 48)
                }

                if canReply && isLast {
                    HStack(spacing: 6) {
                        replyButton("arrowshape.turn.up.left.2", "Reply all") { ui.replyRequest = (.replyAll, message.id, UUID()) }
                        replyButton("arrowshape.turn.up.left", "Reply") { ui.replyRequest = (.reply, message.id, UUID()) }
                        replyButton("arrowshape.turn.up.right", "Forward") { ui.replyRequest = (.forward, message.id, UUID()) }
                    }
                    .padding(.leading, 48).padding(.top, 2)
                }
            }
        }
        .padding(16)
        .background(Theme.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line.opacity(0.7)))
        .shadow(color: Color.black.opacity(0.045), radius: 4, y: 1.5)
        .sheet(isPresented: $showSource) { RawSourceSheet(message: message, account: account) }
        // встроенные картинки (скриншоты, логотипы подписи) подгружаются, только когда письмо раскрыто
        .task(id: isExpanded && htmlMode && render.hasCIDImages) {
            guard isExpanded, htmlMode, render.hasCIDImages, !inlineLoaded else { return }
            inline = await store.inlineImages(for: message, account: account)
            inlineLoaded = true
        }
    }

    private var senderLine: some View {
        HStack(spacing: 6) {
            Text(message.from.short).font(.g(14.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1).layoutPriority(1)
            if !message.from.name.isEmpty { Text("(\(domain))").font(.g(13)).foregroundStyle(Theme.faint).lineLimit(1) }
        }
        .contentShape(Rectangle())
    }

    private func replyButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.sec)
                .frame(width: 40, height: 30)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Пункт меню перевода отдельной вьюхой: перевод в соседнем письме не перерисовывает всю карточку.
private struct TranslateMenuItem: View {
    let message: MailMessage
    @Binding var showOriginal: Bool
    @Environment(Translator.self) private var translator
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if translator.translations[translator.key(message.id, settings.translateTarget)] != nil {
            Button(showOriginal ? "Show translation" : "Show original") { showOriginal.toggle() }
        } else {
            Button("Translate") { translator.translate(id: message.id, text: message.ownText, to: settings.translateTarget) }
        }
    }
}

/// Тело раскрытого письма: перевод, HTML или чистый текст. Отдельная вьюха читает переводчик сама,
/// поэтому шапка карточки от него не зависит.
private struct MailCardBody: View {
    let message: MailMessage
    let render: MessageRender
    let htmlMode: Bool
    let html: String?
    let waitingImages: Bool
    @Binding var showQuoted: Bool
    @Binding var showOriginal: Bool
    @Binding var showFooter: Bool
    @Environment(Translator.self) private var translator
    @Environment(AppSettings.self) private var settings
    @AppStorage(Reader.zoomKey) private var zoom: Double = 1.0

    private var hasQuote: Bool { htmlMode && message.html != nil ? render.htmlHasQuote : render.textHasQuote }

    var body: some View {
        let tKey = translator.key(message.id, settings.translateTarget)
        let translated = translator.translations[tKey]
        let showingTranslation = translated != nil && !showOriginal
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let translated, !showOriginal {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Label("Translated to \(settings.translateTarget)", systemImage: "character.bubble")
                                .font(.g(12, .medium)).foregroundStyle(Theme.muted)
                            Button("Show original") { showOriginal = true }
                                .buttonStyle(.plain).font(.g(12, .medium)).foregroundStyle(Theme.blueText)
                        }
                        Text(CleanText.linkify(translated))
                    }
                } else if htmlMode, message.html != nil {
                    if let html {
                        HTMLBody(html: html, cacheKey: message.id + (showQuoted ? "|q" : ""), zoom: zoom)
                    } else if waitingImages {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
                    }
                } else {
                    let clean = showQuoted ? render.cleanFull : render.cleanOwn
                    VStack(alignment: .leading, spacing: 8) {
                        Text(clean.body)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let footer = clean.footer {
                            if showFooter {
                                Text(footer).font(.g(12.5 * zoom)).foregroundStyle(Theme.faint)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button(showFooter ? "Hide details" : "Show more") { showFooter.toggle() }
                                .buttonStyle(.plain).font(.g(12, .medium)).foregroundStyle(Theme.muted)
                        }
                    }
                    // иврит и арабский выравниваются по своему направлению
                    .environment(\.layoutDirection, clean.rtl ? .rightToLeft : .leftToRight)
                }
            }
            .font(.g(14.5 * zoom)).lineSpacing(3 * zoom).foregroundStyle(Theme.ink)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)

            // видно только само письмо, прошлая переписка внутри него открывается кнопкой
            if hasQuote && !showingTranslation {
                Button { showQuoted.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showQuoted ? "chevron.up" : "clock.arrow.circlepath").font(.system(size: 10.5, weight: .semibold))
                        Text(showQuoted ? "Hide history" : "Show history").font(.g(12, .medium))
                    }
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(Theme.chip))
                }
                .buttonStyle(.plain)
                .help(showQuoted ? "Hide earlier messages quoted in this email" : "Show earlier messages quoted in this email")
            }
            if translator.inFlight.contains(tKey) {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Translating").font(.g(12)).foregroundStyle(Theme.muted) }
            }
            if let e = translator.errors[tKey] { Text(e).font(.g(12)).foregroundStyle(Theme.accentText) }
        }
        .padding(.leading, htmlMode && !showingTranslation && render.isRichLayout ? 0 : 48)
        .padding(.horizontal, htmlMode && !showingTranslation && render.isRichLayout ? -16 : 0)
    }
}

/// Файлы вложений: кэш в папке приложения, имя очищено от путей. Повторный клик не качает заново
/// и не плодит копии в Downloads; в Downloads файл попадает только по «Save to Downloads».
enum AttachmentFiles {
    static func sanitized(_ name: String) -> String {
        var n = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n == "." || n == ".." { n = "attachment" }
        return n
    }

    static func cachedURL(_ a: Attachment) -> URL {
        AppPaths.cacheDir
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(sanitized(a.messageID), isDirectory: true)
            .appendingPathComponent(String(a.size), isDirectory: true)
            .appendingPathComponent(sanitized(a.filename))
    }

    static func isCached(_ a: Attachment) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(a).path)
    }

    @MainActor
    static func file(_ a: Attachment, account: String, store: MailStore, report: Bool = true) async -> URL? {
        let url = cachedURL(a)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            let data = try await store.client(account).attachment(messageID: a.messageID, id: a.id)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            if report { store.error = error.localizedDescription }
            AppLog.write("attachment \(a.filename): \(error.localizedDescription)")
            return nil
        }
    }

    /// Копия в Downloads со свободным именем «file (1).pdf».
    static func saveToDownloads(_ src: URL) -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = src.lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var url = dir.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        do { try FileManager.default.copyItem(at: src, to: url); return url } catch { return nil }
    }
}

struct AttachmentChips: View {
    let attachments: [Attachment]
    let account: String
    @Environment(MailStore.self) private var store
    @State private var busy: Set<String> = []
    @State private var preview: URL?
    @State private var thumbs: [String: NSImage] = [:]

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(attachments) { a in
                Button { run(a) { url in preview = url } } label: { chip(a) }
                    .buttonStyle(.plain)
                    .help("Preview (Quick Look). Right click to open or save")
                    .contextMenu {
                        Button("Quick Look") { run(a) { url in preview = url } }
                        Button("Open") { run(a) { url in NSWorkspace.shared.open(url) } }
                        Button("Save to Downloads") {
                            run(a) { url in
                                if let saved = AttachmentFiles.saveToDownloads(url) {
                                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                                }
                            }
                        }
                    }
            }
        }
        .quickLookPreview($preview)
        .task(id: attachments.map(\.id)) { await loadThumbs() }
    }

    private func chip(_ a: Attachment) -> some View {
        HStack(spacing: 6) {
            if busy.contains(a.id) {
                ProgressView().controlSize(.mini)
            } else if let img = thumbs[a.id] {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Text(a.filename).font(.g(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)).font(.g(12)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.white))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }

    private func run(_ a: Attachment, _ then: @escaping (URL) -> Void) {
        guard !busy.contains(a.id) else { return }
        busy.insert(a.id)
        Task {
            if let url = await AttachmentFiles.file(a, account: account, store: store) { then(url) }
            busy.remove(a.id)
        }
    }

    /// Миниатюры картинок до 5 МБ: файл всё равно ляжет в кэш и потом откроется мгновенно.
    private func loadThumbs() async {
        for a in attachments where a.mimeType.hasPrefix("image/") && a.size < 5_000_000 && thumbs[a.id] == nil {
            guard let url = await AttachmentFiles.file(a, account: account, store: store, report: false),
                  let img = NSImage(contentsOf: url) else { continue }
            thumbs[a.id] = img
        }
    }
}

/// Простой перенос элементов по строкам.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x)
        }
        return CGSize(width: min(width, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
