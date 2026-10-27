import Foundation

final class MockProtocol: URLProtocol {
    static var reply: [String: Any] = [:]
    static var status = 200
    static var captured: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: Self.reply))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct GeminiTests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        let schema: [String: Any] = ["name": "add_text", "description": "title", "input_schema": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]]
        let body = GeminiClient.body(contents: [["role": "user", "parts": [["text": "제목 넣어줘"]]]], system: "editor", tools: [schema])
        let data = try JSONSerialization.data(withJSONObject: body)
        let encoded = String(data: data, encoding: .utf8)!
        precondition(encoded.contains("functionDeclarations") && !encoded.contains("input_schema"))
        let emptyTool: [String: Any] = ["name": "get_project_state", "input_schema": ["type": "object", "properties": [:]]]
        let emptyBody = GeminiClient.body(contents: [], system: nil, tools: [emptyTool])
        let declarations = (emptyBody["tools"] as! [[String: Any]])[0]["functionDeclarations"] as! [[String: Any]]
        precondition(declarations[0]["parameters"] == nil) // Gemini rejects empty OBJECT schemas.
        let modelContent: [String: Any] = ["role": "model", "parts": [["thoughtSignature": "opaque-signature", "functionCall": ["id": "call-1", "name": "add_text", "args": ["text": "안녕하세요", "start": 0]]]]]
        MockProtocol.reply = ["candidates": [["finishReason": "STOP", "content": modelContent]]]
        let response = try await GeminiClient.request(key: "test-secret", contents: [], system: "editor", tools: [schema], session: session)
        let parsed = try GeminiClient.content(response)
        precondition(NSDictionary(dictionary: parsed).isEqual(to: modelContent))
        precondition(MockProtocol.captured?.value(forHTTPHeaderField: "x-goog-api-key") == "test-secret")
        precondition(!(MockProtocol.captured?.url?.absoluteString.contains("test-secret") ?? true))
        precondition(MockProtocol.captured?.url?.host == "generativelanguage.googleapis.com")
        for code in [400, 401, 403, 404, 429, 503] {
            MockProtocol.status = code
            MockProtocol.reply = ["error": ["message": "test-secret must never appear"]]
            do { _ = try await GeminiClient.request(key: "test-secret", contents: [], session: session); fatalError("accepted HTTP error") }
            catch { precondition(!error.localizedDescription.contains("test-secret")) }
        }
        for fixture: [String: Any] in [[:], ["promptFeedback": ["blockReason": "SAFETY"]], ["candidates": [["finishReason": "MAX_TOKENS", "content": modelContent]]]] {
            do { _ = try GeminiClient.content(fixture); fatalError("accepted incomplete response") } catch {}
        }
        print("PASS: request schema, Korean arguments, complete function-call/signature preservation, credential handling, HTTP failures, blocked/truncated responses")
    }
}
