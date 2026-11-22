import Foundation

/// Native Gemini API. Keys are sent only in a header; never in URLs or logs.
enum GeminiClient {
    static let keychainService = "com.contenjoo.easycut.gemini"
    static let model = "gemini-2.5-flash-lite"
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func body(contents: [[String: Any]], system: String?, tools: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = ["contents": contents, "generationConfig": ["maxOutputTokens": 8192]]
        if let system { body["systemInstruction"] = ["parts": [["text": system]]] }
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map { tool -> [String: Any] in
                var declaration: [String: Any] = ["name": tool["name"] ?? "", "description": tool["description"] ?? ""]
                if let schema = tool["input_schema"] as? [String: Any],
                   let properties = schema["properties"] as? [String: Any], !properties.isEmpty {
                    declaration["parameters"] = schema
                }
                return declaration
            }]]
        }
        return body
    }

    static func request(key: String, contents: [[String: Any]], system: String? = nil,
                        tools: [[String: Any]] = [], session: URLSession = .shared) async throws -> [String: Any] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(contents: contents, system: system, tools: tools))
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure(message: errorMessage(code: code)) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Gemini 응답을 읽지 못했습니다. 다시 시도해 주세요.")
        }
        _ = try content(object)
        return object
    }

    static func errorMessage(code: Int) -> String {
        switch code {
        case 400, 401: return "Gemini 키 또는 요청을 확인해 주세요. 새 키를 발급해 다시 연결할 수 있습니다."
        case 403: return "이 키로 Gemini를 사용할 수 없습니다. Google AI Studio에서 프로젝트 권한과 지원 지역을 확인해 주세요."
        case 404: return "Gemini 모델을 사용할 수 없습니다. EasyCut 업데이트를 확인해 주세요."
        case 429: return "Gemini 사용량 한도에 도달했습니다. 잠시 후 다시 시도하거나 Google AI Studio에서 무료 한도를 확인해 주세요. 유료로 자동 전환하지 않습니다."
        case 500...599: return "Gemini 서버가 혼잡합니다. 잠시 후 다시 시도해 주세요."
        default: return "Gemini 연결에 실패했습니다 (HTTP \(code)). 다시 시도해 주세요."
        }
    }

    static func content(_ response: [String: Any]) throws -> [String: Any] {
        guard let candidate = (response["candidates"] as? [[String: Any]])?.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]], !parts.isEmpty else {
            throw Failure(message: "Gemini가 응답하지 못했습니다. 요청을 바꿔 다시 시도해 주세요.")
        }
        let finish = candidate["finishReason"] as? String ?? "STOP"
        guard finish == "STOP" else {
            throw Failure(message: finish == "MAX_TOKENS" ? "Gemini 응답이 길어 중단됐습니다. 요청을 나눠 주세요." : "Gemini가 요청을 처리하지 못했습니다. 요청 내용을 확인해 주세요.")
        }
        return content
    }
}
