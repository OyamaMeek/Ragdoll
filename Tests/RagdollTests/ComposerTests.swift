import Foundation
import RagdollCore
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

@Test func acpComposerUsesGroupedAgentModelsAndFallsBackToLegacyModels() throws {
    let info = try JSONDecoder().decode(JSONValue.self, from: Data("""
    {
        "configOptions": [{
            "configId": "active_provider_model", "category": "model", "type": "select", "currentValue": "provider/b",
            "options": [{"group": "provider", "name": "Provider", "options": [
                {"value": "provider/a", "name": "Model A"}, {"value": "provider/b", "name": "Model B"}
            ]}]
        }],
        "models": {"currentModelId": "legacy", "availableModels": [{"modelId": "legacy", "name": "Legacy"}]}
    }
    """.utf8))
    let catalog = ACPModelOptions(info: info)
    #expect(catalog.configID == "active_provider_model")
    #expect(catalog.current == "provider/b")
    #expect(catalog.choices.map(\.id) == ["provider/a", "provider/b"])
    #expect(catalog.choices.map(\.name) == ["Model A", "Model B"])

    let legacy = ACPModelOptions(info: .object(["models": info["models"]]))
    #expect(legacy.configID == "__legacy_model")
    #expect(legacy.current == "legacy")
    #expect(legacy.choices.map(\.name) == ["Legacy"])
}
