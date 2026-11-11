import SwiftUI

/// Комментарий внутри треда, как заметка команды в Missive: тонкая полоса слева, имя, время, текст.
struct CommentRow: View {
    let comment: HubComment
    let threadKey: ThreadKey?
    @Environment(HubStore.self) private var hub

    var body: some View {
        if comment.kind == "system" {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus").font(.system(size: 10)).foregroundStyle(Theme.faint)
                Text("\(comment.name) \(comment.text)").font(.g(12)).foregroundStyle(Theme.faint)
                Text(Fmt.listDate(comment.date)).font(.g(11.5)).foregroundStyle(Theme.ghost)
            }
            .padding(.horizontal, 28).padding(.vertical, 8)
        } else {
            HStack(alignment: .top, spacing: 10) {
                badge
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(comment.isAgent ? "Revolt" : comment.name).font(.g(13, .semibold)).foregroundStyle(Theme.ink)
                        Text(comment.isAgent ? "agent" : "internal").font(.g(11, .medium))
                            .foregroundStyle(comment.isAgent ? Theme.accentText : Theme.muted)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(comment.isAgent ? Theme.agentBg : Theme.chip))
                        Text(Fmt.listDate(comment.date)).font(.g(11.5)).monospacedDigit().foregroundStyle(Theme.faint)
                    }
                    if comment.isAgent {
                        AgentMessageView(message: AgentMessage(role: .assistant, text: comment.text), threadKey: threadKey)
                    } else {
                        Text(Self.highlighted(comment.text)).font(.g(14)).lineSpacing(2).foregroundStyle(Theme.ink)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 26).padding(.trailing, 28).padding(.vertical, 12)
            .background(comment.isAgent ? Theme.agentBg.opacity(0.6) : Theme.page.opacity(0.7))
            .overlay(alignment: .leading) {
                Rectangle().fill(comment.isAgent ? Theme.accent : Theme.ghost).frame(width: 2)
            }
        }
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(comment.isAgent ? Theme.accent : Theme.ink)
            if comment.isAgent {
                Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(initials(comment.name)).font(.g(10.5, .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
    }

    /// @упоминания выделены акцентом.
    static func highlighted(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        let ns = s as NSString
        if let re = try? NSRegularExpression(pattern: "@[\\p{L}0-9._-]+") {
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                if let r = Range(m.range, in: s), let ar = Range(r, in: a) {
                    a[ar].foregroundColor = Theme.blueText
                    a[ar].font = .g(14, .medium)
                }
            }
        }
        return a
    }
}

/// Кто в обсуждении и кнопка «Invite».
struct MembersBar: View {
    let detail: ThreadDetail
    @Environment(HubStore.self) private var hub
    @State private var showInvite = false

    var body: some View {
        let k = HubStore.key(detail.key)
        let list = hub.members[k] ?? []
        HStack(spacing: 6) {
            HStack(spacing: -6) {
                ForEach(list.prefix(5)) { p in
                    Text(initials(p.display)).font(.g(10, .semibold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.ink2))
                        .overlay(Circle().stroke(Theme.white, lineWidth: 2))
                        .help(p.email)
                }
            }
            if hub.isOwner {
                Button { showInvite = true } label: { Label(list.isEmpty ? "Invite" : "\(list.count)", systemImage: "person.badge.plus") }
                    .buttonStyle(.dash(.normal, small: true))
                    .help("Invite to the discussion")
                    .popover(isPresented: $showInvite, arrowEdge: .bottom) { InvitePopover(detail: detail) }
            }
        }
    }
}

struct InvitePopover: View {
    let detail: ThreadDetail
    @Environment(HubStore.self) private var hub
    @State private var email = ""
    @State private var name = ""
    @State private var busy = false
    @State private var done: String?
    @State private var failure: String?

