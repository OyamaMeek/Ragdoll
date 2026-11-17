import Foundation
import SwiftUI
import Testing
@testable import Ragdoll

@Test @MainActor func activityGreensGetLighterInBothThemes() {
    let view = DashboardView(showSessions: {})
    for scheme in [ColorScheme.light, .dark] {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let colors = (1...4).map { view.activityColor($0).resolve(in: environment) }
        #expect(abs(colors[0].red - 33.0 / 255) < 0.001)
        #expect(abs(colors[0].green - 110.0 / 255) < 0.001)
        #expect(abs(colors[0].blue - 57.0 / 255) < 0.001)
        #expect(abs(colors[3].red - 155.0 / 255) < 0.001)
        #expect(abs(colors[3].green - 233.0 / 255) < 0.001)
        #expect(abs(colors[3].blue - 168.0 / 255) < 0.001)
        for (lower, higher) in zip(colors, colors.dropFirst()) {
            #expect(lower.red < higher.red)
            #expect(lower.green < higher.green)
            #expect(lower.blue < higher.blue)
        }
    }
}

@Test @MainActor func activityTooltipUsesLocalDateAndCompactTokens() {
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29))!
    let tooltip = ActivityTooltip(date: date, tokens: 170_000_000)
    #expect(tooltip.dateText == "10月29日")
    #expect(tooltip.tokenText == "1.7亿 个 Token")
    #expect(ActivityTooltip(date: date, tokens: 0).tokenText == "0 个 Token")
}
