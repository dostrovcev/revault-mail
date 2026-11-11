import AppKit
import CoreText
import SwiftUI

/// Палитра и шрифт кабинета Re:Vault (/app, «Revault Redesign», site/console/v2.css).
enum Theme {
    /// Light preserves the previous blue theme; Re:Vault follows the cabinet design system.
    enum Kind: String, CaseIterable, Identifiable {
        case missive, vault
        var id: String { rawValue }
        var title: String { self == .missive ? "Light" : "Re:Vault" }
    }

    struct Palette {
        var ink, ink2, sec, muted, faint, ghost, icon: Color
        var line, lineSoft, border, borderHover, page, chip, hover, navHover, navOn: Color
        var accent, accentText, accentBg, green, greenBg, white: Color
        var blue, blueSoft, blueText, bubble: Color
        /// Выбранная строка списка и отметка непрочитанного.
        var select, dot: Color
        /// Пузырь Револта в треде.
        var agentBg: Color
        /// Фон непрочитанной строки и он же под курсором.
        var unreadBg, unreadHover: Color
        /// Боковая панель: фон, текст, вторичный текст, карточки, выбор, счётчики.
        var side, sideInk, sideMuted, sideFaint, sideIcon, sideCard, sideBorder, sideNavOn, sideNavHover: Color
        var sideCountBg, sideCountText, sideUnreadBg, sideUnreadText: Color
        /// Полоска слева у выбранной папки (Vault), прозрачная у Missive.
        var sideMark: Color
        var sideIsDark: Bool
    }

    static let missive = Palette(
        ink: Color(hex: 0x1D2125), ink2: Color(hex: 0x3A3F45), sec: Color(hex: 0x4B5158), muted: Color(hex: 0x6E747B),
        faint: Color(hex: 0x8D9399), ghost: Color(hex: 0xB8BCC2), icon: Color(hex: 0x7A8088),
        line: Color(hex: 0xE6E7EB), lineSoft: Color(hex: 0xF0F1F4), border: Color(hex: 0xE2E4E8), borderHover: Color(hex: 0xC9CDD3),
        page: Color(hex: 0xF5F6F8), chip: Color(hex: 0xEDEEF1), hover: Color(hex: 0xF4F5F8),
        navHover: Color(hex: 0xE9EAEF), navOn: Color(hex: 0xE3E4EA),
        accent: Color(hex: 0xEE5B32), accentText: Color(hex: 0xC2471F), accentBg: Color(hex: 0xFDEEE8),
        green: Color(hex: 0x2E7A55), greenBg: Color(hex: 0xE8F2EC), white: .white,
        blue: Color(hex: 0x4C5BE0), blueSoft: Color(hex: 0xE2E7FD), blueText: Color(hex: 0x3646C9), bubble: Color(hex: 0xE3EAFC),
        select: Color(hex: 0x4C5BE0), dot: Color(hex: 0x4C5BE0), agentBg: Color(hex: 0xFDEEE8),
        unreadBg: Color(hex: 0xE9EAEC), unreadHover: Color(hex: 0xDFE1E4),
        side: Color(hex: 0xF3F3F6), sideInk: Color(hex: 0x1D2125), sideMuted: Color(hex: 0x6E747B), sideFaint: Color(hex: 0x8D9399),
        sideIcon: Color(hex: 0x3A3F45), sideCard: .white, sideBorder: Color(hex: 0xE2E4E8),
        sideNavOn: Color(hex: 0xE3E4EA), sideNavHover: Color(hex: 0xE9EAEF),
        sideCountBg: Color(hex: 0xEDEEF1), sideCountText: Color(hex: 0x6E747B),
        sideUnreadBg: Color(hex: 0xE2E7FD), sideUnreadText: Color(hex: 0x3646C9),
        sideMark: .clear, sideIsDark: false)

