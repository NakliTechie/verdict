import CoreML
import CryptoKit
import Foundation

/// Laya typed-decision model (ModernBERT encoder, Convai Innovations, Apache-2.0) via the laya-coreml
/// export, run in-process with Core ML. One forward pass yields a real distribution over the
/// options, so `Sample.distribution` is set and the engine reports `confidenceKind = .decoded`.
public final class LayaCoreMLBackend: DecisionBackend, @unchecked Sendable {
    public let name = "laya-coreml"
    public let producesDistribution = true

    public struct Manifest: Sendable {
        public let source: String
        public let precision: String
        public let maxLength: Int
        public let lengths: [Int]
        public let maxOptions: Int
        public let files: [String: (bytes: Int, sha256: String)]
    }

    public let directory: URL
    public let manifest: Manifest
    public let headMaxLen: Int
    let temperature: [Double]
    let temperatureByOptions: [String: Double]
    let computeUnits: MLComputeUnits
    private let tokenizer: BPETokenizer
    /// MLModel is not Sendable; access is serialised by `lock` (Core ML also rejects concurrent
    /// predictions on one instance).
    private let lock = NSLock()
    nonisolated(unsafe) private var loadedModel: MLModel?

    public static let defaultDirectory: URL = {
        if let env = ProcessInfo.processInfo.environment["VERDICT_LAYA_MODEL"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/verdict/models/laya-typed-decisions-coreml")
    }()
    public static let hubRepo = "aac6fef/laya-typed-decisions-coreml"

    /// `VERDICT_LAYA_COMPUTE` = all | cpu | gpu | ane. Default: cpu — on macOS 26.5 every op of this export
    /// lands on the CPU under every setting (see `opPlacement()`), and `.cpuOnly` loads fastest and quietest.
    public static var defaultComputeUnits: MLComputeUnits {
        switch ProcessInfo.processInfo.environment["VERDICT_LAYA_COMPUTE"]?.lowercased() {
        case "all": .all
        case "gpu": .cpuAndGPU
        case "ane", "ne": .cpuAndNeuralEngine
        default: .cpuOnly
        }
    }

    public static func downloadRemedy(for directory: URL) -> String {
        "hf download \(hubRepo) --local-dir \"\(directory.path)\"  (Apache-2.0, 843 MB; verify with `verdict status --verify`)"
    }

    /// Reads the manifests and tokenizer; the Core ML model itself loads lazily on the first sample.
    public init(directory: URL = LayaCoreMLBackend.defaultDirectory, computeUnits: MLComputeUnits = LayaCoreMLBackend.defaultComputeUnits) throws {
        self.directory = directory
        self.computeUnits = computeUnits
        let cfg = try Self.json(directory.appendingPathComponent("coreml_config.json"))
        guard cfg["format"] as? String == "laya-coreml", (cfg["format_version"] as? NSNumber)?.intValue == 1,
              let shape = cfg["shape"] as? [String: Any] else {
            throw BackendError(code: .modelUnavailable, message: "\(directory.path)/coreml_config.json is not a laya-coreml v1 export.")
        }
        var files: [String: (Int, String)] = [:]
        for (k, v) in cfg["files"] as? [String: [String: Any]] ?? [:] {
            files[k] = ((v["bytes"] as? NSNumber)?.intValue ?? 0, v["sha256"] as? String ?? "")
        }
        manifest = Manifest(source: cfg["source"] as? String ?? "?", precision: cfg["precision"] as? String ?? "?",
                            maxLength: (shape["max_length"] as? NSNumber)?.intValue ?? 512,
                            lengths: (shape["lengths"] as? [NSNumber])?.map(\.intValue) ?? [],
                            maxOptions: (shape["max_options"] as? NSNumber)?.intValue ?? 32, files: files)
        let rl = try Self.json(directory.appendingPathComponent("rl_agent_config.json"))
        headMaxLen = (rl["head_max_len"] as? NSNumber)?.intValue ?? 192
        temperature = (rl["temperature"] as? [NSNumber])?.map(\.doubleValue) ?? [1, 1, 1]
        temperatureByOptions = (rl["temperature_by_options"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:]
        guard temperature.count == 3, (temperature + Array(temperatureByOptions.values)).allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BackendError(code: .modelUnavailable, message: "rl_agent_config.json calibration temperatures are not finite and positive.")
        }
        tokenizer = try BPETokenizer(tokenizerJSON: directory.appendingPathComponent("tokenizer/tokenizer.json"),
                                     config: directory.appendingPathComponent("tokenizer/tokenizer_config.json"))
    }

    // MARK: Availability

    /// Cheap check: every manifest file exists with its recorded size. `verifyChecksums` does the sha256 pass.
    public static func availability(directory: URL = LayaCoreMLBackend.defaultDirectory) -> BackendAvailability {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("coreml_config.json").path) else {
            return .unavailable(reason: "No Laya checkpoint at \(directory.path).", remedy: downloadRemedy(for: directory))
        }
        do {
            let backend = try LayaCoreMLBackend(directory: directory)
            for (rel, meta) in backend.manifest.files {
                let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(rel).path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
                if size != meta.bytes {
                    return .unavailable(reason: "\(rel) is \(size) bytes; the manifest says \(meta.bytes).",
                                        remedy: "Re-download: " + downloadRemedy(for: directory))
                }
            }
            return .available
        } catch let e as BackendError {
            return .unavailable(reason: e.message, remedy: downloadRemedy(for: directory))
        } catch {
            return .unavailable(reason: String(describing: error), remedy: downloadRemedy(for: directory))
        }
    }

