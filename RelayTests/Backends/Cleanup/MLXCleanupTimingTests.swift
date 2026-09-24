import Synchronization
import XCTest

@testable import Relay

/// Spike S3 (spec §21), kept for re-runs on other Macs. Opt-in: set
/// `TEST_RUNNER_RELAY_QWEN_DIR_0_6B` and/or `TEST_RUNNER_RELAY_QWEN_DIR_1_7B` to verified snapshots.
final class MLXCleanupTimingTests: XCTestCase {
    private static let inputs = [
        "uh so I think we should um ship the release on friday",
        "set the port to 3 no 4 and restart the server",
        "open src/app.swift I mean src/main.swift and add a test for the parser",
        "uh change the user service no wait the auth service to use refresh tokens and don't change the API",
        "okay so the build is failing because um the tests in the networking module time out after like thirty seconds "
            + "and we should probably bump that to sixty",
    ]

    private final class FirstChunk: Sendable {
        private let instant = Mutex<ContinuousClock.Instant?>(nil)
        func mark() { instant.withLock { if $0 == nil { $0 = .now } } }
        var value: ContinuousClock.Instant? { instant.withLock { $0 } }
    }

    func testColdAndWarmTiming() async throws {
        let env = ProcessInfo.processInfo.environment
        let targets: [(CleanupModelID, String)] = [
            (.qwen3_0_6b, "RELAY_QWEN_DIR_0_6B"), (.qwen3_1_7b, "RELAY_QWEN_DIR_1_7B"),
        ].compactMap { id, key in env[key].map { (id, $0) } }
        guard !targets.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_RELAY_QWEN_DIR_0_6B and/or TEST_RUNNER_RELAY_QWEN_DIR_1_7B")
        }
        let clock = ContinuousClock()
        for (id, path) in targets {
            let engine = MLXLiveEngine()
            let loadStart = clock.now
            let loaded = try await engine.load(directory: URL(fileURLWithPath: path, isDirectory: true))
            let loadTime = clock.now - loadStart
            let model = try XCTUnwrap(loaded as? MLXLoadedCleanupModel)

            var warmTotals: [Duration] = []
            var warmFirsts: [Duration] = []
            var coldGeneration: Duration?
            for round in 0..<3 {
                for text in Self.inputs {
                    let request = CleanupRequest(
                        modelID: id, instructions: CleanupPrompt.instructions, input: text,
                        maxOutputTokens: CleanupPrompt.maxOutputTokens(for: text)
                    )
                    let first = FirstChunk()
                    let start = clock.now
                    _ = try await model.generate(request, onFirstChunk: { first.mark() })
                    let total = clock.now - start
                    if coldGeneration == nil {
                        coldGeneration = total
                        continue
                    }
                    warmTotals.append(total)
                    if let firstAt = first.value { warmFirsts.append(firstAt - start) }
                    print("S3 \(id.diagnosticName) round=\(round) total_ms=\(Self.ms(total))")
                }
            }
            print(
                "S3 SUMMARY \(id.diagnosticName) load_ms=\(Self.ms(loadTime)) cold_generation_ms=\(Self.ms(coldGeneration ?? .zero)) "
                    + "warm_total_p50_ms=\(Self.ms(Self.percentile(warmTotals, 0.5))) warm_total_p95_ms=\(Self.ms(Self.percentile(warmTotals, 0.95))) "
                    + "warm_first_p50_ms=\(Self.ms(Self.percentile(warmFirsts, 0.5))) warm_first_p95_ms=\(Self.ms(Self.percentile(warmFirsts, 0.95)))"
            )
            await model.unload()
            await engine.clearCache()
        }
    }

    private static func percentile(_ values: [Duration], _ p: Double) -> Duration {
        guard !values.isEmpty else { return .zero }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))
        return sorted[index]
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
