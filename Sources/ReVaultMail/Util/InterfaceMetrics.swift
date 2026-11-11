import Foundation

enum InterfaceMetrics {
    static let scaleKey = "interfaceScale"
    static let scales: [Double] = [0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4]
    static func clamp(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return min(1.4, max(0.8, (scale * 10).rounded() / 10))
    }

    struct Layout {
        var sidebar: Double; var list: Double; var agent: Double
        var spare: Double; var squeezed: Bool; var detail: Double
    }

    static func layout(total: Double, showSidebar: Bool, side: Double, list: Double, showAgent: Bool, agent: Double) -> Layout {
        let fixed = 45.0, detailMin = 380.0
        var s = showSidebar ? min(max(side, 190), 380) : 0
        var l = min(max(list, 280), 720)
        var a = showAgent ? min(max(agent, 280), 760) : 0
        func handles() -> Double { 7 + (s > 0 ? 7 : 0) + (a > 0 ? 7 : 0) }
        func over() -> Double { fixed + handles() + s + l + a + detailMin - total }
        if over() > 0, a > 0 { a = max(280, a - over()) }
        if over() > 0 { l = max(280, l - over()) }
        if over() > 0, s > 0 { s = max(190, s - over()) }
        // At large UI scales, let the optional agent panel give the reader room.
        if over() > 0, a > 0 { a = 0 }
        if over() > 0, s > 0 { s = 0 }
        let detail = max(300, total - fixed - handles() - s - l - a)
        return Layout(sidebar: s, list: l, agent: a, spare: max(0, -over()), squeezed: showSidebar && s == 0, detail: detail)
    }
}
