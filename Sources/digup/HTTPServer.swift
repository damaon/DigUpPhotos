import Foundation
#if canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

/// A small HTTP/1.1 server on the loopback interface, for `digup serve`: one thread per connection, one request per
/// connection (`Connection: close`), bodies by Content-Length. Enough for one person's browser on the same machine.
final class HTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: [String]]
        let headers: [String: String]   // lowercased names
        let body: Data

        func value(_ name: String) -> String? { query[name]?.last }
        func values(_ name: String) -> [String] { query[name] ?? [] }
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Body = .data(Data())

        enum Body {
            case data(Data)
            /// A file, or the part of it a Range header asked for.
            case file(URL, Range<UInt64>?)
        }

        static func json(_ object: Any, status: Int = 200) -> Response {
            let type = ["Content-Type": "application/json; charset=utf-8"]
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                return Response(status: 500, headers: type, body: .data(Data(#"{"error":"can't write the answer as JSON"}"#.utf8)))
            }
            return Response(status: status, headers: type, body: .data(data))
        }

        static func text(_ text: String, status: Int, type: String = "text/plain; charset=utf-8") -> Response {
            Response(status: status, headers: ["Content-Type": type], body: .data(Data(text.utf8)))
        }

        static func error(_ status: Int, _ message: String) -> Response { json(["error": message], status: status) }
    }

    let port: UInt16
    private let listener: Socket.Handle
    private let handle: @Sendable (Request) -> Response

    /// Listens on 127.0.0.1:`port` (0: any free port; `port` then says which).
    init(port: UInt16, handle: @escaping @Sendable (Request) -> Response) throws {
        (listener, self.port) = try Socket.listen(port: port)
        self.handle = handle
    }

    /// Accepts connections until the process ends.
    func run() -> Never {
        while true {
            guard let connection = Socket.accept(listener) else { continue }
            Thread.detachNewThread { [self] in
                serve(connection)
                Socket.close(connection)
            }
        }
    }

    private func serve(_ connection: Socket.Handle) {
        guard let request = read(connection) else {
            write(.text("bad request", status: 400), to: connection, headOnly: false)
            return
        }
        write(handle(request), to: connection, headOnly: request.method == "HEAD")
    }

    private func read(_ connection: Socket.Handle) -> Request? {
        var buffer = Data()
        var headerEnd: Int?
        while headerEnd == nil {
            guard buffer.count < 64 * 1024, let chunk = Socket.receive(connection), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))?.upperBound
        }
        guard let headerEnd else { return nil }
        let head = String(decoding: buffer[..<headerEnd], as: UTF8.self).split(separator: "\r\n")
        let line = head.first?.split(separator: " ") ?? []
        guard line.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for field in head.dropFirst() {
            guard let colon = field.firstIndex(of: ":") else { continue }
            headers[field[..<colon].lowercased()] = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= 1024 * 1024 else { return nil }
        var body = Data(buffer[headerEnd...])
        while body.count < length {
            guard let chunk = Socket.receive(connection), !chunk.isEmpty else { return nil }
            body.append(chunk)
        }
        let target = line[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        // Form encoding, as browsers write it: "+" is a space (URLComponents leaves it a "+").
        func decode(_ text: Substring) -> String {
            text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(text)
        }
        var query: [String: [String]] = [:]
        for pair in target.count > 1 ? target[1].split(separator: "&") : [] {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            query[decode(parts[0]), default: []].append(parts.count > 1 ? decode(parts[1]) : "")
        }
        return Request(method: String(line[0]), path: target[0].removingPercentEncoding ?? String(target[0]),
                       query: query, headers: headers, body: body.prefix(length))
    }

    private func write(_ response: Response, to connection: Socket.Handle, headOnly: Bool) {
        var response = response
        var length = 0
        switch response.body {
        case .data(let data): length = data.count
        case .file(let url, let range):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if let range {
                let clamped = range.clamped(to: 0..<size)
                response.body = .file(url, clamped)
                response.headers["Content-Range"] = "bytes \(clamped.lowerBound)-\(max(clamped.lowerBound, clamped.upperBound) - 1)/\(size)"
                length = clamped.count
            } else {
                length = Int(size)
            }
            response.headers["Accept-Ranges"] = "bytes"
        }
        response.headers["Content-Length"] = String(length)
        response.headers["Connection"] = "close"
        response.headers["X-Content-Type-Options"] = "nosniff"
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        guard Socket.send(Data(head.utf8), to: connection), !headOnly else { return }
        switch response.body {
        case .data(let data):
            _ = Socket.send(data, to: connection)
        case .file(let url, let range):
            guard let file = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? file.close() }
            var left = UInt64(length)
            if let range { try? file.seek(toOffset: range.lowerBound) }
            while left > 0, let chunk = try? file.read(upToCount: Int(min(left, 256 * 1024))), !chunk.isEmpty {
                guard Socket.send(chunk, to: connection) else { return }
                left -= UInt64(chunk.count)
            }
        }
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 204: "No Content", 206: "Partial Content", 304: "Not Modified", 400: "Bad Request",
         403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 416: "Range Not Satisfiable",
         500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Status"
    }
}

