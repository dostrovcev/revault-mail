import SwiftUI

/// Панель агента справа, как Agent Panel в Zed: тред сверху, лента, поле ввода снизу.
struct AgentPanel: View {
    @Environment(AgentStore.self) private var agent
    @Environment(MailStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(UIState.self) private var ui
    @Environment(HubStore.self) private var hub
    @State private var input = ""
    @State private var attachThread = true
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var showHistory = false
    @FocusState private var inputFocused: Bool

    private var chat: AgentChat? { agent.activeChat }
    private var thread: ThreadDetail? { store.selectedDetail }

    /// Письмо, которое уйдёт агенту контекстом в этом ходе.
    private var contextThread: ThreadDetail? {
        if let k = chat?.threadKey { return store.details[k] }
        return attachThread ? thread : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HLine()
            if let c = chat, !c.messages.isEmpty { messages(c) } else { emptyState }
            composer
        }
        .background(Theme.page)
        .overlay(alignment: .leading) { VLine() }
        .onChange(of: ui.agentFocusNonce) { _, _ in inputFocused = true }
        .onAppear {
            inputFocused = true
            agent.openThread = { [weak store] in store?.selectedThread }
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") { if let c = chat { agent.rename(c.id, to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 4) {
            Button { showHistory.toggle() } label: {
                HStack(spacing: 6) {
                    Text(chat?.title ?? "New chat").font(.g(13, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHistory, arrowEdge: .bottom) { history }
            Spacer(minLength: 8)
            IconButton("plus", help: "New chat (⌥⌘T)") { agent.activeChatID = nil; inputFocused = true }
            if let c = chat {
                Menu {
                    Button("Rename") { newTitle = c.title; renaming = true }
                    if let k = c.threadKey { Button("Open email") { store.selectedThread = k } }
                    if c.threadKey == nil, let t = thread { Button("Attach to open email") { agent.attach(c.id, thread: t) } }
                    if c.threadKey != nil { Button("Detach from email") { agent.attach(c.id, thread: nil) } }
                    Divider()
                    Button("Delete chat", role: .destructive) { agent.delete(c.id) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(Theme.muted) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
            }
            IconButton("sidebar.right", help: "Hide panel (⇧⌘J)") { settings.showAgentPanel = false }
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 48)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let t = thread, !agent.chats(for: t.key).isEmpty {
                Text("This email").font(.g(11, .medium)).foregroundStyle(Theme.faint).padding(.horizontal, 8).padding(.top, 4)
                ForEach(agent.chats(for: t.key)) { c in historyRow(c) }
                HLine().padding(.vertical, 4)
            }
            Text("Recent").font(.g(11, .medium)).foregroundStyle(Theme.faint).padding(.horizontal, 8).padding(.top, 4)
            ForEach(Array(agent.sortedChats.prefix(20))) { c in historyRow(c) }
            if agent.chats.isEmpty {
                Text("No chats yet").font(.g(12.5)).foregroundStyle(Theme.ghost).padding(8)
            }
        }
        .padding(8)
        .frame(width: 320)
        .background(Theme.white)
    }

    private func historyRow(_ c: AgentChat) -> some View {
        NavRow(title: c.title, icon: c.threadKey == nil ? "bubble.left" : "envelope", selected: c.id == agent.activeChatID,
               trailing: Fmt.relative(c.updatedAt)) {
            agent.activeChatID = c.id
            if let k = c.threadKey { store.selectedThread = k }
            showHistory = false
        }
    }

    // MARK: Лента

    private func messages(_ c: AgentChat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(c.messages) { m in AgentMessageView(message: m, threadKey: c.threadKey).id(m.id) }
                    if agent.running.contains(c.id) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text(agent.status[c.id] ?? "Thinking").font(.g(12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onAppear { proxy.scrollTo("bottom") }
            .onChange(of: c.messages.last?.text) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: c.messages.count) { _, _ in proxy.scrollTo("bottom") }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            if let t = thread {
                Text(t.subject).font(.g(15, .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                Text("Ask anything about this email, or pick an action.").font(.g(13)).foregroundStyle(Theme.muted)
                    .padding(.bottom, 8)
                ForEach(Self.quick, id: \.1) { icon, q in
                    QuickAction(icon: icon, text: q) { submit(q) }
                }
            } else {
                Text("Revolt").font(.g(15, .semibold)).foregroundStyle(Theme.ink)
                Text("Use your own Claude or ChatGPT account. Choose Claude Code or Codex in Settings → Agent, then open an email to discuss it.")
                    .font(.g(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    static let quick: [(String, String)] = [
        ("text.alignleft", "Summary: what this email is about and what they want from me"),
        ("arrowshape.turn.up.left", "Draft a reply to the last email"),
        ("person.text.rectangle", "Who is this person and what is our history with them"),
        ("checklist", "Tasks and deadlines from this email"),
        ("character.bubble", "Translate the thread into Russian"),
    ]

    // MARK: Ввод

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let t = contextThread {
                    HStack(spacing: 5) {
                        Image(systemName: "envelope").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        Text(t.subject).font(.g(12, .medium)).foregroundStyle(Theme.sec).lineLimit(1)
                        if chat?.threadKey == nil {
                            Button { attachThread = false } label: { Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.faint) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
                } else if thread != nil {
                    Button { attachThread = true } label: { Label("Attach email", systemImage: "plus") }
                        .buttonStyle(.dash(.ghost, small: true))
                }
                Spacer()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $input)
                    .font(.g(13.5))
                    .focused($inputFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        submit(input)
                        return .handled
                    }
                if input.isEmpty {
                    Text(thread != nil ? "What should Revolt answer?" : "Message Revolt").font(.g(13.5)).foregroundStyle(Theme.faint).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            HStack(spacing: 6) {
                Text(settings.agentProvider == "codex" ? "Codex · your ChatGPT" : "Claude Code · your Claude")
                    .font(.g(12, .medium)).foregroundStyle(Theme.muted)
                Spacer()
                if let c = chat, agent.running.contains(c.id) {
                    Button { agent.stop(c.id) } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                        .buttonStyle(.dash(.primary, small: true)).help("Stop")
                } else {
                    Button { submit(input) } label: { Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.dash(canSendReply ? .ghost : .primary, small: true))
                        .help("Ask Revolt. Nothing is sent (Return)")
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if canSendReply {
                        Button { sendReply() } label: { Label("Send", systemImage: "paperplane.fill") }
                            .buttonStyle(.dash(.primary, small: true))
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Revolt writes this reply and sends it. You get 10 seconds to undo (Cmd+Return)")
                            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .padding(12)
    }

    /// Кнопка Send есть, когда открыт тред из своего ящика.
    private var canSendReply: Bool {
        guard let t = thread else { return false }
        return store.isMe(t.account)
    }

    private func sendReply() {
        guard let t = thread else { return }
        agent.writeAndSend(input, thread: t)
        input = ""
    }

    private func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let c = chat, agent.running.contains(c.id) { return }
        let ctx = contextThread
        var chatID = chat?.id
        if chatID == nil, let ctx { chatID = agent.newChat(thread: ctx) }
        agent.send(t, chatID: chatID, thread: ctx, account: ctx?.account)
        input = ""
    }
}

struct QuickAction: View {
    let icon: String
    let text: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.icon).frame(width: 16)
                Text(text).font(.g(13)).foregroundStyle(Theme.ink2).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.hover : Theme.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct AgentMessageView: View {
    let message: AgentMessage
    let threadKey: ThreadKey?
    @Environment(AgentStore.self) private var agent

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .textSelection(.enabled)
                .font(.g(13))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
        case .tool:
            Label(message.text, systemImage: "wrench.and.screwdriver")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.g(12)).foregroundStyle(.orange).textSelection(.enabled)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.segments(message.text).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let s):
                        Text(Self.markdown(s)).font(.g(13)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .reply(let s):
                        ReplyCard(text: s, threadKey: threadKey)
                    case .code(let s):
                        Text(s).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    enum Segment { case text(String), reply(String), code(String) }

    static func segments(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var rest = Substring(text)
        while let open = rest.range(of: "```") {
            let before = String(rest[..<open.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(before.trimmingCharacters(in: .newlines))) }
            let afterOpen = rest[open.upperBound...]
            let langEnd = afterOpen.firstIndex(of: "\n") ?? afterOpen.endIndex
            let lang = afterOpen[..<langEnd].trimmingCharacters(in: .whitespaces).lowercased()
            let bodyStart = langEnd < afterOpen.endIndex ? afterOpen.index(after: langEnd) : langEnd
            let bodyPart = afterOpen[bodyStart...]
            if let close = bodyPart.range(of: "```") {
                let body = String(bodyPart[..<close.lowerBound]).trimmingCharacters(in: .newlines)
                out.append(["reply", "email", "письмо"].contains(lang) ? .reply(body) : .code(body))
                rest = bodyPart[close.upperBound...]
            } else {
                // блок ещё пишется
                let body = String(bodyPart)
                out.append(["reply", "email", "письмо"].contains(lang) ? .reply(body) : .code(body))
                rest = ""
            }
        }
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(String(rest).trimmingCharacters(in: .newlines))) }
        return out
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct ReplyCard: View {
    let text: String
    let threadKey: ThreadKey?
    @Environment(AgentStore.self) private var agent
    @Environment(UIState.self) private var ui
    @Environment(MailStore.self) private var store

    @State private var state = ""

    /// Хеш стабилен между запусками (hashValue в Swift каждый раз другой).
    private var stateKey: String {
        var h: UInt64 = 5381
        for b in text.utf8 { h = (h &* 33) &+ UInt64(b) }
        return "draftCard." + String(h, radix: 36)
    }

    var body: some View {
        Group {
            switch state {
            case "hidden": EmptyView()
            case "collapsed": collapsedCard
            default: fullCard
            }
        }
        .onAppear { state = UserDefaults.standard.string(forKey: stateKey) ?? "" }
    }

    private func setState(_ v: String) {
        state = v
        UserDefaults.standard.set(v, forKey: stateKey)
    }

    /// Свёрнутый черновик: одна строка, клик раскрывает; крестик убирает карточку из ленты совсем.
    private var collapsedCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope.open").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text("Draft reply").font(.g(12, .medium)).foregroundStyle(Theme.muted)
            Text(text.replacingOccurrences(of: "\n", with: " ")).font(.g(12)).foregroundStyle(Theme.faint).lineLimit(1)
            Spacer(minLength: 4)
            Button { setState("hidden") } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from the thread")
        }
        .padding(.horizontal, 10).frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .contentShape(Rectangle())
        .onTapGesture { setState("") }
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Draft reply", systemImage: "envelope.open").font(.g(12)).foregroundStyle(Theme.muted)
                Spacer()
                Button { setState("collapsed") } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).help("Collapse")
                Button { setState("hidden") } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from the thread")
            }
            Text(text).font(.g(13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    if let k = threadKey, store.selectedThread != k { store.selectedThread = k }
                    if threadKey != nil || store.selectedThread != nil {
                        agent.pendingInsert = (threadKey ?? store.selectedThread, text)
                    } else {
                        ui.newMessagePrefill = ("", "", text)
                        ui.showNewMessage = true
                    }
                } label: { Label(threadKey != nil || store.selectedThread != nil ? "Insert into reply" : "New email", systemImage: "arrow.down.doc") }
                    .buttonStyle(.dashPrimary).controlSize(.small)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }
}
