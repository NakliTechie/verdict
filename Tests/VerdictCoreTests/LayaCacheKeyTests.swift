import Foundation
import Testing
@testable import VerdictCore

/// Finding 3: the compiled model name is keyed by the weights' sha256, so a replaced checkpoint recompiles.
@Suite struct LayaCacheKeyTests {
    @Test(.enabled(if: LayaCoreMLBackend.availability() == .available)) func compiledNameCarriesWeightsHash() throws {
        let b = try LayaCoreMLBackend()
        let sha = b.manifest.files["model.mlpackage/Data/com.apple.CoreML/weights/weight.bin"]!.sha256
        #expect(b.compiledName == "model-\(sha.prefix(16)).mlmodelc")
        #expect(b.compiledName != "model.mlmodelc")
    }

    /// Compiled models from older installs (unkeyed) or replaced weights (other hash) go, in both the
    /// package dir and the cache dir; the current one, the package and unrelated entries stay.
    @Test func staleCompiledModelsAreRemoved() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("pkg"), cache = root.appendingPathComponent("cache")
        let keep = "model-4c1dbcd09c84813a.mlmodelc"
        for n in [keep, "model.mlmodelc", "model-0123456789abcdef.mlmodelc", "model.mlpackage", "encoder.mlmodelc"] {
            try Self.fakeCompiled(in: pkg, n)
        }
        try Data("{}".utf8).write(to: pkg.appendingPathComponent("coreml_config.json"))
        for n in [keep, "model-fedcba9876543210.mlmodelc"] { try Self.fakeCompiled(in: cache, n) }

        let removed = LayaCoreMLBackend.removeStaleCompiledModels(
            in: [pkg, cache, root.appendingPathComponent("missing")], keeping: keep)

        #expect(Set(removed.map { "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)" })
            == ["pkg/model.mlmodelc", "pkg/model-0123456789abcdef.mlmodelc", "cache/model-fedcba9876543210.mlmodelc"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: pkg.path))
            == [keep, "model.mlpackage", "encoder.mlmodelc", "coreml_config.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == [keep])
    }

    /// A read-only package dir is not an error: the stale entry stays and nothing throws.
    @Test func readOnlyDirectoryIsSkipped() throws {
        let fm = FileManager.default
        let root = try Self.tempRoot()
        defer { try? fm.removeItem(at: root) }
        let pkg = root.appendingPathComponent("pkg")
        try Self.fakeCompiled(in: pkg, "model.mlmodelc")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pkg.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pkg.path) }

        let removed = LayaCoreMLBackend.removeStaleCompiledModels(in: [pkg], keeping: "model-4c1dbcd09c84813a.mlmodelc")

        #expect(removed.isEmpty)
        #expect(fm.fileExists(atPath: pkg.appendingPathComponent("model.mlmodelc/weights/weight.bin").path))
    }

    static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("verdict-laya-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A directory shaped like a compiled model: `<name>/weights/weight.bin`.
    static func fakeCompiled(in dir: URL, _ name: String) throws {
        let weights = dir.appendingPathComponent(name).appendingPathComponent("weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data(count: 64).write(to: weights.appendingPathComponent("weight.bin"))
    }
}
