import AppKit
import Foundation
import Testing
@testable import Ragdoll

@Test @MainActor func reopeningMissingDesktopFails() async {
    await #expect(throws: (any Error).self) {
        try await CodexDesktop.reopen(URL(fileURLWithPath: "/missing/desktop.app"))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["RAGDOLL_DESKTOP_LIVE"] == "1"))
@MainActor func desktopReopenWaitsForExitAndReportsRefusedTermination() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent/tests/desktop-\(UUID().uuidString)")
    let app = root.appendingPathComponent("Lifecycle.app")
    let contents = app.appendingPathComponent("Contents")
    let executable = contents.appendingPathComponent("MacOS/Lifecycle")
    let identifier = "com.oyamameek.ragdoll.lifecycle.\(UUID().uuidString)"
    let blocked = contents.appendingPathComponent("refuse-exit")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: blocked)
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).forEach { $0.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
    let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Lifecycle", "CFBundlePackageType": "APPL", "LSUIElement": true]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let source = root.appendingPathComponent("Lifecycle.swift")
    try Data("""
    import AppKit
    final class Delegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/refuse-exit").path) ? .terminateCancel : .terminateNow
        }
    }
    let delegate = Delegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    """.utf8).write(to: source)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    compiler.arguments = [source.path, "-o", executable.path, "-module-cache-path", root.appendingPathComponent("modules").path]
    try compiler.run(); compiler.waitUntilExit()
    #expect(compiler.terminationStatus == 0)
    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["--force", "--sign", "-", app.path]
    try signer.run(); signer.waitUntilExit()
    #expect(signer.terminationStatus == 0)

    try await CodexDesktop.reopen(app)
    let first = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first)
    try await CodexDesktop.reopen(app)
    let second = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first)
    #expect(first.isTerminated)
    #expect(first.processIdentifier != second.processIdentifier)
    try Data().write(to: blocked)
    await #expect(throws: (any Error).self) { try await CodexDesktop.reopen(app) }
    #expect(!second.isTerminated)
    #expect(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count == 1)
}