/// BSD sockets, and Winsock on Windows: just what a loopback server needs.
enum Socket {
    #if os(Windows)
    typealias Handle = SOCKET
    typealias Length = Int32
    #else
    typealias Handle = Int32
    typealias Length = socklen_t
    #endif

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func listen(port: UInt16) throws -> (Handle, UInt16) {
        #if os(Windows)
        var data = WSADATA()
        guard WSAStartup(0x0202, &data) == 0 else { throw Failure(description: "can't start Winsock") }
        let handle = WinSDK.socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        guard handle != INVALID_SOCKET else { throw Failure(description: "can't open a socket") }
        #elseif canImport(Glibc)
        let handle = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard handle >= 0 else { throw Failure(description: "can't open a socket") }
        #else
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw Failure(description: "can't open a socket") }
        #endif
        #if !os(Windows)
        var yes: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var address = sockaddr_in()
        address.sin_port = port.bigEndian
        #if os(Windows)
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
        #else
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian   // 127.0.0.1: never reachable from the network
        #endif
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, Length(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Socket.close(handle)
            throw Failure(description: "port \(port) is taken (another digup serve?)")
        }
        #if os(Windows)
        guard WinSDK.listen(handle, 64) == 0 else { throw Failure(description: "can't listen on port \(port)") }
        #elseif canImport(Glibc)
        guard Glibc.listen(handle, 64) == 0 else { throw Failure(description: "can't listen on port \(port)") }
        #else
        guard Darwin.listen(handle, 64) == 0 else { throw Failure(description: "can't listen on port \(port)") }
        #endif
        var actual = sockaddr_in()
        var size = Length(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &size) }
        }
        return (handle, UInt16(bigEndian: actual.sin_port))
    }

    static func accept(_ listener: Handle) -> Handle? {
        #if os(Windows)
        let connection = WinSDK.accept(listener, nil, nil)
        return connection == INVALID_SOCKET ? nil : connection
        #elseif canImport(Glibc)
        let connection = Glibc.accept(listener, nil, nil)
        return connection < 0 ? nil : connection
        #else
        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { return nil }
        var yes: Int32 = 1   // a browser that went away mustn't kill us with SIGPIPE
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        return connection
        #endif
    }

    static func receive(_ connection: Handle) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = buffer.withUnsafeMutableBytes { bytes -> Int in
            #if os(Windows)
            Int(recv(connection, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count), 0))
            #else
            recv(connection, bytes.baseAddress, bytes.count, 0)
            #endif
        }
        return count < 0 ? nil : Data(buffer[0..<count])
    }

    /// False when the other side went away.
    static func send(_ data: Data, to connection: Handle) -> Bool {
        var sent = 0
        while sent < data.count {
            let count = data[(data.startIndex + sent)...].withUnsafeBytes { bytes -> Int in
                #if os(Windows)
                Int(WinSDK.send(connection, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count), 0))
                #elseif canImport(Glibc)
                Glibc.send(connection, bytes.baseAddress, bytes.count, Int32(MSG_NOSIGNAL))
                #else
                Darwin.send(connection, bytes.baseAddress, bytes.count, 0)
                #endif
            }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }

    static func close(_ handle: Handle) {
        #if os(Windows)
        closesocket(handle)
        #elseif canImport(Glibc)
        _ = Glibc.close(handle)
        #else
        _ = Darwin.close(handle)
        #endif
    }
}