    // Cabinet specimen, 04 November 2026: https://re-vault.io/preview-design-system/
    // Semantic aliases intentionally share the specimen's 20 colors.
    static let vault = Palette(
        ink: Color(hex: 0x14282B), ink2: Color(hex: 0x14282B), sec: Color(hex: 0x4A5759), muted: Color(hex: 0x667272),
        faint: Color(hex: 0x667272), ghost: Color(hex: 0xB4BABA), icon: Color(hex: 0x667272),
        line: Color(hex: 0xE9EAE7), lineSoft: Color(hex: 0xF1F1EF), border: Color(hex: 0xD6D9D6), borderHover: Color(hex: 0x667272),
        page: Color(hex: 0xFAFAF8), chip: Color(hex: 0xF0F0ED), hover: Color(hex: 0xF4F4F1),
        navHover: Color(hex: 0xF0F0ED), navOn: Color(hex: 0xE9EAE7),
        accent: Color(hex: 0xEE5B32), accentText: Color(hex: 0xBB431C), accentBg: Color(hex: 0xFDEEE8),
        green: Color(hex: 0x2E7A55), greenBg: Color(hex: 0xE8F2EC), white: .white,
        blue: Color(hex: 0x14282B), blueSoft: Color(hex: 0xF0F0ED), blueText: Color(hex: 0x14282B), bubble: Color(hex: 0xF0F0ED),
        select: Color(hex: 0x14282B), dot: Color(hex: 0xEE5B32), agentBg: Color(hex: 0xFDEEE8),
        unreadBg: Color(hex: 0xE9EAE7), unreadHover: Color(hex: 0xDFE1DE),
        side: Color(hex: 0xF4F4F1), sideInk: Color(hex: 0x14282B), sideMuted: Color(hex: 0x4A5759), sideFaint: Color(hex: 0x667272),
        sideIcon: Color(hex: 0x4A5759), sideCard: .white, sideBorder: Color(hex: 0xE9EAE7),
        sideNavOn: Color(hex: 0xE9EAE7), sideNavHover: Color(hex: 0xF0F0ED),
        sideCountBg: Color(hex: 0xF0F0ED), sideCountText: Color(hex: 0x667272),
        sideUnreadBg: Color(hex: 0x14282B), sideUnreadText: .white,
        sideMark: Color(hex: 0xEE5B32), sideIsDark: false)

    static let red = Color(hex: 0xB3261E)
    static let redBg = Color(hex: 0xFBEBE9)
    static func motion(_ reduced: Bool) -> Animation? {
        reduced ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    }

