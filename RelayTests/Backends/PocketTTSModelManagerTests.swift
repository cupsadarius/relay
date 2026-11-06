import Foundation
import XCTest

@testable import Relay

final class PocketTTSModelManagerTests: XCTestCase {
    func testOneModelIsAlwaysSelected() async {
        let manager = SingleModelManager.pocketTTS(model: .pocketTTS(loader: FakeManagerPocketLoader(present: true)))
        let rows = await manager.models()
        XCTAssertEqual(rows.map(\.id), [manager.descriptor.id])
        XCTAssertEqual(rows[0].capabilities, [.download, .select, .remove])
        XCTAssertEqual(rows[0].installState, .downloaded)
        XCTAssertTrue(rows[0].isSelected)
    }

    func testDownloadUsesExplicitDownloadLoad() async throws {
        let loader = FakeManagerPocketLoader(present: false)
        let manager = SingleModelManager.pocketTTS(model: .pocketTTS(loader: loader))
        try await manager.downloadModel(manager.descriptor.id) { _ in }
        let downloadCount = await loader.downloadCount
        let localCount = await loader.localCount
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(localCount, 0)
    }

    func testRemoveDelegatesToLoader() async throws {
        let loader = FakeManagerPocketLoader(present: true)
        let manager = SingleModelManager.pocketTTS(model: .pocketTTS(loader: loader))

        try await manager.removeModel(manager.descriptor.id)

        let removeCount = await loader.removeCount
        XCTAssertEqual(removeCount, 1)
    }
}

private actor FakeManagerPocketLoader: PocketTTSModelLoading {
    private var present: Bool
    private(set) var downloadCount = 0
    private(set) var localCount = 0
    private(set) var removeCount = 0

    init(present: Bool) { self.present = present }
    func modelsArePresent() async -> Bool { present }
    func removeModels() async throws { removeCount += 1; present = false }
    func loadLocal() async throws -> any PocketTTSModelSession {
        localCount += 1
        return FakeManagerPocketSession()
    }
    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> any PocketTTSModelSession {
        downloadCount += 1
        present = true
        progress(1)
        return FakeManagerPocketSession()
    }
}

private struct FakeManagerPocketSession: PocketTTSModelSession {
    func synthesizeStream(text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
