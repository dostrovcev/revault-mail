import SwiftUI

/// Полоса над списком, когда выделено два треда и больше: те же действия, что E, #, U, S, плюс метки и отложение.
struct BulkActionBar: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        let keys = store.orderedSelection
        let anyUnread = keys.contains { store.summary($0)?.unread == true }
        let allStarred = keys.allSatisfy { store.summary($0)?.starred == true }
        let box = store.mailbox.labelID
        HStack(spacing: 2) {
            Button { store.clearSelection() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain).help("Clear selection (Esc)")
            Text("\(keys.count) selected").font(.g(13, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                .fixedSize()
            Spacer(minLength: 6)
            if box == "SPAM" {
                BarButton("tray.and.arrow.down", "Not spam") { store.notSpam(keys) }
            } else {
                BarButton("archivebox", "Archive (E)") { store.archive(keys) }
            }
            BarButton("trash", "Move to trash (#)") { store.trash(keys) }
            BarButton(anyUnread ? "envelope.open" : "envelope.badge", anyUnread ? "Mark as read (U)" : "Mark as unread (U)") {
                store.setUnread(keys, !anyUnread)
            }
            BarButton(allStarred ? "star.slash" : "star", allStarred ? "Remove star (S)" : "Star (S)") { store.toggleStar(keys) }
            BarButton("tag", "Labels (L)") { store.listPopover = ListPopover(kind: .labels, keys: keys) }
            BarButton("folder", "Move to (V)") { store.listPopover = ListPopover(kind: .move, keys: keys) }
            BarButton("clock", "Snooze (H)") { store.listPopover = ListPopover(kind: .snooze, keys: keys) }
            if box != "SPAM" {
                BarButton("exclamationmark.octagon", "Spam (!)") { store.markSpam(keys) }
            }
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(Theme.blueSoft.opacity(0.55))
        .overlay(alignment: .bottom) { HLine() }
    }
}

private struct BarButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    init(_ icon: String, _ help: String, action: @escaping () -> Void) { self.icon = icon; self.help = help; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(hover ? Theme.ink : Theme.ink2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.white : .clear))
        }
        .buttonStyle(.plain).help(help)
        .onHover { hover = $0 }
    }
}

/// Правая часть окна при выделении нескольких тредов: сколько выбрано и крупные кнопки действий.
struct MultiSelectionDetail: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        let keys = store.orderedSelection
        let accounts = Set(keys.map(\.account))
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<min(3, keys.count), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 10).fill(Theme.white)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                        .frame(width: 150, height: 96)
                        .rotationEffect(.degrees(Double(i) * 4 - 4))
                        .offset(y: CGFloat(i) * -4)
                }
                Image(systemName: "tray.full").font(.system(size: 26)).foregroundStyle(Theme.faint)
            }
            .frame(height: 120)
            Text("\(keys.count) conversations selected").font(.g(16, .semibold)).foregroundStyle(Theme.ink)
            if accounts.count > 1 {
                Text("From \(accounts.count) inboxes").font(.g(12.5)).foregroundStyle(Theme.faint)
            }
            HStack(spacing: 8) {
                if store.mailbox.labelID == "SPAM" {
                    Button("Not spam") { store.notSpam(keys) }.buttonStyle(.dash)
                } else {
                    Button("Archive") { store.archive(keys) }.buttonStyle(.dashPrimary)
                }
                Button("Trash") { store.trash(keys) }.buttonStyle(.dash)
                Button("Mark as read") { store.setUnread(keys, false) }.buttonStyle(.dash)
                Button("Snooze") { store.listPopover = ListPopover(kind: .snooze, keys: keys) }.buttonStyle(.dash)
            }
            HStack(spacing: 6) {
                Kbd("E"); Text("archive").foregroundStyle(Theme.faint)
                Kbd("#"); Text("trash").foregroundStyle(Theme.faint)
                Kbd("U"); Text("read").foregroundStyle(Theme.faint)
                Kbd("L"); Text("labels").foregroundStyle(Theme.faint)
                Kbd("Esc"); Text("clear").foregroundStyle(Theme.faint)
            }
            .font(.g(12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.white)
    }
}