    var body: some View {
        let k = HubStore.key(detail.key)
        let current = Set((hub.members[k] ?? []).map(\.email))
        VStack(alignment: .leading, spacing: 10) {
            Text("Invite a teammate").font(.g(15, .semibold)).foregroundStyle(Theme.ink)
            Text("They will see the emails in this thread and the discussion, and can write and ask Revolt. They cannot reply from your inbox.")
                .font(.g(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            let known = hub.people.filter { $0.role == "member" && !current.contains($0.email) }
            if !known.isEmpty {
                ForEach(known) { p in
                    Button { Task { await add(p.email, p.display) } } label: {
                        HStack(spacing: 10) {
                            PersonDot(name: p.display, color: Color.avatar(for: p.email), size: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(p.display).font(.g(13.5, .medium)).foregroundStyle(Theme.ink)
                                Text(p.email).font(.g(12)).foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            Text("Invite").font(.g(12, .medium)).foregroundStyle(Theme.blueText)
                        }
                        .padding(.horizontal, 6).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HLine()
            }
            TextField("Email (Google)", text: $email).textFieldStyle(.roundedBorder).font(.g(13))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).font(.g(13))
            if let failure {
                Text(failure).font(.g(12)).foregroundStyle(Theme.accentText).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let done { Text(done).font(.g(12)).foregroundStyle(Theme.green) }
                Spacer()
                Button(busy ? "Inviting..." : "Invite") { Task { await add(email, name) } }
                    .buttonStyle(.dash(.primary, small: true))
                    .disabled(busy || !email.contains("@"))
            }
            if !(hub.members[k] ?? []).isEmpty {
                HLine()
                ForEach(hub.members[k] ?? []) { p in
                    HStack {
                        Text(p.display).font(.g(13, .medium))
                        Text(p.email).font(.g(12)).foregroundStyle(Theme.faint)
                        Spacer()
                        Button("Remove") {
                            Task {
                                failure = nil
                                if !(await hub.removeMember(p.email, from: detail.key)) {
                                    failure = hub.error ?? "Couldn't remove \(p.email). Try again."
                                }
                            }
                        }
                            .buttonStyle(.dash(.ghost, small: true))
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Theme.white)
    }

    private func add(_ e: String, _ n: String) async {
        busy = true
        failure = nil
        done = nil
        if await hub.invite(email: e.trimmingCharacters(in: .whitespaces), name: n, to: detail) {
            done = "Added: \(e)"
            email = ""; name = ""
        } else {
            failure = hub.error ?? "Invite failed. Try again."
        }
        busy = false
    }
}

/// Чат команды внизу треда, как «Chat with team» в Missive: Enter отправить, @ подсказывает людей и Револта.
struct CommentComposer: View {
    let detail: ThreadDetail
    @Environment(HubStore.self) private var hub
    @Binding var text: String
    var focusNonce = UUID()
    @FocusState private var focused: Bool
    @State private var sending = false
    @State private var failure: String?

    private var mentionQuery: String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let tail = text[text.index(after: at)...]
        if tail.contains(" ") || tail.contains("\n") { return nil }
        return String(tail).lowercased()
    }

    private var suggestions: [HubPerson] {
        guard let q = mentionQuery else { return [] }
        let revolt = HubPerson(email: "revolt@agent", name: "Revolt", role: "agent")
        let all = hub.people.contains { $0.role == "agent" } ? hub.people : [revolt] + hub.people
        return all.filter { $0.email != hub.me?.email }
            .filter { q.isEmpty || $0.handle.hasPrefix(q) || $0.display.lowercased().hasPrefix(q) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text(failure).font(.g(12)).foregroundStyle(Theme.accentText).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { self.failure = nil } label: { Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.faint) }
                        .buttonStyle(.plain)
                }
                .padding(.leading, 38)
            }
            if let st = hub.agentStatus[HubStore.key(detail.key)] {
                HStack(spacing: 8) {
                    Text(st == "queued" ? "Revolt is queued" : "Revolt is working").font(.g(12)).foregroundStyle(Theme.accentText)
                    Button("Stop") { Task { await hub.cancel(thread: detail.key) } }
                        .buttonStyle(.dash(.ghost, small: true))
                        .help("Stop Revolt in this thread")
                }
                .padding(.leading, 38)
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { p in
                        Button { complete(p) } label: {
                            HStack(spacing: 8) {
                                PersonDot(name: p.display, color: p.role == "agent" ? Theme.accent : Theme.ink2, size: 22, sparkle: p.role == "agent")
                                Text(p.display).font(.g(13.5, .medium)).foregroundStyle(Theme.ink)
                                Text(p.role == "agent" ? "AI teammate" : p.email).font(.g(12)).foregroundStyle(Theme.faint)
                                Spacer()
                            }
                            .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .frame(maxWidth: 360)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .shadow(color: Color(hex: 0x14282B).opacity(0.08), radius: 10, y: 4)
            }
            HStack(alignment: .bottom, spacing: 10) {
                PersonDot(name: hub.me?.display ?? "You", color: Color.avatar(for: hub.me?.email ?? "d"), size: 28)
                HStack(alignment: .bottom, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $text)
                            .font(.g(14))
                            .focused($focused)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 22, maxHeight: 140)
                            .fixedSize(horizontal: false, vertical: true)
                            .onKeyPress(.return, phases: .down) { press in
                                if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                                if let first = suggestions.first { complete(first); return .handled }
                                submit()
                                return .handled
                            }
                        if text.isEmpty {
                            Text("Note for the team").font(.g(14)).foregroundStyle(Theme.faint)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .padding(.vertical, 2)
                    Button { insert("@") } label: { Image(systemName: "at").font(.system(size: 13)).foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain).help("Mention a teammate").frame(height: 24)
                    Button { insert("@revolt ") } label: { Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(Theme.accent) }
                        .buttonStyle(.plain).help("Ask Revolt").frame(height: 24)
                    Button { submit() } label: {
                        Group {
                            if sending { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                        }
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.ghost : Theme.blue))
                    }
                    .buttonStyle(.plain)
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 20).fill(Theme.white))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(focused ? Theme.blue.opacity(0.5) : Theme.border))
                .shadow(color: Color.black.opacity(0.04), radius: 4, y: 1)
            }
            if !hub.online {
                Text(hub.reconnecting
                     ? "Team chat is reconnecting. If this stays, sign in again from your card at the bottom left."
                     : "Team chat is offline. It reconnects on its own when the server is reachable.")
                    .font(.g(11.5)).foregroundStyle(Theme.faint)
                    .padding(.leading, 38)
            }
        }
        .onChange(of: focusNonce) { _, _ in focused = true }
    }

    private func insert(_ s: String) {
        text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + s
        focused = true
    }

    private func complete(_ p: HubPerson) {
        if let at = text.lastIndex(of: "@") { text = String(text[..<at]) }
        text += "@" + p.handle + " "
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        sending = true
        failure = nil
        Task {
            if await hub.comment(t, on: detail) {
                text = ""
            } else {
                failure = hub.error ?? "Comment not sent. Try again."
            }
            sending = false
        }
    }
}
