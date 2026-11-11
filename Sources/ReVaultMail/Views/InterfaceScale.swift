import SwiftUI

/// Scale layout as well as typography, without recreating editors or their drafts.
struct InterfaceScale: ViewModifier {
    @AppStorage(InterfaceMetrics.scaleKey) private var storedScale = 1.0
    func body(content: Content) -> some View {
        let scale = InterfaceMetrics.clamp(storedScale)
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}

struct InterfaceScaleCommands: Commands {
    @AppStorage(InterfaceMetrics.scaleKey) private var scale = 1.0
    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Menu("Interface Size · \(Int(InterfaceMetrics.clamp(scale) * 100))%") {
                Button("Larger Interface") { scale = InterfaceMetrics.clamp(scale + 0.1) }
                    .keyboardShortcut("+", modifiers: .command).disabled(scale >= 1.4)
                // Cmd-= works on keyboards where + needs Shift.
                Button("Larger Interface (⌘=)") { scale = InterfaceMetrics.clamp(scale + 0.1) }
                    .keyboardShortcut("=", modifiers: .command).disabled(scale >= 1.4)
                Button("Smaller Interface") { scale = InterfaceMetrics.clamp(scale - 0.1) }
                    .keyboardShortcut("-", modifiers: .command).disabled(scale <= 0.8)
                Button("Actual Size (100%)") { scale = 1 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Picker("Interface Size", selection: $scale) {
                    ForEach(InterfaceMetrics.scales, id: \.self) { value in
                        Text("\(Int(value * 100))%").tag(value)
                    }
                }
            }
        }
    }
}

/// Sheets have their own presentation surface, so they receive the same scale explicitly.
struct ScaledComposeSheet: View {
    @AppStorage(InterfaceMetrics.scaleKey) private var storedScale = 1.0
    var body: some View {
        let scale = InterfaceMetrics.clamp(storedScale)
        ScrollView { NewMessageView() }
            .modifier(InterfaceScale())
            .frame(width: 640 * scale, height: min(600 * scale, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
    }
}
