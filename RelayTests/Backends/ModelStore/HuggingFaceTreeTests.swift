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

    /// Review fix 13: never follow a `rel="next"` link to a host other than huggingface.co, or
    /// over anything but https, however well-formed the header otherwise looks.
    func testNextPageURLRejectsAnyOtherHostOrScheme() {
        let otherHost = #"<https://evil.test/api/models/a/b/tree/x?cursor=abc>; rel="next""#
        XCTAssertNil(HuggingFaceTree.nextPageURL(from: response(link: otherHost)))

        let notHTTPS = #"<http://huggingface.co/api/models/a/b/tree/x?cursor=abc>; rel="next""#
        XCTAssertNil(HuggingFaceTree.nextPageURL(from: response(link: notHTTPS)))

        let subdomainSpoof = #"<https://huggingface.co.evil.test/p>; rel="next""#
        XCTAssertNil(HuggingFaceTree.nextPageURL(from: response(link: subdomainSpoof)))
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
