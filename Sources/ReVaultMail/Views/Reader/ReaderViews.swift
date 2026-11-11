import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Мелкие вьюхи карточки письма: подробности заголовков, исходник, отписка, ответ на приглашение, «скачать все».

/// Все заголовки письма по клику на отправителя, с копированием адресов.
struct MessageDetailsPopover: View {
    let message: MailMessage
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            people("From", [message.from])
            if !message.replyTo.isEmpty { people("Reply-To", message.replyTo) }
            if !message.to.isEmpty { people("To", message.to) }
            if !message.cc.isEmpty { people("Cc", message.cc) }
            row("Date") { Text(MessageDetailsFormat.long(message.date)).font(.g(13)).foregroundStyle(Theme.ink).textSelection(.enabled) }
            row("Subject") {
                Text(message.subject.isEmpty ? "(no subject)" : message.subject).font(.g(13)).foregroundStyle(Theme.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            let all = ([message.from] + message.replyTo + message.to + message.cc).map(\.email)
            HStack {
                Spacer()
                Button(copied == "*" ? "Copied" : "Copy all addresses") { copy(Array(NSOrderedSet(array: all)).compactMap { $0 as? String }.joined(separator: ", "), tag: "*") }
                    .buttonStyle(.dash(.normal, small: true))
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func row<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.g(12, .medium)).foregroundStyle(Theme.faint).frame(width: 64, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func people(_ title: String, _ list: [Person]) -> some View {
        row(title) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            if !p.name.isEmpty { Text(p.name).font(.g(13, .medium)).foregroundStyle(Theme.ink) }
                            Text(p.email).font(.g(12.5)).foregroundStyle(p.name.isEmpty ? Theme.ink : Theme.muted)
                        }
                        .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button { copy(p.email, tag: title + p.email) } label: {
                            Image(systemName: copied == title + p.email ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain).help("Copy address")
                    }
                }
            }
        }
    }

    private func copy(_ s: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = tag
    }
}

/// Исходник письма моноширинным текстом: копировать, сохранить .eml.
struct RawSourceSheet: View {
    let message: MailMessage
    let account: String
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var raw: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Original message").font(.g(15, .semibold)).foregroundStyle(Theme.ink)
                Text(message.subject).font(.g(13)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw ?? "", forType: .string)
                }.buttonStyle(.dash(.normal, small: true)).disabled(raw == nil)
                Button("Save as .eml") { save() }.buttonStyle(.dash(.normal, small: true)).disabled(raw == nil)
                Button("Close") { dismiss() }.buttonStyle(.dash(.primary, small: true)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).frame(height: 52)
            HLine()
            Group {
                if let raw {
                    SourceTextView(text: raw)
                } else if let error {
                    Text(error).font(.g(13)).foregroundStyle(Theme.accentText).padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 700)
        .background(Theme.white)
        .task {
            do { raw = try await store.client(account).rawSource(id: message.id) } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard let raw else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentFiles.sanitized(message.subject.isEmpty ? "message" : message.subject) + ".eml"
        panel.allowedContentTypes = [.init(filenameExtension: "eml") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { try? Data(raw.utf8).write(to: url) }
    }
}

/// Большой текст через NSTextView: SwiftUI Text на мегабайтах исходника тормозит.
struct SourceTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            tv.textContainerInset = NSSize(width: 12, height: 10)
            tv.string = text
        }
        return scroll
    }
    func updateNSView(_ v: NSScrollView, context: Context) {
        if let tv = v.documentView as? NSTextView, tv.string != text { tv.string = text }
    }
}

/// Пилюля «Unsubscribe» в шапке рассылки.
struct UnsubscribePill: View {
    let message: MailMessage
    let account: String
    @Environment(MailStore.self) private var store
    @State private var info: UnsubscribeInfo?
    @State private var confirm = false
    @State private var busy = false
    @State private var done = false

    var body: some View {
        Group {
            if let info {
                Button { tap(info) } label: {
                    HStack(spacing: 4) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(done ? "Unsubscribed" : "Unsubscribe").font(.g(11.5, .medium))
                    }
                    .foregroundStyle(done ? Theme.green : Theme.sec)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Capsule().fill(done ? Theme.greenBg : Theme.chip))
                }
                .buttonStyle(.plain)
                .disabled(busy || done)
                .help(help(info))
                .confirmationDialog("Unsubscribe from \(message.from.short)?", isPresented: $confirm) {
                    Button("Unsubscribe") { Task { await oneClick(info) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The sender will be asked to stop sending you these emails.")
                }
            }
        }
        .task(id: message.id) {
            done = UnsubscribeCache.done.contains(message.id)
            info = await UnsubscribeCache.load(message, account: account, store: store)
        }
    }

    private func help(_ i: UnsubscribeInfo) -> String {
        if i.oneClick { return "Unsubscribe in one click" }
        if i.https != nil { return "Open the unsubscribe page" }
        return "Send an unsubscribe email"
    }

