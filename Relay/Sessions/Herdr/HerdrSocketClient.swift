import Foundation
import Darwin

protocol HerdrQuerying: Sendable {
    func currentPane(socketPath: String) async throws -> HerdrPaneInfo
}

struct HerdrSocketClient: HerdrQuerying {
    func currentPane(socketPath: String) async throws -> HerdrPaneInfo {
        let request = #"{"id":"relay_focus","method":"pane.current","params":{}}"# + "\n"
        let line = try await UnixLineRequest.send(path: socketPath, line: request, timeoutMilliseconds: 400)
        let response = try JSONDecoder().decode(HerdrResponse.self, from: Data(line.utf8))
        guard let pane = response.result?.pane else { throw HerdrQueryError.invalidResponse }
        return HerdrPaneInfo(paneID: pane.paneID, focused: pane.focused, agentSession: pane.agentSession)
    }
}

enum HerdrQueryError: Error { case invalidResponse, socketFailure, pathTooLong, responseTooLarge }

enum UnixLineRequest {
    static func send(path: String, line: String, timeoutMilliseconds: Int32) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try sendBlocking(path: path, line: line, timeoutMilliseconds: timeoutMilliseconds)
        }.value
    }

    private static func sendBlocking(path: String, line: String, timeoutMilliseconds: Int32) throws -> String {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw HerdrQueryError.pathTooLong
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrQueryError.socketFailure }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: timeoutMilliseconds * 1_000)
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { dst in
            dst.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { src in
                dst.copyBytes(from: src.prefix(dst.count))
            }
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard connected == 0 else { throw HerdrQueryError.socketFailure }

        let bytes = Array(line.utf8)
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            guard wrote > 0 else { throw HerdrQueryError.socketFailure }
            sent += wrote
        }

        var response = Data()
        var byte: UInt8 = 0
        while response.count <= 64 * 1024 {
            let count = Darwin.read(fd, &byte, 1)
            guard count > 0 else { throw HerdrQueryError.socketFailure }
            if byte == 0x0A { return String(decoding: response, as: UTF8.self) }
            response.append(byte)
        }
        throw HerdrQueryError.responseTooLarge
    }
}
