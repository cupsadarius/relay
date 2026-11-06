import Foundation
import XCTest

@testable import Relay

final class KokoroModelManagerTests: XCTestCase {
    func testOneModelIsAlwaysSelectedAndPresenceControlsInstallState() async {
        let loader = FakeManagerKokoroLoader(present: false)
        let manager = SingleModelManager.kokoro(model: .kokoro(loader: loader))
        var rows = await manager.models()
        XCTAssertEqual(rows.map(\.id), [manager.descriptor.id])
        XCTAssertEqual(rows[0].capabilities, [.download, .select, .remove])
        XCTAssertEqual(rows[0].installState, .notDownloaded)
        XCTAssertTrue(rows[0].isSelected)

        await loader.setPresent(true)
        rows = await manager.models()
        XCTAssertEqual(rows[0].installState, .downloaded)
    }

    func testDownloadUsesExplicitDownloadLoad() async throws {
        let loader = FakeManagerKokoroLoader(present: false)
        let manager = SingleModelManager.kokoro(model: .kokoro(loader: loader))
        try await manager.downloadModel(manager.descriptor.id) { _ in }
        let downloadCount = await loader.downloadCount
        let localCount = await loader.localCount
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(localCount, 0)
    }

    func testRemoveDelegatesToLoader() async throws {
        let loader = FakeManagerKokoroLoader(present: true)
        let manager = SingleModelManager.kokoro(model: .kokoro(loader: loader))

        try await manager.removeModel(manager.descriptor.id)

        let removeCount = await loader.removeCount
        XCTAssertEqual(removeCount, 1)
    }
}

private actor FakeManagerKokoroLoader: KokoroModelLoading {
    private var present: Bool
    private(set) var downloadCount = 0
    private(set) var localCount = 0
    private(set) var removeCount = 0

    init(present: Bool) { self.present = present }
    func setPresent(_ value: Bool) { present = value }
    func modelsArePresent() async -> Bool { present }
    func removeModels() async throws { removeCount += 1; present = false }
    func loadLocal() async throws -> any KokoroModelSession {
        localCount += 1
        return FakeManagerKokoroSession()
    }
    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any KokoroModelSession {
        downloadCount += 1
        present = true
        progress(1)
        return FakeManagerKokoroSession()
    }
}

private struct FakeManagerKokoroSession: KokoroModelSession {
    func phonemes(for text: String) async throws -> String { text }
    func synthesize(phonemes: String, voice: String, speed: Float) async throws -> KokoroPCM {
        KokoroPCM(samples: [], sampleRate: 24_000)
    }
}
