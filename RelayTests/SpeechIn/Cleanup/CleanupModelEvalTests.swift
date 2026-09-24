import Foundation
import XCTest

@testable import Relay

/// Manual, opt-in (spec §19):
///   TEST_RUNNER_RELAY_CLEANUP_EVAL=1 TEST_RUNNER_RELAY_QWEN_DIR_0_6B=/tmp/relay-qwen/0.6b xcodebuild test … \
///     -only-testing:RelayTests/CleanupModelEvalTests
/// `TEST_RUNNER_RELAY_CLEANUP_EVAL_APPLE=1` adds the Apple model (needs a signed build on a Mac
/// with Apple Intelligence on). Writes `/tmp/relay-cleanup-eval-<model>.json`.
final class CleanupModelEvalTests: XCTestCase {
    struct Report: Encodable {
        let model: String
        let cases: Int
        let acceptanceRate: Double
        let referenceMatchRate: Double
        let correctionApplicationRate: Double
        let wrapperOrMarkupRate: Double
        let failOpenRate: Double
        let alreadyCleanFailOpenRate: Double
        let cueNegativeOverCorrections: Int
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let passesBar: Bool
    }

    private let environment = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["RELAY_CLEANUP_EVAL"] == "1", "set RELAY_CLEANUP_EVAL=1 to run the live eval")
    }

    func testQwen06B() async throws {
        try await evaluateMLX(.qwen3_0_6b, env: "RELAY_QWEN_DIR_0_6B")
    }

    func testQwen17B() async throws {
        try await evaluateMLX(.qwen3_1_7b, env: "RELAY_QWEN_DIR_1_7B")
    }

    func testAppleSystemModel() async throws {
        try XCTSkipUnless(environment["RELAY_CLEANUP_EVAL_APPLE"] == "1", "set RELAY_CLEANUP_EVAL_APPLE=1")
        let engine = AppleFoundationCleanupEngine()
        try XCTSkipUnless(engine.availability() == .available, "Apple model unavailable")
        try await evaluate(.appleSystem) { try await engine.respond($0) }
    }

    private func evaluateMLX(_ id: CleanupModelID, env: String) async throws {
        let directory: URL
        if let path = environment[env] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let store = MLXCleanupModelStore(root: RelayPaths.sharedModelsDirectory().appendingPathComponent("MLX", isDirectory: true))
            try XCTSkipUnless(store.presence(of: id), "\(id.displayName) not downloaded and \(env) unset")
            directory = store.directory(for: id)
        }
        let model = try await MLXLiveEngine().load(directory: directory)
        try await evaluate(id) { try await model.generate($0) }
        await model.unload()
    }

    private func evaluate(_ id: CleanupModelID, generate: (CleanupRequest) async throws -> String) async throws {
        let corpus = try CleanupEvalCorpus.load().filter { $0.category != "nonEnglish" }
        let validator = CleanupSafetyValidator()
        func request(_ input: String) -> CleanupRequest {
            CleanupRequest(modelID: id, instructions: CleanupPrompt.instructions, input: input, maxOutputTokens: CleanupPrompt.maxOutputTokens(for: input))
        }

        _ = try await generate(request("warm up the model")) // exclude the first-call cost from warm latency

        var accepted = 0
        var referenceMatches = 0
        var wrapperOrMarkup = 0
        var corrections = (total: 0, applied: 0)
        var alreadyClean = (total: 0, failedOpen: 0)
        var cueNegativeOverCorrections = 0
        var latencies: [Double] = []
        let clock = ContinuousClock()

        for testCase in corpus {
            let started = clock.now
            // Same path as production: pre-pass, generate, validate against the pre-passed text.
            let prePassed = SelfCorrectionPrePass.apply(to: testCase.input)
            let output = (try? await generate(request(prePassed.text))) ?? ""
            latencies.append(Self.milliseconds(clock.now - started))

            let verdict = validator.validate(input: prePassed.text, output: output, replaced: prePassed.replaced, phrases: prePassed.phrases)
            let good = [testCase.reference] + testCase.acceptable
            // `contentMatches` ignores sentence punctuation: correction application and cue-negative
            // over-corrections judge the words kept. `referenceMatchRate` stays strict (spec §19).
            var contentMatches = false
            switch verdict {
            case let .accept(cleaned):
                accepted += 1
                if CleanupEvalScoring.matches(cleaned, good: good, key: CleanupEvalScoring.referenceKey) { referenceMatches += 1 }
                contentMatches = CleanupEvalScoring.matches(cleaned, good: good, key: CleanupEvalScoring.contentKey)
                if testCase.category == "cueNegative", !contentMatches { cueNegativeOverCorrections += 1 }
            case .reject(.wrapper), .reject(.reasoningMarkup):
                wrapperOrMarkup += 1
            case .reject:
                break
            }
            if testCase.category.hasPrefix("correction."), testCase.category != "correction.retractionOnly" {
                corrections.total += 1
                if contentMatches { corrections.applied += 1 }
            }
            if testCase.category == "alreadyClean" {
                alreadyClean.total += 1
                if case .reject = verdict { alreadyClean.failedOpen += 1 }
            }
        }

        let total = Double(corpus.count)
        let sorted = latencies.sorted()
        let percentile: (Double) -> Double = { sorted[min(sorted.count - 1, Int((Double(sorted.count) * $0).rounded(.up)) - 1)] }
        let failOpen = 1 - Double(accepted) / total
        let alreadyCleanFailOpen = alreadyClean.total == 0 ? 0 : Double(alreadyClean.failedOpen) / Double(alreadyClean.total)
        let correctionRate = corrections.total == 0 ? 1 : Double(corrections.applied) / Double(corrections.total)
        let p95 = percentile(0.95)
        let report = Report(
            model: id.rawValue,
            cases: corpus.count,
            acceptanceRate: Double(accepted) / total,
            referenceMatchRate: Double(referenceMatches) / total,
            correctionApplicationRate: correctionRate,
            wrapperOrMarkupRate: Double(wrapperOrMarkup) / total,
            failOpenRate: failOpen,
            alreadyCleanFailOpenRate: alreadyCleanFailOpen,
            cueNegativeOverCorrections: cueNegativeOverCorrections,
            p50Milliseconds: percentile(0.5),
            p95Milliseconds: p95,
            passesBar: p95 <= 1500 && failOpen <= 0.15 && alreadyCleanFailOpen <= 0.05 && correctionRate >= 0.8
                && cueNegativeOverCorrections == 0
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: "/tmp/relay-cleanup-eval-\(id.rawValue).json"))
        print(String(decoding: data, as: UTF8.self))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
