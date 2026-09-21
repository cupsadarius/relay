import Foundation
import XCTest
@testable import Relay

final class KokoroModelManagerTests: XCTestCase {
    func testOneModelIsAlwaysSelectedAndPresenceControlsInstallState() async {
        let engine = FakeManagerKokoroEngine(present: false)
        let manager = KokoroModelManager(engine: engine)
        var rows = await manager.models()
        XCTAssertEqual(rows.map(\.id), [KokoroModelManager.modelID])
        XCTAssertEqual(rows[0].capabilities, [.download, .select, .remove])
        XCTAssertEqual(rows[0].installState, .notDownloaded)
        XCTAssertTrue(rows[0].isSelected)

        await engine.setPresent(true)
        rows = await manager.models()
        XCTAssertEqual(rows[0].installState, .downloaded)
    }

    func testDownloadUsesExplicitDownloadLoad() async throws {
        let engine = FakeManagerKokoroEngine(present: false)
        let manager = KokoroModelManager(engine: engine)
        try await manager.downloadModel(KokoroModelManager.modelID) { _ in }
        let downloadCount = await engine.downloadCount
        let localCount = await engine.localCount
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(localCount, 0)
    }
}

private actor FakeManagerKokoroEngine: KokoroEngine {
    private var present: Bool
    private(set) var downloadCount = 0
    private(set) var localCount = 0

    init(present: Bool) { self.present = present }
    func setPresent(_ value: Bool) { present = value }
    func modelsArePresent() async -> Bool { present }
    func load(allowDownload: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        if allowDownload { downloadCount += 1; present = true; progress(1) }
        else { localCount += 1 }
    }
    func synthesize(text: String, voice: String, speed: Float) async throws -> Data { Data() }
}
