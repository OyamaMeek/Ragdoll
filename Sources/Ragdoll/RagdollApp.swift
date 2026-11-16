import SwiftUI
import AppKit
import RagdollCore

@main
struct RagdollApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).frame(minWidth: 1050, minHeight: 720).task { await model.launch() }
        }
        .defaultSize(width: 1380, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入 Claude 导出包…") { model.importDesktop() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("刷新会话") { Task { await model.refresh() } }.keyboardShortcut("r")
                Button("立即归档") { Task { await model.archiveNow() } }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}
