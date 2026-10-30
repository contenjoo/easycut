import Foundation

extension SelfTest {
    /// Pure fixtures and an intercepting URLProtocol; never reads keys or contacts a provider.
    static func testVideoGenerationAPI(_ dir: URL) async throws {
        print("영상 생성: Claude·GPT·Gemini API 요청·응답·오류·취소")
        let fakeKey = "easycut-unit-test-not-a-real-key"
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) }
        func json(_ value: Any) throws -> String { String(decoding: try data(value), as: UTF8.self) }
        func rejects(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, label) } catch { check(true, label) }
        }
        func build(_ provider: VideoGenerationProvider, model: String? = nil, key: String? = nil) throws -> URLRequest {
            try VideoGenerationAPI.buildRequest(provider: provider, model: model ?? provider.defaultModel,
                key: key ?? fakeKey, prompt: "Return JSON for a test animation", maxOutputTokens: 512)
        }
        let legacy: [String: Any] = ["renderer": "canvas", "prompt": "호환성 검사", "duration": 2,
                                    "width": 640, "height": 640, "fps": 30]
        let legacyRequest = try JSONDecoder().decode(VideoGenerationRequest.self, from: data(legacy))
        check(legacyRequest.provider == .claude && legacyRequest.model == VideoGenerationProvider.claude.defaultModel,
              "기존 요청의 AI 공급자·모델은 Claude 기본값으로 호환")
        var explicit = legacy
        explicit["provider"] = "gemini"; explicit["model"] = "gemini-test-model"
        let explicitRequest = try JSONDecoder().decode(VideoGenerationRequest.self, from: data(explicit))
        let roundTrip = try JSONDecoder().decode(VideoGenerationRequest.self, from: JSONEncoder().encode(explicitRequest))
        check(explicitRequest.provider == .gemini && explicitRequest.model == "gemini-test-model" && roundTrip == explicitRequest,
              "선택한 API 공급자·모델을 요청 파일에 보존")
        check(VideoGenerationProvider.claude.defaultAccess == .subscription && VideoGenerationProvider.openAI.defaultAccess == .subscription &&
              VideoGenerationProvider.gemini.defaultAccess == .api && !VideoGenerationProvider.gemini.supportsSubscription &&
              VideoGenerationProvider.claude.keychainService == Keychain.service,
              "Claude·GPT는 구독 기본, Gemini는 API 기본이며 Claude API는 기존 키체인 서비스 재사용")

        let claude = try build(.claude)
        let claudeBody = try JSONSerialization.jsonObject(with: claude.httpBody!) as! [String: Any]
        check(claude.url?.absoluteString == "https://api.anthropic.com/v1/messages" && claude.httpMethod == "POST" &&
              claude.value(forHTTPHeaderField: "x-api-key") == fakeKey &&
              claude.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01",
              "Claude는 고정 Messages API와 인증·버전 헤더 사용")
        let claudeMessages = claudeBody["messages"] as? [[String: Any]]
        check(claudeBody["model"] as? String == VideoGenerationProvider.claude.defaultModel &&
              claudeBody["max_tokens"] as? Int == 512 && claudeMessages?.first?["role"] as? String == "user" &&
              claudeMessages?.first?["content"] as? String == "Return JSON for a test animation" && claudeBody["tools"] == nil,
              "Claude API는 선택 모델·토큰 한도·사용자 프롬프트만 전송하며 도구는 제공하지 않음")

        let openAI = try build(.openAI)
        let openAIBody = try JSONSerialization.jsonObject(with: openAI.httpBody!) as! [String: Any]
        let openAIFormat = (openAIBody["text"] as? [String: Any])?["format"] as? [String: Any]
        check(openAI.url?.absoluteString == "https://api.openai.com/v1/responses" && openAI.httpMethod == "POST" &&
              openAI.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)",
              "GPT는 고정 Responses API와 인증 헤더 사용")
        check(openAIBody["store"] as? Bool == false && openAIFormat?["type"] as? String == "json_object" &&
              openAIBody["model"] as? String == VideoGenerationProvider.openAI.defaultModel,
              "GPT 요청은 서버 저장을 끄고 JSON 응답과 선택 모델 사용")

        let gemini = try build(.gemini)
        let geminiBody = try JSONSerialization.jsonObject(with: gemini.httpBody!) as! [String: Any]
        let geminiConfig = geminiBody["generationConfig"] as? [String: Any]
        check(gemini.url?.host == "generativelanguage.googleapis.com" &&
              gemini.url?.path == "/v1beta/models/\(VideoGenerationProvider.gemini.defaultModel):generateContent" &&
              gemini.httpMethod == "POST" && gemini.value(forHTTPHeaderField: "x-goog-api-key") == fakeKey,
              "Gemini는 고정 생성 API와 인증 헤더 사용")
        check(geminiConfig?["responseMimeType"] as? String == "application/json" &&
              geminiConfig?["maxOutputTokens"] as? Int == 512,
              "Gemini 요청은 JSON 응답과 응답 길이 지정")
        check([claude, openAI, gemini].allSatisfy { request in
            !(request.url?.absoluteString.contains(fakeKey) ?? true) &&
            !String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(fakeKey) && request.url?.query == nil
        }, "API 키는 URL·쿼리·JSON 본문에 포함하지 않음")
        for provider in VideoGenerationProvider.allCases {
            rejects("\(provider.rawValue): 모델 이름의 경로·쿼리 주입 거절") {
                _ = try build(provider, model: "models/test?key=unexpected")
            }
            rejects("\(provider.rawValue): 모델 이름의 줄바꿈 거절") { _ = try build(provider, model: "test\nmodel") }
            rejects("\(provider.rawValue): API 키 안의 줄바꿈 거절") { _ = try build(provider, key: "unit\nkey") }
            rejects("\(provider.rawValue): 빈 API 키 거절") { _ = try build(provider, key: " ") }
        }
        let source = "function frame(i) { ctx.fillStyle='#000'; ctx.fillRect(0,0,W,H); }\nfunction audio(t) { return 0; }"
        let sourceJSON = try json(["title": "API 기술 검증", "source": source])
        func claudeResponse(_ text: String, stop: String = "end_turn") -> [String: Any] {
            ["type": "message", "role": "assistant", "stop_reason": stop, "content": [
                ["type": "thinking", "thinking": "internal thought", "text": "not final output"],
                ["type": "text", "text": text]
            ]]
        }
        func openAIResponse(_ text: String, status: String = "completed") -> [String: Any] {
            ["status": status, "output": [
                ["type": "reasoning", "content": [["type": "output_text", "text": "not final output"]]],
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]
            ]]
        }
        func geminiResponse(_ text: String, finish: String = "STOP") -> [String: Any] {
            ["candidates": [["finishReason": finish, "content": ["parts": [
                ["text": "internal thought must not be returned", "thought": true], ["text": text]
            ]]]]]
        }
        let claudeText = try VideoGenerationAPI.decodeResponse(data(claudeResponse(" \n" + sourceJSON + "\n")), provider: .claude)
        let openAIText = try VideoGenerationAPI.decodeResponse(data(openAIResponse(" \n" + sourceJSON + "\n")), provider: .openAI)
        let geminiText = try VideoGenerationAPI.decodeResponse(data(geminiResponse(sourceJSON)), provider: .gemini)
        check(claudeText == sourceJSON, "Claude의 thinking 블록을 제외하고 text 블록만 추출")
        check(try VideoGenerationAPI.decodeResponse(data(claudeResponse(sourceJSON, stop: "stop_sequence")), provider: .claude) == sourceJSON,
              "Claude stop_sequence로 완료한 응답 허용")
        check(openAIText == sourceJSON, "GPT의 추론 항목을 건너뛰고 최종 메시지 텍스트만 추출")
        check(geminiText == sourceJSON, "Gemini의 thought 부분을 제외하고 최종 텍스트만 추출")
        for (provider, text) in [(VideoGenerationProvider.claude, claudeText), (.openAI, openAIText), (.gemini, geminiText)] {
            let decoded = try GeneratedVideoSource.decode(text, renderer: .canvas)
            check(decoded.source == source && decoded.title == "API 기술 검증", "\(provider.rawValue): API 결과를 기존 영상 코드 계약으로 검사")
            let selectionJSON = try json(["skillIDs": ["visual-explainer"], "reason": "시각적 설명에 맞는 지침입니다."])
            let response = provider == .claude ? claudeResponse(selectionJSON) :
                (provider == .openAI ? openAIResponse(selectionJSON) : geminiResponse(selectionJSON))
            let selectionText = try VideoGenerationAPI.decodeResponse(data(response), provider: provider)
            check(try VideoSkillSelection.decode(selectionText).skills.map(\.id) == ["visual-explainer"],
                  "\(provider.rawValue): API 결과를 검토된 스킬 선택 계약으로 검사")
        }
        for stop in ["max_tokens", "tool_use", "pause_turn", "refusal"] {
            rejects("Claude: \(stop)로 중단된 응답 거절") {
                _ = try VideoGenerationAPI.decodeResponse(data(claudeResponse(sourceJSON, stop: stop)), provider: .claude)
            }
        }
        rejects("Claude: 거절 블록을 코드로 실행하지 않음") {
            _ = try VideoGenerationAPI.decodeResponse(data(["type": "message", "stop_reason": "end_turn", "content": [
                ["type": "refusal", "refusal": "cannot comply"]
            ]]), provider: .claude)
        }
        rejects("Claude: 빈 최종 텍스트 거절") {
            _ = try VideoGenerationAPI.decodeResponse(data(claudeResponse(" \n")), provider: .claude)
        }
        rejects("Claude: 오류 응답을 코드로 실행하지 않음") {
            _ = try VideoGenerationAPI.decodeResponse(data(["type": "error", "error": ["type": "api_error", "message": fakeKey]]), provider: .claude)
        }
        for status in ["incomplete", "failed", "in_progress"] {
            rejects("GPT: \(status) 응답은 실행 가능한 코드로 취급하지 않음") {
                _ = try VideoGenerationAPI.decodeResponse(data(openAIResponse(sourceJSON, status: status)), provider: .openAI)
            }
        }
        rejects("GPT: 거절 응답은 코드로 실행하지 않음") {
            _ = try VideoGenerationAPI.decodeResponse(data(["status": "completed", "output": [
                ["type": "message", "content": [["type": "refusal", "refusal": "cannot comply"]]]
            ]]), provider: .openAI)
        }
        rejects("GPT: 빈 최종 메시지 거절") {
            _ = try VideoGenerationAPI.decodeResponse(data(openAIResponse(" \n")), provider: .openAI)
        }
        for finish in ["MAX_TOKENS", "SAFETY", "OTHER"] {
            rejects("Gemini: \(finish)로 중단된 응답 거절") {
                _ = try VideoGenerationAPI.decodeResponse(data(geminiResponse(sourceJSON, finish: finish)), provider: .gemini)
            }
        }
        rejects("Gemini: 프롬프트 차단 응답 거절") {
            _ = try VideoGenerationAPI.decodeResponse(data(["promptFeedback": ["blockReason": "SAFETY"]]), provider: .gemini)
        }
        rejects("Gemini: 빈 최종 텍스트 거절") {
            _ = try VideoGenerationAPI.decodeResponse(data(geminiResponse("")), provider: .gemini)
        }
        rejects("API 응답의 2MB 상한 적용") {
            _ = try VideoGenerationAPI.decodeResponse(Data(repeating: 32, count: VideoGenerationAPI.responseLimit + 1), provider: .openAI)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoGenerationAPIStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for (provider, code) in [(VideoGenerationProvider.claude, 403), (.openAI, 401), (.gemini, 429)] {
            VideoGenerationAPIStub.configure(status: code, body: Data("server echoed \(fakeKey)".utf8))
            do {
                _ = try await VideoGenerationAPI.request(provider: provider, model: provider.defaultModel, key: fakeKey,
                    prompt: "Return JSON", maxOutputTokens: 512, session: session)
                check(false, "\(provider.rawValue): HTTP \(code) 오류 전달")
            } catch {
                check(error.localizedDescription == VideoGenerationAPI.errorMessage(provider: provider, code: code) &&
                      !error.localizedDescription.contains(fakeKey) && !error.localizedDescription.contains("server echoed"),
                      "\(provider.rawValue): HTTP \(code) 오류에서 키·서버 원문을 노출하지 않음")
            }
        }
        for provider in VideoGenerationProvider.allCases {
            let response = provider == .claude ? claudeResponse(sourceJSON) :
                (provider == .openAI ? openAIResponse(sourceJSON) : geminiResponse(sourceJSON))
            VideoGenerationAPIStub.configure(status: 200, body: try data(response))
            let fetched = try await VideoGenerationAPI.request(provider: provider, model: provider.defaultModel,
                key: fakeKey, prompt: "Return JSON", maxOutputTokens: 512, session: session)
            check(fetched == sourceJSON, "\(provider.rawValue): 외부 통신 없는 모의 HTTP 응답도 최종 코드 JSON까지 연결")
        }

        VideoGenerationAPIStub.configure(status: 200, headers: ["Content-Length": "\(VideoGenerationAPI.responseLimit + 1)"], body: Data())
        do {
            _ = try await VideoGenerationAPI.request(provider: .gemini, model: VideoGenerationProvider.gemini.defaultModel,
                key: fakeKey, prompt: "Return JSON", maxOutputTokens: 512, session: session)
            check(false, "HTTP 응답 길이 헤더의 2MB 상한 적용")
        } catch { check(error.localizedDescription.contains("2MB"), "HTTP 응답 길이 헤더의 2MB 상한 적용") }

        VideoGenerationAPIStub.configure(status: nil, body: Data())
        let previousStarts = VideoGenerationAPIStub.startCount
        let pending = Task {
            try await VideoGenerationAPI.request(provider: .openAI, model: VideoGenerationProvider.openAI.defaultModel,
                key: fakeKey, prompt: "Return JSON", maxOutputTokens: 512, session: session)
        }
        for _ in 0..<100 {
            if VideoGenerationAPIStub.startCount > previousStarts { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = VideoGenerationAPIStub.startCount > previousStarts
        pending.cancel()
        do { _ = try await pending.value; check(false, "진행 중 API 요청 취소 전파") }
        catch { check(started && error is CancellationError, "진행 중 API 요청 취소가 CancellationError로 전파") }
    }
}

/// Intercepts every request on the dedicated test session, including unexpected URLs.
private final class VideoGenerationAPIStub: URLProtocol {
    private static let lock = NSLock()
    private static var status: Int? = 200
    private static var headers: [String: String] = [:]
    private static var body = Data()
    private static var starts = 0

    static var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    static func configure(status: Int?, headers: [String: String] = [:], body: Data) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; self.headers = headers; self.body = body
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.starts += 1
        let status = Self.status, headers = Self.headers, body = Self.body
        Self.lock.unlock()
        guard let status else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
