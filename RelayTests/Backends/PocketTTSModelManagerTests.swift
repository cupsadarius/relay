import Foundation
import XCTest
@testable import Relay

final class PocketTTSModelManagerTests: XCTestCase {
    func testOneModelIsAlwaysSelected() async {
        let manager = PocketTTSModelManager(engine: FakeManagerPocketEngine(present: true))
        let rows = await manager.models()
        XCTAssertEqual(rows.map(\.id), [PocketTTSModelManager.modelID])
        XCTAssertEqual(rows[0].capabilities, [.download, .select, .remove])
        XCTAssertEqual(rows[0].installState, .downloaded)
        XCTAssertTrue(rows[0].isSelected)
    }

    func testDownloadUsesExplicitDownloadLoad() async throws {
        let engine = FakeManagerPocketEngine(present: false)
        let manager = PocketTTSModelManager(engine: engine)
        try await manager.downloadModel(PocketTTSModelManager.modelID) { _ in }
        let downloadCount = await engine.downloadCount
        let localCount = await engine.localCount
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(localCount, 0)
    }
}

private actor FakeManagerPocketEngine: PocketTTSEngine {
    private var present: Bool
    private(set) var downloadCount = 0
    private(set) var localCount = 0

    init(present: Bool) { self.present = present }
    func modelsArePresent() async -> Bool { present }
    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        if allowDownload { downloadCount += 1; present = true; progress(1) }
        else { localCount += 1 }
    }
    func synthesize(text: String, voice: String) async throws -> Data { Data() }
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
