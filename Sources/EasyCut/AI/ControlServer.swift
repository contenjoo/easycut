import Foundation
import Network

/// 외부 Claude(Claude Code, Claude 데스크톱)가 MCP로 앱을 조작할 수 있게 하는 로컬 전용 제어 서버.
/// 127.0.0.1에만 열리고, 앱 지원 폴더의 비밀 토큰(사용자만 읽기 가능)을 가진 요청만 받는다.
@MainActor
final class ControlServer {
    nonisolated static let port: UInt16 = 47_821
    private var listener: NWListener?
    unowned let store: EditorStore

    nonisolated static var tokenURL: URL { AppPaths.support.appendingPathComponent("control-token") }

    init(store: EditorStore) { self.store = store }

    nonisolated static func token() -> String {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8), t.count >= 32 { return t }
        let t = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        return t
    }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        let token = Self.token()
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Self.receive(conn, buffer: Data()) { req in
                Task { @MainActor in
                    guard let self else { conn.cancel(); return }
                    let reply = await self.handle(req, token: token)
                    Self.respond(conn, reply)
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    /// HTTP 요청 하나를 끝까지 읽는다 (Content-Length 기준)
    nonisolated static func receive(_ conn: NWConnection, buffer: Data, done: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                let len = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if buf.count - range.upperBound >= len {
                    done(buf)
                    return
                }
            }
            if complete || error != nil || buf.count > 8 << 20 { done(buf); return }
            receive(conn, buffer: buf, done: done)
        }
    }

    nonisolated static func respond(_ conn: NWConnection, _ body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ raw: Data, token: String) async -> [String: Any] {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return ["error": "bad request"] }
        let head = String(decoding: raw[..<sep.lowerBound], as: UTF8.self)
        let auth = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("authorization:") }
            .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        guard auth == "Bearer \(token)" else { return ["error": "unauthorized"] }
        guard let body = try? JSONSerialization.jsonObject(with: raw[sep.upperBound...]) as? [String: Any],
              let name = body["name"] as? String else { return ["error": "bad body"] }
        let (text, isErr) = await AITools.execute(name, body["input"] as? [String: Any] ?? [:], store: store)
        return ["text": text, "is_error": isErr]
    }
}

/// `EasyCut --mcp` : MCP(stdio) 서버. 실행 중인 EasyCut 앱으로 도구 호출을 전달한다.
enum MCPBridge {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue } // 알림은 응답하지 않는다
            var result: [String: Any]?
            var error: [String: Any]?
            switch method {
            case "initialize":
                result = ["protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
                          "capabilities": ["tools": [String: Any]()],
                          "serverInfo": ["name": "easycut", "version": "1.0.0"],
                          "instructions": "EasyCut 영상 편집 앱을 조작합니다. 앱이 실행 중이어야 합니다. 먼저 get_project_state로 상태를 확인하세요."]
            case "ping":
                result = [:]
            case "tools/list":
                result = ["tools": AITools.definitions.map { d -> [String: Any] in
                    ["name": d["name"]!, "description": d["description"]!, "inputSchema": d["input_schema"]!]
                }]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                let (text, isErr) = call(name, args)
                result = ["content": [["type": "text", "text": text]], "isError": isErr]
            default:
                error = ["code": -32601, "message": "Method not found: \(method)"]
            }
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id!]
            if let result { reply["result"] = result }
            if let error { reply["error"] = error }
            if let out = try? JSONSerialization.data(withJSONObject: reply), let s = String(data: out, encoding: .utf8) {
                print(s)
            }
        }
    }

    static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        guard let token = try? String(contentsOf: ControlServer.tokenURL, encoding: .utf8) else {
            return ("EasyCut 앱이 실행 중이 아닙니다. 앱을 먼저 여세요.", true)
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(ControlServer.port)/tool")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1500
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "input": args])
        let sem = DispatchSemaphore(value: 0)
        var out: (String, Bool) = ("EasyCut 앱에 연결할 수 없습니다. 앱이 실행 중인지 확인하세요.", true)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let t = obj["text"] as? String { out = (t, (obj["is_error"] as? Bool) ?? false) }
                else if let e = obj["error"] as? String { out = ("오류: \(e)", true) }
            }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }
}
