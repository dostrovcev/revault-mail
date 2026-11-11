import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(InterfaceMetrics.scaleKey) private var scale = 1.0
    var body: some View {
        TabView {
            AccountsSettings().tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            AgentSettings().tabItem { Label("Agent", systemImage: "sparkles") }
            ReadingSettings().tabItem { Label("Reading", systemImage: "text.bubble") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .modifier(InterfaceScale())
        .frame(width: 600 * InterfaceMetrics.clamp(scale), height: 480 * InterfaceMetrics.clamp(scale))
    }
}

/// Версия сборки: видно, есть ли в ней нужная правка.
enum AppVersion {
    static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local" }
    static var line: String { "Version \(short) (build \(build))" }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Logo(size: 28, suffix: "Mail")
            Link("Built by Dmitry Ostrovtsev", destination: URL(string: "https://www.linkedin.com/in/dostrovcev/")!)
            Link("Re:Vault · AI for your business", destination: URL(string: "https://re-vault.io/?utm_source=revault-mail&utm_medium=app&utm_campaign=open-source")!)
            Link("Source code · MIT", destination: URL(string: "https://github.com/dostrovcev/revault-mail")!)
            Text(AppVersion.line).font(.g(13)).foregroundStyle(Theme.muted).textSelection(.enabled)
            Text("Gmail and your own AI, in one open source app.")
                .font(.g(12.5)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Строки «Sign in again» для ящиков, у которых истёк вход.
struct ExpiredAccountsRows: View {
    @Environment(MailStore.self) private var store
    let onSignIn: (String) -> Void
    var body: some View {
        ForEach(store.accounts.filter { store.expiredAccounts.contains($0.email) }) { acc in
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent)
                Text("Sign-in expired: \(acc.email)").font(.g(12.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                Spacer(minLength: 6)
                Button("Sign in again") { onSignIn(acc.email) }.buttonStyle(.dash(.normal, small: true))
            }
        }
    }
}

/// Импорт OAuth-клиента Google: файлом или вставкой двух полей.
struct GoogleClientSetup: View {
    @Environment(MailStore.self) private var store
    @State private var clientID = GoogleClientConfig.load()?.clientID ?? ""
    @State private var secret = GoogleClientConfig.load()?.clientSecret ?? ""
    @State private var saved = GoogleClientConfig.load() != nil
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Import client_secret.json") { importFile() }.buttonStyle(.dashPrimary)
                Button("Open Google Cloud Console") {
                    NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                }.buttonStyle(.dash)
                if saved { Label("Client saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.g(12)) }
            }
            TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
            SecureField("Client secret", text: $secret).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") { save(GoogleClientConfig(clientID: clientID.trimmingCharacters(in: .whitespaces), clientSecret: secret.trimmingCharacters(in: .whitespaces))) }
                    .buttonStyle(.dash)
                    .disabled(clientID.isEmpty || secret.isEmpty)
                if let message { Text(message).font(.g(12)).foregroundStyle(Theme.muted) }
            }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard let cfg = GoogleClientConfig.parse(downloaded: data) else {
            message = GoogleClientConfig.isWebClient(data)
                ? "This is a Web client key. A Desktop app key is needed."
                : "The file has no client_id and client_secret."
            return
        }
        clientID = cfg.clientID
        secret = cfg.clientSecret
        save(cfg)
    }

    private func save(_ cfg: GoogleClientConfig) {
        cfg.save()
        saved = true
        message = "Done. Now add a Gmail account."
    }
}

struct AccountsSettings: View {
    @Environment(MailStore.self) private var store
    @State private var signIn: Task<Void, Never>?
    @State private var signInID = UUID()

    var body: some View {
        Form {
            Section("Google OAuth client") { GoogleClientSetup() }
            Section("Gmail accounts") {
                ForEach(store.accounts) { acc in
                    HStack {
                        Circle().fill(Color.avatar(for: acc.email)).frame(width: 8, height: 8)
                        Text(acc.email)
                        TextField("Name in the From field", text: Binding(get: { acc.displayName }, set: { store.setDisplayName($0, for: acc.email) }))
                            .textFieldStyle(.roundedBorder).frame(width: 180)
                        Spacer()
                        // у каждого ящика: новый вход добавляет права, которых не было (календарь с 0.12.10)
                        Button("Sign in again") { start { await store.relogin(acc.email) } }
                            .disabled(signIn != nil)
                        Button("Remove", role: .destructive) { store.removeAccount(acc.email) }
                    }
                }
                HStack {
                    Button { start { await store.addAccount() } } label: { Label("Add Gmail", systemImage: "plus") }
                        .disabled(!store.hasGoogleClient || signIn != nil)
                    if signIn != nil {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser").font(.g(12))
                        Button("Cancel") { signIn?.cancel(); signIn = nil }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func start(_ work: @escaping @MainActor () async -> Void) {
        signIn?.cancel()
        let id = UUID()
        signInID = id
        signIn = Task { @MainActor in
            await work()
            if signInID == id { signIn = nil }
        }
    }
}

struct AgentSettings: View {
    @Environment(AppSettings.self) private var settings
    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Bring your own AI") {
                Picker("Provider", selection: $s.agentProvider) {
                    ForEach(LocalAgentCLI.Backend.allCases) { Text($0.title).tag($0.rawValue) }
                }.onChange(of: s.agentProvider) { _, _ in s.agentModel = "" }
                if s.agentProvider == "codex" {
                    TextField("Codex executable", text: $s.codexPath)
                } else {
                    TextField("Claude executable", text: $s.claudePath)
                }
                TextField("Model (blank uses the provider default)", text: $s.agentModel)
                Text("Sign in once in Terminal with claude or codex login. Then ask about an email, draft a reply, or translate a thread.")
                Text("The app is free. Your AI account's plan and usage limits apply. Selected email content is sent to your chosen provider when you ask the assistant or use translation.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct ReadingSettings: View {
    @AppStorage(InterfaceMetrics.scaleKey) private var scale = 1.0
    @Environment(AppSettings.self) private var settings
    @AppStorage("useGeist") private var useGeist = false
    @AppStorage("theme") private var theme = Theme.Kind.vault.rawValue
    var body: some View {
        @Bindable var s = settings
        Form {
            Picker("Theme", selection: $theme) {
                ForEach(Theme.Kind.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Picker("Interface size", selection: $scale) {
                ForEach(InterfaceMetrics.scales, id: \.self) { value in Text("\(Int(value * 100))%").tag(value) }
            }
            Text("View → Interface Size · ⌘+ / ⌘− · ⌘0 resets to 100%")
                .font(.g(12)).foregroundStyle(Theme.muted)
            Picker("Translate into", selection: $s.translateTarget) { ForEach(AppSettings.languages, id: \.self) { Text($0).tag($0) } }
            Toggle("Geist font", isOn: Binding(get: { theme == Theme.Kind.vault.rawValue || useGeist }, set: { useGeist = $0 }))
                .disabled(theme == Theme.Kind.vault.rawValue)
                .help("Re:Vault uses Geist from the cabinet design system. This switch controls the Light theme.")
        }
        .formStyle(.grouped)
    }
}

struct WelcomeView: View {
    @Environment(MailStore.self) private var store
    @State private var adding = false
    @State private var signIn: Task<Void, Never>?
    @State private var showSetup = false
    @State private var notice: String?
    @State private var watching = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 22) {
                Logo(size: 34, suffix: "Mail")
                Text("Gmail, translation and the Revolt agent for every email")
                    .font(.g(15)).foregroundStyle(Theme.muted)

                VStack(spacing: 14) {
                    GoogleSignInButton(busy: adding) { startSignIn() }
                        .disabled(adding)
                    if adding {
                        Button("Cancel") { cancelSignIn() }.buttonStyle(.dash(.ghost, small: true))
                    }
                    ExpiredAccountsRows { email in
                        run { await store.relogin(email) }
                    }
                    if let notice {
                        Text(notice).font(.g(12.5)).foregroundStyle(Theme.accentText).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if adding {
                        Text("Finish signing in in your browser: choose the account and allow access to mail.")
                            .font(.g(12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    } else {
                        Text("You can connect several inboxes: after the first sign-in, click your card at the bottom left and choose Add Google account.")
                            .font(.g(12.5)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                    }
                }
                .frame(width: 380)
                .padding(28)
                .dashCard(padding: 0)

                if showSetup || !store.hasGoogleClient {
                    setupCard
                } else {
                    Button("Use your own Google OAuth client") { showSetup = true }
                        .buttonStyle(.dash(.ghost, small: true))
                }
            }
            .frame(width: 620)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
    }

    private func setupStep(_ n: Int, _ text: String, _ url: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.g(12, .semibold)).foregroundStyle(Theme.white)
                .frame(width: 20, height: 20).background(Circle().fill(Theme.ink))
            Text(text).font(.g(13)).foregroundStyle(Theme.ink2)
            Spacer(minLength: 8)
            Button("Open") { NSWorkspace.shared.open(URL(string: url)!); watchDownloads() }.buttonStyle(.dash(.normal, small: true))
        }
    }

    private func startSignIn() {
        guard store.hasGoogleClient else {
            showSetup = true
            notice = "A Google sign-in key is needed, once. Follow the steps below: the app picks up the downloaded file from Downloads and continues the sign-in."
            NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!)
            watchDownloads()
            return
        }
        notice = nil
        run { await store.addAccount() }
    }

    /// Вход в браузере с кнопкой Cancel: задача хранится, чтобы её можно было снять.
    private func run(_ work: @escaping @MainActor () async -> Void) {
        signIn?.cancel()
        adding = true
        let t = Task { @MainActor in
            await work()
            if !Task.isCancelled { adding = false; signIn = nil }
        }
        signIn = t
    }

    private func cancelSignIn() {
        signIn?.cancel()
        signIn = nil
        adding = false
        notice = "Sign-in cancelled."
    }

    /// Ждёт client_secret_*.json в Загрузках, импортирует и сразу запускает вход.
    private func watchDownloads() {
        guard !watching, !DevTools.isSnapshot else { return }
        watching = true
        Task {
            let started = Date()
            while !store.hasGoogleClient {
                if let cfg = Self.findDownloadedClient(newerThan: started) {
                    cfg.save()
                    notice = nil
                    run { await store.addAccount() }
                    break
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            watching = false
        }
    }

    static func findDownloadedClient(newerThan date: Date) -> GoogleClientConfig? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let candidates = files.filter { f in
            guard f.lastPathComponent.hasPrefix("client_secret"), f.pathExtension == "json" else { return false }
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return m > date
        }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for f in candidates {
            if let data = try? Data(contentsOf: f), let cfg = GoogleClientConfig.parse(downloaded: data) { return cfg }
        }
        return nil
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.hasGoogleClient ? "Your own OAuth client" : "Once: Google sign-in key").font(.g(15, .semibold))
            if !store.hasGoogleClient {
                Text("This build has no sign-in key yet. Create it once, then sign-in is one button.")
                    .font(.g(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                setupStep(1, "Enable the Gmail API (if asked, create a project with any name)",
                          "https://console.cloud.google.com/apis/library/gmail.googleapis.com")
                setupStep(2, "Consent screen: Get started, type External, your email, then Publish app",
                          "https://console.cloud.google.com/auth/overview")
                setupStep(3, "Create client: type Desktop app, Create, then Download JSON",
                          "https://console.cloud.google.com/auth/clients/create")
                HStack(spacing: 6) {
                    if watching { ProgressView().controlSize(.mini) }
                    Text(watching ? "Waiting for the client_secret file in Downloads..." : "The downloaded file is picked up from Downloads automatically.")
                        .font(.g(12.5)).foregroundStyle(Theme.muted)
                }
                .padding(.top, 2)
            }
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Enter the key manually") {
                    GoogleClientSetup().padding(.top, 6)
            }
            .font(.g(12.5))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashCard(padding: 0)
    }
}

/// Кнопка в стиле Google: белая, рамка, цветная «G».
struct GoogleSignInButton: View {
    var title = "Sign in with Google"
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if busy { ProgressView().controlSize(.small) } else { GoogleG().frame(width: 18, height: 18) }
                Text(title).font(.g(14.5, .medium)).foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.hover : Theme.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? Theme.borderHover : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Логотип «G» из четырёх дуг фирменных цветов Google.
struct GoogleG: View {
    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height)
            let lw = w * 0.2
            ZStack {
                arc(from: -40, to: 45, Color(hex: 0x4285F4), lw)
                arc(from: 45, to: 135, Color(hex: 0x34A853), lw)
                arc(from: 135, to: 205, Color(hex: 0xFBBC05), lw)
                arc(from: 205, to: 320, Color(hex: 0xEA4335), lw)
                Rectangle().fill(Color(hex: 0x4285F4))
                    .frame(width: w * 0.46, height: lw)
                    .offset(x: w * 0.2)
            }
            .frame(width: w, height: w)
        }
    }

    private func arc(from: Double, to: Double, _ c: Color, _ lw: CGFloat) -> some View {
        Circle()
            .trim(from: (from + 360).truncatingRemainder(dividingBy: 360) / 360, to: to < from ? 1 : (to.truncatingRemainder(dividingBy: 360)) / 360)
            .stroke(c, style: StrokeStyle(lineWidth: lw))
            .padding(lw / 2)
            .rotationEffect(.degrees(0))
    }
}
