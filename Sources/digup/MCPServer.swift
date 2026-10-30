import DigUpCore
import Foundation

/// `digup mcp`: the index as an MCP server (Model Context Protocol) on stdin/stdout, for AI agents. JSON-RPC 2.0, one
/// message per line; logs go to stderr. It reads the index the app (or `digup index`) writes: it only searches it, and
/// it won't make one where there's none.
///
/// Tools: `search` (words, with kinds, people and a time), `photos` (of people or a time, newest first), `people`
/// and `status`. The query encoder starts on the first search and stays loaded; the vectors are read again for every
/// search, so what the app indexed meanwhile is found.
func mcpServer(_ args: Arguments) -> Int32 {
    let server = MCPServer(index: args.indexFolder)
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            server.send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
            continue
        }
        server.handle(message)
    }
    server.close()
    return 0
}

final class MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    let index: URL
    private var embedder: (any Embedder)?

    init(index: URL) {
        self.index = index
    }

    func close() {
        embedder?.close()
    }

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    func handle(_ message: [String: Any]) {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return }   // a notification ("notifications/initialized"): nothing to answer
        func reply(_ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            reply(["protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                   "capabilities": ["tools": [String: Any]()],
                   "serverInfo": ["name": "digup", "title": "DigUpPhotos", "version": "1"],
                   "instructions": "Searches the user's photos, videos and documents by what they show or say. "
                       + "Times can be in the query (\"beach 2023\") or in `when`."])
        case "ping":
            reply([:])
        case "tools/list":
            reply(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try call(name, arguments)
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
                reply(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                       "structuredContent": result])
            } catch {
                reply(["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no method \(method)"]])
        }
    }

    // MARK: Tools

    private func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let file = index.appendingPathComponent(IndexStore.mainFile)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CLIError("no index at \(index.path): open DigUpPhotos or run `digup index` first")
        }
        let store = try IndexStore(directory: index)
        switch name {
        case "search": return try search(arguments, store: store)
        case "photos": return try photos(arguments, store: store)
        case "people":
            return ["people": try store.people().map { person -> [String: Any] in
                ["id": person.id, "name": person.name ?? NSNull(), "photos": person.photoCount]
            }]
        case "status":
            let counts = try store.counts()
            var files: [String: Int] = [:]
            for (kind, states) in counts.byKindAndState { files[kind] = states.values.reduce(0, +) }
            return ["index": index.path, "files": files, "vectors": counts.vectors,
                    "long_files_being_read": counts.unfinished]
        default:
            throw CLIError("no tool \(name)")
        }
    }

    private func search(_ arguments: [String: Any], store: IndexStore) throws -> [String: Any] {
        guard var query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            throw CLIError("search needs a query")
        }
        var dates = try span(arguments["when"])
        if dates == nil, let typed = DateSpan.parse(query) {
            dates = typed.span
            query = typed.rest
        }
        let people = try self.people(arguments["people"], store: store)
        let kinds = try self.kinds(arguments["kinds"])
        let limit = min(max(arguments["limit"] as? Int ?? 20, 1), 200)
        let searcher = try Searcher(store: store)
        guard !query.isEmpty else {
            return ["results": try searcher.photos(of: people ?? [], in: dates, kinds: kinds, limit: limit).map(row)]
        }
        let parsed = Searcher.parse(query)
        let vectors = try encode(Searcher.embedPhrases(query), searcher: searcher)
        let hits = try searcher.search(query, queryVector: vectors?.first, kinds: kinds, people: people, dates: dates,
                                       limit: limit, clauseVectors: parsed.hasOperators ? (vectors ?? []) : [])
        let strong = Searcher.strongCount(hits)
        return ["query": query, "when": dates?.title ?? NSNull(),
                "results": hits.enumerated().map { index, hit in
                    var out = row(hit)
                    out["strong"] = index < strong
                    return out
                }]
    }

    private func photos(_ arguments: [String: Any], store: IndexStore) throws -> [String: Any] {
        let dates = try span(arguments["when"])
        let people = try self.people(arguments["people"], store: store) ?? []
        guard dates != nil || !people.isEmpty else { throw CLIError("photos needs people, a time (`when`), or both") }
        let limit = min(max(arguments["limit"] as? Int ?? 50, 1), 1000)
        let searcher = try Searcher(store: store, loadVectors: false)
        return ["when": dates?.title ?? NSNull(),
                "results": try searcher.photos(of: people, in: dates, kinds: try kinds(arguments["kinds"]),
                                               limit: limit).map(row)]
    }

    /// The query encoder, started once (it takes seconds) and kept.
    private func encode(_ phrases: [String], searcher: Searcher) throws -> [[Float]]? {
        guard searcher.vectorCount > 0, !phrases.isEmpty else { return nil }
        if embedder == nil {
            embedder = try makeEmbedder(textOnly: true, log: index.appendingPathComponent("worker-mcp.log"))
        }
        guard let embedder else { return nil }
        if let source = searcher.vectorSource, source != embedder.info.vectorSource {
            throw CLIError("the index's vectors come from \(source) but the query encoder is \(embedder.info.vectorSource)")
        }
        return try embedder.embedTexts(phrases.map(Prompts.query))
    }

    private func row(_ hit: SearchHit) -> [String: Any] {
        var out: [String: Any] = ["path": hit.path, "kind": hit.kind.rawValue]
        if let taken = hit.info["taken"] { out["taken"] = taken }
        if let lat = hit.info["lat"], let lon = hit.info["lon"] { out["location"] = "\(lat),\(lon)" }
        if hit.z != nil || hit.keywordRank != nil {
            out["matched"] = hit.matchedMeaning ? "meaning" : (hit.keywordRank != nil ? "words" : "name")
            out["score"] = (hit.score * 100).rounded() / 100
        }
        if let loc = hit.loc { out[hit.segment == .page || hit.segment == .pageImage ? "page" : "seconds"] = loc }
        if let excerpt = hit.excerpt { out["excerpt"] = excerpt }
        return out
    }

    private func span(_ value: Any?) throws -> DateSpan? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard let parsed = DateSpan.parse(text), parsed.rest.isEmpty else {
            throw CLIError("can't read the time “\(text)”: try “2023”, “july 2023”, “2019-2021” or “last year”")
        }
        return parsed.span
    }

    /// People by id or name (any case); nil when none were asked for.
    private func people(_ value: Any?, store: IndexStore) throws -> Set<Int64>? {
        let asked = (value as? [Any] ?? []).map { "\($0)" }
        guard !asked.isEmpty else { return nil }
        let everyone = try store.people()
        return Set(try asked.map { wanted in
            if let id = Int64(wanted), everyone.contains(where: { $0.id == id }) { return id }
            guard let person = everyone.first(where: { $0.name?.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw CLIError("no person “\(wanted)” (see the `people` tool)")
            }
            return person.id
        })
    }

    private func kinds(_ value: Any?) throws -> Set<FileKind>? {
        let asked = value as? [String] ?? []
        guard !asked.isEmpty else { return nil }
        return Set(try asked.map { name in
            guard let kind = FileKind(rawValue: name) else { throw CLIError("no kind “\(name)”") }
            return kind
        })
    }

    private static var kindSchema: [String: Any] {
        [
            "type": "array", "items": ["type": "string", "enum": FileKind.allCases.map(\.rawValue)],
            "description": "Only these kinds of files.",
        ]
    }

    private static var peopleSchema: [String: Any] {
        [
            "type": "array", "items": ["type": ["string", "integer"]],
            "description": "People by name or id (from the `people` tool); a photo must have all of them.",
        ]
    }

    private static var whenSchema: [String: Any] {
        [
            "type": "string",
            "description": "When it was taken: \"2023\", \"july 2023\", \"2019-2021\", \"last year\" (English or Polish).",
        ]
    }

    static var tools: [[String: Any]] {
        [
            ["name": "search",
             "title": "Search photos and files",
             "description": "Finds photos, videos, screenshots and documents by what they show or say (\"dog on the beach\", "
                 + "\"receipt from the hardware store\") and by words in them. Results are best first; `strong` is false "
                 + "for ones that trail far behind. An empty list means nothing was close.",
             "inputSchema": ["type": "object", "required": ["query"],
                             "properties": ["query": ["type": "string", "description": "What to look for."],
                                            "kinds": kindSchema, "people": peopleSchema, "when": whenSchema,
                                            "limit": ["type": "integer", "minimum": 1, "maximum": 200]]],
             "annotations": ["readOnlyHint": true]],
            ["name": "photos",
             "title": "Photos of people or a time",
             "description": "Every photo and video with the given people on it and/or taken in the given time, newest first.",
             "inputSchema": ["type": "object",
                             "properties": ["people": peopleSchema, "when": whenSchema, "kinds": kindSchema,
                                            "limit": ["type": "integer", "minimum": 1, "maximum": 1000]]],
             "annotations": ["readOnlyHint": true]],
            ["name": "people",
             "title": "People",
             "description": "The people found on the photos (grouped by face): id, name if the user gave one, photo count.",
             "inputSchema": ["type": "object", "properties": [String: Any]()],
             "annotations": ["readOnlyHint": true]],
            ["name": "status",
             "title": "Index status",
             "description": "What's indexed: files per kind and vectors.",
             "inputSchema": ["type": "object", "properties": [String: Any]()],
             "annotations": ["readOnlyHint": true]],
        ]
    }
}
