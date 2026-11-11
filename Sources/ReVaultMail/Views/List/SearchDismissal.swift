import AppKit
import SwiftUI

/// Observe clicks without consuming them: the same click can close search and open a message.
struct SearchDismissal: NSViewRepresentable {
    var enabled: Bool
    var dismiss: () -> Void

    func makeNSView(context: Context) -> WatchView { WatchView() }
    func updateNSView(_ view: WatchView, context: Context) {
        view.dismiss = dismiss
        view.watch(enabled)
    }
    static func dismantleNSView(_ view: WatchView, coordinator: ()) { view.watch(false) }

    final class WatchView: NSView {
        var dismiss: (() -> Void)?
        private var monitor: Any?
        private var observer: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func watch(_ enabled: Bool) {
            if !enabled {
                if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
                if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                if event.window !== window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.dismiss?()
                }
                return event
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.window else { return }
                self.dismiss?()
            }
        }
    }
}
