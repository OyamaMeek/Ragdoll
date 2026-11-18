import Foundation
import Testing
@testable import Ragdoll

@Test @MainActor func composerKeepsModelSelectionPerSessionAndResetsEffortWhenModelChanges() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".agent/tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(root: root)

    model.composerSelections["first", default: .init()].model = "first-model"
    model.composerSelections["first", default: .init()].effort = "high"
    model.composerSelections["second", default: .init()].model = "second-model"

    #expect(model.composerSelections["first"]?.model == "first-model")
    #expect(model.composerSelections["first"]?.effort == "high")
    #expect(model.composerSelections["second"]?.effort == "")

    model.composerSelections["first", default: .init()].model = "second-model"
    #expect(model.composerSelections["first"]?.effort == "")
}
