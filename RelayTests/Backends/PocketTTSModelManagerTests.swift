import Foundation
import XCTest

@testable import Relay

final class PocketTTSModelManagerTests: XCTestCase {
    func testOneModelIsAlwaysSelected() async {
        let manager = SingleModelManager.pocketTTS(engine: FakeManagerPocketEngine(present: true))
        let rows = await manager.models()
        XCTAssertEqual(rows.map(\.id), [manager.descriptor.id])
        XCTAssertEqual(rows[0].capabilities, [.download, .select, .remove])
        XCTAssertEqual(rows[0].installState, .downloaded)
        XCTAssertTrue(rows[0].isSelected)
    }

    func testDownloadUsesExplicitDownloadLoad() async throws {
        let engine = FakeManagerPocketEngine(present: false)
        let manager = SingleModelManager.pocketTTS(engine: engine)
        try await manager.downloadModel(manager.descriptor.id) { _ in }
        let downloadCount = await engine.downloadCount
        let localCount = await engine.localCount
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(localCount, 0)
    }

    func testRemoveDelegatesToEngine() async throws {
        let engine = FakeManagerPocketEngine(present: true)
        let manager = SingleModelManager.pocketTTS(engine: engine)

        try await manager.removeModel(manager.descriptor.id)

        let removeCount = await engine.removeCount
        XCTAssertEqual(removeCount, 1)
    }
}

private actor FakeManagerPocketEngine: PocketTTSEngine {
    private var present: Bool
    private(set) var downloadCount = 0
    private(set) var localCount = 0
    private(set) var removeCount = 0

    init(present: Bool) { self.present = present }
    func modelsArePresent() async -> Bool { present }
    func removeModels() async throws { removeCount += 1; present = false }
    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        if allowDownload { downloadCount += 1; present = true; progress(1) } else { localCount += 1 }
    }
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
