import DigUpCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import digup

/// `digup serve`: who gets in, and what the HTTP server makes of a browser's requests.
@Suite(.serialized) struct ServeTests {
    let folder: URL
    let app: WebApp

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("serve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app = try WebApp(index: folder.appendingPathComponent("index"), options: IndexOptions(), extraFolders: [])
        app.port = 7811
    }

    func request(_ path: String, method: String = "GET", query: [String: [String]] = [:],
                 headers: [String: String] = [:], body: Data = Data()) -> HTTPServer.Request {
        HTTPServer.Request(method: method, path: path, query: query,
                           headers: ["host": "127.0.0.1:7811"].merging(headers) { $1 }, body: body)
    }

    func sessionCookie() throws -> String {
        let page = app.handle(request("/"))
        #expect(page.status == 200)
        let cookie = try #require(page.headers["Set-Cookie"])
        #expect(cookie.contains("SameSite=Strict") && cookie.contains("HttpOnly"))
        return String(cookie.split(separator: ";")[0])
    }

    @Test func onlyThePageItSetTheCookieForGetsIn() throws {
        let cookie = try sessionCookie()
        #expect(app.handle(request("/api/status")).status == 403)                                    // no cookie
        #expect(app.handle(request("/api/status", headers: ["cookie": "digup=guess"])).status == 403)
        #expect(app.handle(request("/api/status", headers: ["cookie": cookie])).status == 200)
        // Another host name pointing here (DNS rebinding) gets nothing, not even the page.
        #expect(app.handle(request("/", headers: ["host": "evil.example:7811"])).status == 403)
        // A POST from another site, or not JSON, is turned away; from the page it goes through.
        let json = ["cookie": cookie, "content-type": "application/json"]
        #expect(app.handle(request("/api/sync", method: "POST", headers: json.merging(["origin": "http://evil.example"]) { $1 }))
            .status == 403)
        #expect(app.handle(request("/api/sync", method: "POST", headers: ["cookie": cookie, "content-type": "text/plain"]))
            .status == 403)
        #expect(app.handle(request("/api/sync", method: "POST", headers: json.merging(["origin": "http://127.0.0.1:7811"]) { $1 }))
            .status == 200)
    }

    @Test func filesAreServedOnlyFromTheIndex() throws {
        let cookie = try sessionCookie()
        let secret = folder.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)
        let response = app.handle(request("/api/file", query: ["path": [secret.path]], headers: ["cookie": cookie]))
        #expect(response.status == 404)
    }

    /// Through a socket, as a browser asks: "+" in the query is a space, a Range gives part of a file.
    @Test func browsersRequestsOverTheWire() throws {
        let server = try HTTPServer(port: 0) { request in
            if request.path == "/echo" { return .json(["q": request.value("q") ?? "", "path": request.path]) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("range-\(ProcessInfo.processInfo.processIdentifier).txt")
            try? Data("0123456789".utf8).write(to: file)
            return HTTPServer.Response(status: 206, body: .file(file, 2..<5))
        }
        Thread.detachNewThread { server.run() }
        func fetch(_ path: String) throws -> (Int, Data) {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: (Int, Data)?
            URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(server.port)\(path)")!) { data, response, _ in
                result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
                done.signal()
            }.resume()
            done.wait()
            return try #require(result)
        }
        let (status, data) = try fetch("/echo?q=person+smiling%21&other=1")
        #expect(status == 200)
        let echo = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(echo == ["q": "person smiling!", "path": "/echo"])
        let (partial, bytes) = try fetch("/range")
        #expect(partial == 206 && String(decoding: bytes, as: UTF8.self) == "234")
    }
}