    static var kind: Kind = Kind(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .vault {
        didSet { p = kind == .vault ? vault : missive }
    }
    static private(set) var p: Palette = (Kind(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .vault) == .vault ? vault : missive

    static var ink: Color { p.ink }
    static var ink2: Color { p.ink2 }
    static var sec: Color { p.sec }
    static var muted: Color { p.muted }
    static var faint: Color { p.faint }
    static var ghost: Color { p.ghost }
    static var icon: Color { p.icon }
    static var line: Color { p.line }
    static var lineSoft: Color { p.lineSoft }
    static var border: Color { p.border }
    static var borderHover: Color { p.borderHover }
    static var page: Color { p.page }
    static var side: Color { p.side }
    static var chip: Color { p.chip }
    static var hover: Color { p.hover }
    static var navHover: Color { p.navHover }
    static var navOn: Color { p.navOn }
    static var accent: Color { p.accent }
    static var accentText: Color { p.accentText }
    static var accentBg: Color { p.accentBg }
    static var green: Color { p.green }
    static var greenBg: Color { p.greenBg }
    static var white: Color { p.white }
    static var blue: Color { p.blue }
    static var blueSoft: Color { p.blueSoft }
    static var blueText: Color { p.blueText }
    static var bubble: Color { p.bubble }
    static var select: Color { p.select }
    static var dot: Color { p.dot }
    static var agentBg: Color { p.agentBg }
    static var unreadBg: Color { p.unreadBg }
    static var unreadHover: Color { p.unreadHover }
    static var sideInk: Color { p.sideInk }
    static var sideMuted: Color { p.sideMuted }
    static var sideFaint: Color { p.sideFaint }
    static var sideIcon: Color { p.sideIcon }
    static var sideCard: Color { p.sideCard }
    static var sideBorder: Color { p.sideBorder }
    static var sideNavOn: Color { p.sideNavOn }
    static var sideNavHover: Color { p.sideNavHover }
    static var sideCountBg: Color { p.sideCountBg }
    static var sideCountText: Color { p.sideCountText }
    static var sideUnreadBg: Color { p.sideUnreadBg }
    static var sideUnreadText: Color { p.sideUnreadText }
    static var sideMark: Color { p.sideMark }

    /// Подключает Geist из ресурсов приложения (или из папки проекта при отладке).
    static func registerFonts() {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Fonts")) }
        dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Resources/Fonts").standardized)
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "ttf" {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
            if !files.isEmpty { return }
        }
    }
}

extension Font {
    /// Geist нужного начертания; без шрифта система подставит системный.
    /// Системный шрифт Mac (как в Missive); Geist включается в настройках.
    static func g(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if Theme.kind != .vault && !UserDefaults.standard.bool(forKey: "useGeist") { return .system(size: size, weight: weight) }
        let size: CGFloat = Theme.kind == .vault && size >= 12 ? ([12, 13, 14, 16, 20, 28, 40].min(by: { abs(CGFloat($0) - size) < abs(CGFloat($1) - size) }).map(CGFloat.init) ?? size) : size
        let name: String
        switch weight {
        case .medium: name = "Geist-Medium"
        case .semibold: name = "Geist-SemiBold"
        case .bold, .heavy, .black: name = "Geist-Bold"
        default: name = "Geist-Regular"
        }
        return .custom(name, size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Кнопки кабинета: обычная белая с рамкой, основная чернильная, призрачная.
struct DashButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, ghost, accent }
    var kind: Kind = .normal
    var small = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = kind == .primary || kind == .accent ? .white : (kind == .ghost ? Theme.sec : Theme.ink)
        let bg: Color = {
            switch kind {
            case .primary: return hover ? Theme.sec : Theme.ink
            case .accent: return Theme.accentText
            case .ghost: return hover ? Theme.chip : .clear
            case .normal: return Theme.white
            }
        }()
        let stroke: Color = {
            switch kind {
            case .primary: return Theme.ink
            case .accent: return Theme.accentText
            case .ghost: return .clear
            case .normal: return hover ? Theme.borderHover : Theme.border
            }
        }()
        return configuration.label
            .labelStyle(DashLabelStyle())
            .fixedSize()
            .font(.g(small ? 12.5 : 13, .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, small ? 12 : 16)
            .frame(height: small ? 28 : 36)
            .background(RoundedRectangle(cornerRadius: small ? 6 : 10).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: small ? 6 : 10).stroke(stroke, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
            .animation(Theme.motion(reduceMotion), value: configuration.isPressed)
            .animation(Theme.motion(reduceMotion), value: hover)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == DashButtonStyle {
    static var dash: DashButtonStyle { DashButtonStyle() }
    static var dashPrimary: DashButtonStyle { DashButtonStyle(kind: .primary) }
    static var dashGhost: DashButtonStyle { DashButtonStyle(kind: .ghost) }
    static func dash(_ kind: DashButtonStyle.Kind, small: Bool = false) -> DashButtonStyle { DashButtonStyle(kind: kind, small: small) }
}

/// Карточка кабинета: белая, рамка, радиус 12.
struct DashCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.white))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }
}

extension View {
    func dashCard(padding: CGFloat = 16) -> some View { modifier(DashCard(padding: padding)) }
}

/// Логотип как в кабинете: двоеточие акцентным цветом.
struct Logo: View {
    var size: CGFloat = 17
    var suffix: String? = nil
    var color: Color = Theme.ink
    var body: some View {
        (Text("Re").foregroundColor(color) + Text(":").foregroundColor(Theme.accent) + Text("Vault").foregroundColor(color)
            + Text(suffix.map { " " + $0 } ?? "").foregroundColor(Theme.muted))
            .font(.g(size, .semibold))
            .kerning(-0.3)
    }
}

/// Иконка и подпись рядом, иконка чуть мельче, как в кнопках кабинета.
struct DashLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11.5, weight: .medium))
            configuration.title
        }
    }
}