    private func tap(_ i: UnsubscribeInfo) {
        if i.oneClick { confirm = true; return }
        if let url = i.https { NSWorkspace.shared.open(url); return }
        if let m = i.mailto {
            let p = UnsubscribeInfo.mailtoParts(m)
            let ui = UIState.main
            ui?.newMessagePrefill = (p.to, p.subject, p.body)
            ui?.showNewMessage = true
            Shortcuts.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func oneClick(_ i: UnsubscribeInfo) async {
        guard let url = i.https else { return }
        busy = true
        let ok = await UnsubscribeInfo.oneClick(url)
        busy = false
        if ok {
            done = true
            UnsubscribeCache.done.insert(message.id)
        } else {
            // сервер отказал: открываем страницу отписки, пусть человек закончит там
            NSWorkspace.shared.open(url)
        }
    }
}

/// Полоса ответа на приглашение: «Going? Yes / Maybe / No» отвечает прямо через Google Calendar API
/// (статус гостя меняется на месте, организатору уходит уведомление), текущий ответ подсвечен.
/// Без доступа к календарю или без события в календаре открывается ссылка Google, как раньше.
struct InviteBar: View {
    let info: InviteInfo
    let account: String
    @Environment(MailStore.self) private var store
    @State private var status: GmailClient.RSVP?
    @State private var sending: GmailClient.RSVP?
    @State private var busy = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            Text(info.canRSVP ? "Going?" : "Calendar invitation")
                .font(.g(12.5, .medium)).foregroundStyle(Theme.ink)
                .lineLimit(1).fixedSize()
                .padding(.trailing, 2)
            if info.canRSVP {
                answer("Yes", .accepted, info.yes)
                answer("Maybe", .tentative, info.maybe)
                answer("No", .declined, info.no)
            }
            Spacer(minLength: 6)
            if let v = info.view {
                openButton { NSWorkspace.shared.open(v) }
            } else if let ics = info.ics {
                openButton { openICS(ics) }.disabled(busy)
            }
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.agentBg))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25)))
        .task(id: info.eventID) {
            guard let id = info.eventID, !DevTools.isDemo else { return }
            status = try? await store.client(account).inviteStatus(eventID: id)
        }
    }

    /// «Open in Calendar» словами, если влезает, иначе одной иконкой: полоса всегда в одну строку.
    private func openButton(_ action: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            Button(action: action) { Text("Open in Calendar") }.buttonStyle(.dash(.ghost, small: true))
            Button(action: action) { Image(systemName: "arrow.up.forward.square").font(.system(size: 13)) }
                .buttonStyle(.dash(.ghost, small: true))
        }
        .help("Open in Google Calendar")
    }

    @ViewBuilder
    private func answer(_ title: String, _ value: GmailClient.RSVP, _ url: URL?) -> some View {
        if let url {
            Button { Task { await respond(value, fallback: url) } } label: {
                HStack(spacing: 4) {
                    if sending == value { ProgressView().controlSize(.mini) }
                    else if status == value { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                    Text(title)
                }
            }
            .buttonStyle(.dash(status == value ? .primary : .normal, small: true))
            .disabled(sending != nil)
            .help(status == value ? "Your answer" : "Answer \(title)")
        }
    }

    private func respond(_ value: GmailClient.RSVP, fallback: URL) async {
        guard let id = info.eventID, !DevTools.isDemo else { NSWorkspace.shared.open(fallback); return }
        sending = value
        defer { sending = nil }
        do {
            status = try await store.client(account).respond(eventID: id, status: value)
        } catch GmailClient.CalendarError.noScope {
            // вход старый, без календаря: сразу новый вход в этот ящик и тот же ответ ещё раз
            await store.relogin(account)
            do { status = try await store.client(account).respond(eventID: id, status: value) }
            catch {
                store.error = error.localizedDescription
                NSWorkspace.shared.open(fallback)
            }
        } catch let e as GmailClient.CalendarError {
            // события нет или API выключен: ответ всё равно должен состояться, открываем ссылку Google
            store.error = e.localizedDescription
            NSWorkspace.shared.open(fallback)
        } catch {
            store.error = error.localizedDescription
            AppLog.write("rsvp \(account): \(error.localizedDescription)")
        }
    }

    private func openICS(_ a: Attachment) {
        busy = true
        Task {
            if let url = await AttachmentFiles.file(a, account: account, store: store) { NSWorkspace.shared.open(url) }
            busy = false
        }
    }
}

/// «Download all» для писем с двумя и больше файлами.
struct DownloadAllButton: View {
    let files: [Attachment]
    let subject: String
    let account: String
    @Environment(MailStore.self) private var store
    @State private var busy = false

    var body: some View {
        Button {
            busy = true
            Task {
                _ = await AttachmentFiles.downloadAll(files, subject: subject, account: account, store: store)
                busy = false
            }
        } label: {
            HStack(spacing: 5) {
                if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.down.circle").font(.system(size: 11.5)) }
                Text("Download all (\(files.count))").font(.g(12.5, .medium))
            }
            .foregroundStyle(Theme.sec)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("Save all attachments to a folder in Downloads")
    }
}
