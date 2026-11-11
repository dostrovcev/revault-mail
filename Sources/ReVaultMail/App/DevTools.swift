import AppKit
import Foundation

/// Отладка без Gmail и без записи экрана:
/// RVM_DEMO=1 показывает демо-письма, RVM_SNAPSHOT=/path.png сохраняет снимок окна и выходит.
enum DevTools {
    static var isSnapshot: Bool { ProcessInfo.processInfo.environment["RVM_SNAPSHOT"] != nil }
    static var isDemo: Bool { ProcessInfo.processInfo.environment["RVM_DEMO"] != nil }
    /// Можно ли писать файлы пользователя (чаты, переводы, кэши, правила важного).
    /// В демо нельзя: демо-чаты не должны попасть в настоящую историю владельца.
    static var writesAllowed: Bool { !isDemo }

    @MainActor
    static func scheduleSnapshot() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RVM_SNAPSHOT"] else { return }
        let delay = Double(env["RVM_SNAPSHOT_DELAY"] ?? "3") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView else { exit(2) }
            if let size = env["RVM_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                view.layoutSubtreeIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let scale = window.backingScaleFactor
                let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
                guard let layer = view.layer,
                      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { exit(3) }
                ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                if let img = ctx.makeImage() {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
    }

    static func demo() -> (accounts: [Account], threads: [ThreadSummary], details: [ThreadKey: ThreadDetail], labels: [String: [MailLabel]]) {
        let me = "alex@example.com"
        let me2 = "alex.personal@example.org"
        let now = Date()
        func p(_ n: String, _ e: String) -> Person { Person(name: n, email: e) }
        let sam = p("Sam Example", "sam@example.net")
        let anna = p("Taylor Example", "taylor@example.org")
        let stripe = p("Stripe", "receipts@example.com")
        let chris = p("Jordan Example", "jordan@example.net")

        func msg(_ id: String, _ t: String, _ from: Person, _ to: [Person], _ text: String, _ ago: Double, unread: Bool = false, html: String? = nil) -> MailMessage {
            MailMessage(id: id, threadID: t, from: from, to: to, cc: [], replyTo: [], subject: "", date: now.addingTimeInterval(-ago),
                        messageIDHeader: "<\(id)@demo>", references: "", snippet: String(text.prefix(90)), plain: html == nil ? text : nil,
                        html: html, attachments: [], labelIDs: unread ? ["INBOX", "UNREAD"] : ["INBOX"])
        }
        let t1 = [
            msg("a1", "t1", sam, [p("Alex", me)], "Hi Alex,\n\nSaw your note about the agent-run outreach. We are rolling up three agencies in Q1 and need pipeline for all of them.\n\nCan you share what a pilot looks like?", 7200 * 5),
            msg("a2", "t1", p("Alex", me), [sam], "Sam, sure. The pilot is one segment, one signal, two weeks. We start with your best customer list and build from there.\n\nWhat is the deal size for each agency?", 7200 * 4),
            msg("a3", "t1", sam, [p("Alex", me)], "Around $40k ACV. I recorded a short video on how the roll-up works, link inside. Book any slot here: example.com/booking", 1800, unread: true),
        ]
        let t2 = [msg("b1", "t2", anna, [p("Alex", me)], "Hallo Alex,\n\nkönnen wir den Start der Kampagne auf Montag verschieben? Unser Vertriebsteam ist diese Woche auf einer Messe.\n\nViele Grüße\nAnna", 3600 * 3, unread: true)]
        let t3 = [msg("c1", "t3", stripe, [p("", me2)], "", 3600 * 20,
                      html: "<div style='font-family:sans-serif'><h2 style='color:#635bff'>Receipt from Re:Vault</h2><p>Amount paid: <b>$2,000.00</b></p><p>Thanks for your business.</p></div>")]
        let t4 = [msg("d1", "t4", chris, [p("Alex", me)], "Alex, quick one: can we add two more SDR profiles next month? Same targeting.", 86400 * 2)]

        var details: [ThreadKey: ThreadDetail] = [:]
        var threads: [ThreadSummary] = []
        for (acc, subj, ms) in [(me, "Pilot for the roll-up", t1), (me, "Kampagnenstart verschieben", t2), (me2, "Your receipt from Re:Vault", t3), (me, "Two more SDR profiles", t4)] {
            var fixed = ms
            for i in fixed.indices { fixed[i].subject = subj }
            let d = ThreadDetail(account: acc, id: fixed[0].threadID, subject: subj, messages: fixed, labelIDs: ["INBOX"])
            details[d.key] = d
            let others = fixed.map(\.from)
            threads.append(ThreadSummary(account: acc, id: d.id, subject: subj, snippet: fixed.last!.snippet,
                                         participants: others.reduce(into: [Person]()) { r, p in if !r.contains(p) { r.append(p) } },
                                         lastFrom: fixed.last!.from, date: fixed.last!.date, messageCount: fixed.count,
                                         unread: fixed.contains(where: \.unread), starred: false, hasAttachments: false, labelIDs: ["INBOX"],
                                         bulk: acc == me2, toMe: true, lastIncoming: fixed.last { !$0.from.email.hasSuffix("example.com") }?.from))
        }
        threads.sort { $0.date > $1.date }
        let labels = [me: [MailLabel(id: "INBOX", name: "INBOX", type: "system", unread: 2, total: 267), MailLabel(id: "Label_1", name: "Clients", type: "user", color: "#16a766"), MailLabel(id: "Label_2", name: "Investors", type: "user", color: "#a479e2")],
                      me2: [MailLabel(id: "INBOX", name: "INBOX", type: "system", unread: 66, total: 106)]]
        return ([Account(email: me, displayName: "Alex"), Account(email: me2, displayName: "Alex")], threads, details, labels)
    }
}
