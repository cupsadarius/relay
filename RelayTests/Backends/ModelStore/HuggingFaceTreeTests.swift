import XCTest

@testable import Relay

final class HuggingFaceTreeTests: XCTestCase {
    private func response(link: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://huggingface.co/api/models/a/b/tree/x")!, statusCode: 200, httpVersion: nil,
            headerFields: link.map { ["Link": $0] }
        )!
    }

    func testNextPageURLReadsTheRelNextEntry() {
        let link = #"<https://huggingface.co/api/models/a/b/tree/x?cursor=abc>; rel="next""#
        XCTAssertEqual(HuggingFaceTree.nextPageURL(from: response(link: link))?.absoluteString, "https://huggingface.co/api/models/a/b/tree/x?cursor=abc")
    }

    func testNextPageURLIsNilWithoutRelNext() {
        XCTAssertNil(HuggingFaceTree.nextPageURL(from: response(link: nil)))
        XCTAssertNil(HuggingFaceTree.nextPageURL(from: response(link: #"<https://x.test/p>; rel="prev""#)))
    }

    func testDecodesEntriesAndPrefersTheLFSOid() throws {
        let json = #"""
            [{"type":"file","path":"config.json","size":10,"oid":"aaa"},
             {"type":"file","path":"model.safetensors","size":20,"oid":"bbb","lfs":{"oid":"ccc","size":20}}]
            """#
        let entries = try JSONDecoder().decode([HFTreeEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.map(HuggingFaceTree.oid(for:)), [.gitBlobSHA1("aaa"), .sha256("ccc")])
    }
}