    public func availability() -> BackendAvailability { Self.availability(directory: directory) }

    /// SHA-256 every manifest file. Returns the paths that do not match.
    public func verifyChecksums() throws -> [String] {
        var bad: [String] = []
        for (rel, meta) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: directory.appendingPathComponent(rel))
            if SHA256Hex.digest(data) != meta.sha256 || data.count != meta.bytes { bad.append(rel) }
        }
        return bad
    }

    // MARK: Model

    /// Compiled model cached beside the package as `model.mlmodelc`; falls back to the user cache dir.
    func model() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let m = loadedModel { return m }
        let package = directory.appendingPathComponent("model.mlpackage")
        let compiled = directory.appendingPathComponent("model.mlmodelc")
        let fm = FileManager.default
        var compiledURL = compiled
        if !fm.fileExists(atPath: compiled.path) {
            let tmp = try MLModel.compileModel(at: package)
            if (try? fm.moveItem(at: tmp, to: compiled)) == nil {
                let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("verdict/laya/model.mlmodelc")
                try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: cache)
                try fm.moveItem(at: tmp, to: cache)
                compiledURL = cache
            }
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let m = try MLModel(contentsOf: compiledURL, configuration: config)
        loadedModel = m
        return m
    }

    /// Loads (and compiles if needed) the model now. Returns the wall time.
    @discardableResult
    public func warmUp() throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        _ = try model()
        return clock.now - start
    }

    /// Where Core ML placed the model's operations (`MLComputePlan`): counts per preferred device.
    /// On macOS 26.5 this export places every op on the CPU under every compute-unit setting.
    public func opPlacement() async throws -> [String: Int] {
        _ = try model()
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let plan = try await MLComputePlan.load(contentsOf: compiledModelURL(), configuration: config)
        var counts: [String: Int] = [:]
        guard case .program(let program) = plan.modelStructure, let main = program.functions["main"] else { return counts }
        func walk(_ block: MLModelStructure.Program.Block) {
            for op in block.operations {
                if let usage = plan.deviceUsage(for: op) {
                    switch usage.preferred {
                    case .cpu: counts["cpu", default: 0] += 1
                    case .gpu: counts["gpu", default: 0] += 1
                    case .neuralEngine: counts["neural_engine", default: 0] += 1
                    @unknown default: counts["other", default: 0] += 1
                    }
                } else {
                    counts["unplaced", default: 0] += 1
                }
                for b in op.blocks { walk(b) }
            }
        }
        walk(main.block)
        return counts
    }

    private func compiledModelURL() -> URL {
        let local = directory.appendingPathComponent("model.mlmodelc")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("verdict/laya/model.mlmodelc")
    }

    // MARK: Sampling

    public func sample(state: String, question: Question, sampling: Sampling) async throws -> Sample {
        // Deterministic model: `sampling` is ignored; the engine runs one sample when producesDistribution is true.
        let k = question.labels.count
        guard k <= manifest.maxOptions else {
            throw BackendError(code: .validation, message: "Laya export supports at most \(manifest.maxOptions) options; got \(k).")
        }
        let seq = LayaPrompt.sequence(state: state, question: question, tok: tokenizer,
                                      maxLen: manifest.maxLength, headMaxLen: headMaxLen)
        guard seq.markers.count == k else {
            throw BackendError(code: .contextExceeded, message: "Question has too many options for the token budget (\(seq.markers.count) of \(k) fit).")
        }
        let probs = try forward(seq, options: k)
        let labels = LayaPrompt.labels(question)      // marker order; noul is [false, true]
        let best = probs.indices.max { probs[$0] < probs[$1] }!
        let raw: RawAnswer
        switch question {
        case .choice: raw = .key(labels[best])
        case .score: raw = .level(best)
        case .noul: raw = .bool(best == 1)
        }
        return Sample(raw: raw, distribution: Dictionary(uniqueKeysWithValues: zip(labels, probs)))
    }

    /// Calibrated probabilities over the first `k` marker logits (`ResultMixin.system_one`).
    func forward(_ seq: LayaPrompt.Sequence, options k: Int) throws -> [Double] {
        let model = try model()
        let length = manifest.lengths.first { $0 >= seq.ids.count } ?? manifest.maxLength
        guard seq.ids.count <= manifest.maxLength else {
            throw BackendError(code: .contextExceeded, message: "Input has \(seq.ids.count) tokens; this export supports at most \(manifest.maxLength).")
        }
        let inputIDs = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let markerPos = try MLMultiArray(shape: [1, NSNumber(value: manifest.maxOptions)], dataType: .int32)
        let markerMask = try MLMultiArray(shape: [1, NSNumber(value: manifest.maxOptions)], dataType: .int32)
        let qtype = try MLMultiArray(shape: [1], dataType: .int32)
        let idPtr = inputIDs.dataPointer.bindMemory(to: Int32.self, capacity: length)
        let maskPtr = mask.dataPointer.bindMemory(to: Int32.self, capacity: length)
        for i in 0..<length {
            idPtr[i] = i < seq.ids.count ? seq.ids[i] : tokenizer.padID
            maskPtr[i] = i < seq.ids.count ? 1 : 0
        }
        let mpPtr = markerPos.dataPointer.bindMemory(to: Int32.self, capacity: manifest.maxOptions)
        let mmPtr = markerMask.dataPointer.bindMemory(to: Int32.self, capacity: manifest.maxOptions)
        for i in 0..<manifest.maxOptions {
            mpPtr[i] = i < seq.markers.count ? seq.markers[i] : 0
            mmPtr[i] = i < seq.markers.count ? 1 : 0
        }
        qtype[0] = NSNumber(value: seq.qtype)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inputIDs, "attention_mask": mask, "marker_pos": markerPos, "marker_mask": markerMask, "qtype": qtype,
        ])
        lock.lock()
        defer { lock.unlock() }
        let output = try model.prediction(from: input)
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw BackendError(code: .backendError, message: "Core ML output lacks `logits`.")
        }
        var z: [Double] = (0..<k).map { logits[$0].doubleValue }
        guard z.allSatisfy(\.isFinite) else {
            throw BackendError(code: .backendError, message: "Non-finite Core ML logits.")
        }
        let bucket = LayaPrompt.temperatureBucket(qtype: seq.qtype, options: k)
        let scale = max(1e-3, temperatureByOptions[bucket] ?? temperature[Int(seq.qtype)])
        z = z.map { $0 / scale }
        let m = z.max()!
        let e = z.map { exp($0 - m) }
        let sum = e.reduce(0, +)
        return e.map { $0 / sum }
    }

    // MARK: Helpers

    static func json(_ url: URL) throws -> [String: Any] {
        do {
            guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw BackendError(code: .modelUnavailable, message: "\(url.path) is not a JSON object.")
            }
            return obj
        } catch let e as BackendError {
            throw e
        } catch {
            throw BackendError(code: .modelUnavailable, message: "Cannot read \(url.path): \(error.localizedDescription)")
        }
    }
}

enum SHA256Hex {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
