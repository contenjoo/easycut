import Foundation

enum VideoGenerationAccess: String, Codable, CaseIterable, Identifiable {
    case subscription, api
    var id: String { rawValue }
}

enum VideoGenerationProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case openAI = "openai"
    case gemini

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "GPT"
        case .gemini: return "Gemini"
        }
    }
    var supportsSubscription: Bool { self != .gemini }
    var defaultAccess: VideoGenerationAccess { supportsSubscription ? .subscription : .api }
    var defaultModel: String {
        switch self {
        case .claude: return "claude-opus-5-5"
        case .openAI: return "gpt-6.1-sol"
        case .gemini: return "gemini-3.8-flash"
        }
    }
    var defaultSubscriptionModel: String { self == .openAI ? "codex-default" : defaultModel }
    var keychainService: String? {
        switch self {
        case .claude: return Keychain.service
        case .openAI: return "com.contenjoo.easycut.openai"
        case .gemini: return GeminiClient.keychainService
        }
    }
}

/// Calls only the providers' fixed text-generation endpoints. The returned JSON
/// text is still checked by the generation source/skill contract before use.
enum VideoGenerationAPI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let responseLimit = 2 * 1024 * 1024
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func buildRequest(provider: VideoGenerationProvider, model: String, key: String,
                             prompt: String, maxOutputTokens: Int) throws -> URLRequest {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.range(of: #"^[A-Za-z0-9._-]{1,120}$"#, options: .regularExpression) != nil else {
            throw Failure(message: "모델 이름에는 영문·숫자·마침표·밑줄·하이픈을 사용할 수 있습니다.")
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw Failure(message: "API 키를 확인해 주세요. 키 안에는 공백이나 줄바꿈이 들어갈 수 없습니다.")
        }
        guard maxOutputTokens > 0, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "영상 생성 요청과 응답 길이를 확인해 주세요.")
        }
        let endpoint: URL
        let body: [String: Any]
        switch provider {
        case .claude:
            endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
            body = ["model": model, "max_tokens": maxOutputTokens,
                    "messages": [["role": "user", "content": prompt]]]
        case .openAI:
            endpoint = URL(string: "https://api.openai.com/v1/responses")!
            var payload: [String: Any] = ["model": model, "input": prompt, "max_output_tokens": maxOutputTokens,
                    "store": false, "text": ["format": ["type": "json_object"]]]
            if model.hasPrefix("gpt-6") { payload["reasoning"] = ["effort": "low"] }
            body = payload
        case .gemini:
            endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
            body = ["contents": [["role": "user", "parts": [["text": prompt]]]],
                    "generationConfig": ["maxOutputTokens": maxOutputTokens, "responseMimeType": "application/json"]]
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch provider {
        case .claude:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func request(provider: VideoGenerationProvider, model: String, key: String, prompt: String,
                        maxOutputTokens: Int, session: URLSession = defaultSession) async throws -> String {
        try Task.checkCancellation()
        let request = try buildRequest(provider: provider, model: model, key: key, prompt: prompt, maxOutputTokens: maxOutputTokens)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else {
                throw Failure(message: "AI 서버의 응답을 확인하지 못했습니다. 다시 시도해 주세요.")
            }
            guard response.statusCode == 200 else { throw Failure(message: errorMessage(provider: provider, code: response.statusCode)) }
            guard response.expectedContentLength <= Int64(responseLimit) else {
                throw Failure(message: "AI 응답이 2MB를 초과했습니다. 영상 설명을 줄여 다시 시도해 주세요.")
            }
            var data = Data()
            data.reserveCapacity(min(responseLimit, max(0, Int(response.expectedContentLength))))
            return try await withTaskCancellationHandler {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < responseLimit else {
                        throw Failure(message: "AI 응답이 2MB를 초과했습니다. 영상 설명을 줄여 다시 시도해 주세요.")
                    }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return try decodeResponse(data, provider: provider)
            } onCancel: {
                bytes.task.cancel()
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let failure = error as? Failure { throw failure }
            if (error as? URLError)?.code == .timedOut {
                throw Failure(message: "AI 응답 시간이 초과되었습니다. 설명을 줄여 다시 시도해 주세요.")
            }
            // Never surface raw transport errors or response bodies: they may
            // contain provider diagnostics or request details.
            throw Failure(message: "AI 서버에 연결하지 못했습니다. 인터넷 연결을 확인하고 다시 시도해 주세요.")
        }
    }

    static func decodeResponse(_ data: Data, provider: VideoGenerationProvider) throws -> String {
        guard data.count <= responseLimit else {
            throw Failure(message: "AI 응답이 2MB를 초과했습니다. 영상 설명을 줄여 다시 시도해 주세요.")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure(message: "AI 응답을 읽지 못했습니다. 미리보기를 다시 생성해 주세요.")
        }
        let text: String
        switch provider {
        case .claude:
            guard object["type"] as? String == "message",
                  let stop = object["stop_reason"] as? String, ["end_turn", "stop_sequence"].contains(stop) else {
                throw Failure(message: "Claude 응답이 완성되지 않았습니다. 설명을 줄이거나 다른 모델로 다시 시도해 주세요.")
            }
            let contents = object["content"] as? [[String: Any]] ?? []
            guard !contents.contains(where: { $0["type"] as? String == "refusal" }) else {
                throw Failure(message: "Claude가 이 요청을 처리하지 못했습니다. 영상 설명을 바꿔 다시 시도해 주세요.")
            }
            text = contents.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .openAI:
            guard object["status"] as? String == "completed" else {
                throw Failure(message: "GPT 응답이 완성되지 않았습니다. 설명을 줄이거나 다른 모델로 다시 시도해 주세요.")
            }
            let contents = (object["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            guard !contents.contains(where: { $0["type"] as? String == "refusal" }) else {
                throw Failure(message: "GPT가 이 요청을 처리하지 못했습니다. 영상 설명을 바꿔 다시 시도해 주세요.")
            }
            text = contents.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            guard (object["promptFeedback"] as? [String: Any])?["blockReason"] == nil,
                  let candidate = (object["candidates"] as? [[String: Any]])?.first else {
                throw Failure(message: "Gemini가 이 요청을 처리하지 못했습니다. 영상 설명을 바꿔 다시 시도해 주세요.")
            }
            guard candidate["finishReason"] as? String == "STOP" else {
                if candidate["finishReason"] as? String == "MAX_TOKENS" {
                    throw Failure(message: "Gemini 응답이 길어 중단됐습니다. 설명을 줄이거나 다른 모델로 다시 시도해 주세요.")
                }
                throw Failure(message: "Gemini 응답이 완성되지 않았습니다. 영상 설명을 확인하고 다시 시도해 주세요.")
            }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw Failure(message: "AI가 영상 코드를 반환하지 않았습니다. 미리보기를 다시 생성해 주세요.")
        }
        return result
    }

    static func errorMessage(provider: VideoGenerationProvider, code: Int) -> String {
        let name = provider.title
        switch code {
        case 400: return "\(name) 모델과 요청 설정을 확인해 주세요. 지원하는 모델 이름으로 다시 시도할 수 있습니다."
        case 401: return "\(name) API 키가 올바르지 않거나 만료됐습니다. 새 키로 다시 연결해 주세요."
        case 403: return "이 키로 \(name) 모델을 사용할 수 없습니다. 계정과 프로젝트의 API 권한을 확인해 주세요."
        case 404: return "\(name) 모델을 찾을 수 없습니다. 사용할 수 있는 모델 이름을 입력해 주세요."
        case 429: return "\(name) 사용량 한도에 도달했습니다. 계정의 한도를 확인하거나 잠시 후 다시 시도해 주세요."
        case 500...599: return "\(name) 서버가 혼잡합니다. 잠시 후 다시 시도해 주세요."
        default: return "\(name) 연결에 실패했습니다 (HTTP \(code)). 다시 시도해 주세요."
        }
    }
}
