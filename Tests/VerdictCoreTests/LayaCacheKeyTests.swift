import Foundation
import Testing
import VerdictCore

/// Finding 3: the compiled model name is keyed by the weights' sha256, so a replaced checkpoint recompiles.
@Suite struct LayaCacheKeyTests {
    @Test(.enabled(if: LayaCoreMLBackend.availability() == .available)) func compiledNameCarriesWeightsHash() throws {
        let b = try LayaCoreMLBackend()
        let sha = b.manifest.files["model.mlpackage/Data/com.apple.CoreML/weights/weight.bin"]!.sha256
        #expect(b.compiledName == "model-\(sha.prefix(16)).mlmodelc")
        #expect(b.compiledName != "model.mlmodelc")
    }
}
