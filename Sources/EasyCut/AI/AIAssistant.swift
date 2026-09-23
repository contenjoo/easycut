import Foundation
import Security

/// API 키를 macOS 키체인에 보관
enum Keychain {
    static let service = "com.contenjoo.easycut.anthropic"

    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

struct ChatItem: Identifiable, Equatable {
    enum Role { case user, assistant, tool, error }
    let id = UUID()
    let role: Role
    var text: String
}

/// 앱 안의 AI 편집 도우미: Claude가 편집 도구(AITools)를 호출해 타임라인을 직접 고친다.
@MainActor
final class AIAssistant: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var busy = false
    @Published var hasKey = Keychain.load() != nil
    @Published var status = ""

    static let model = "claude-opus-5"
    private var messages: [[String: Any]] = []
    private var task: Task<Void, Never>?
    unowned let store: EditorStore

    init(store: EditorStore) { self.store = store }

    static let system = """
    당신은 macOS 영상 편집 앱 EasyCut 안에서 일하는 편집 도우미입니다. 사용자의 한국어 요청을 도구 호출로 실제 편집에 반영합니다.

    작업 방식:
    - 편집하기 전에 get_project_state로 현재 구조를 확인하고, 말 내용과 관련된 요청이면 get_transcript로 대본을 봅니다.
    - 시간은 모두 타임라인 기준 초입니다. 대본의 [번호]는 삭제할 때마다 바뀌므로, 여러 구간을 지울 때는 delete_words에 한 번에 넣습니다.
    - "무음/공백 없애기"는 remove_silences, "음·어 같은 말 빼기"는 remove_fillers, 특정 말이나 구간을 지우는 요청은 delete_words 또는 delete_time_ranges를 씁니다.
    - 대본이 없는데 말 내용 기반 편집이 필요하면 transcribe를 먼저 실행합니다.
    - 모든 편집은 사용자가 ⌘Z로 되돌릴 수 있습니다. 요청이 분명하면 되묻지 말고 실행하고, 정말 모호할 때만 짧게 확인합니다.
    - 할 수 있는 도구가 없으면 추측하지 말고 할 수 없다고 말합니다.
    - 끝나면 무엇을 바꿨는지 한두 문장으로 간단히 한국어로 알려 줍니다.
    """

    func setKey(_ k: String) {
        Keychain.save(k.trimmingCharacters(in: .whitespacesAndNewlines))
        hasKey = Keychain.load() != nil
    }

    func reset() {
        task?.cancel()
        messages = []
        items = []
        busy = false
        status = ""
    }

    func cancel() {
        task?.cancel()
        busy = false
        status = "중지됨"
    }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        guard let key = Keychain.load() else {
            items.append(ChatItem(role: .error, text: "Claude API 키를 먼저 설정하세요."))
            return
        }
        items.append(ChatItem(role: .user, text: t))
        messages.append(["role": "user", "content": t])
        busy = true
        task = Task { [weak self] in
            await self?.loop(key: key)
            self?.busy = false
            self?.status = ""
        }
    }

    private func loop(key: String) async {
        for _ in 0..<25 {
            if Task.isCancelled { return }
            status = "생각 중…"
            let resp: [String: Any]
            do {
                resp = try await request(key: key)
            } catch {
                if !Task.isCancelled { items.append(ChatItem(role: .error, text: error.localizedDescription)) }
                // 실패한 요청의 마지막 user 메시지는 남겨 두면 다음 요청이 꼬이지 않도록 정리
                if let last = messages.last, (last["role"] as? String) == "user", last["content"] is String { messages.removeLast() }
                return
            }
            let stop = resp["stop_reason"] as? String ?? ""
            let content = resp["content"] as? [[String: Any]] ?? []
            if stop == "refusal" {
                let why = ((resp["stop_details"] as? [String: Any])?["explanation"] as? String) ?? ""
                items.append(ChatItem(role: .error, text: "요청이 거절되었습니다. \(why)"))
                messages.removeLast()
                return
            }
            // 사고 블록 포함 응답 전체를 그대로 대화에 이어 붙인다
            messages.append(["role": "assistant", "content": content])
            for block in content where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(ChatItem(role: .assistant, text: t))
                }
            }
            let uses = content.filter { ($0["type"] as? String) == "tool_use" }
            if stop == "max_tokens" && uses.isEmpty {
                items.append(ChatItem(role: .error, text: "응답이 너무 길어 중간에 끊겼습니다."))
                return
            }
            guard stop == "tool_use", !uses.isEmpty else { return }
            var results: [[String: Any]] = []
            for u in uses {
                let name = u["name"] as? String ?? ""
                let id = u["id"] as? String ?? ""
                let input = u["input"] as? [String: Any] ?? [:]
                status = "실행: \(Self.label(name))"
                let (out, isErr) = await AITools.execute(name, input, store: store)
                if !name.hasPrefix("get_") {
                    items.append(ChatItem(role: .tool, text: "\(Self.label(name)) — \(out.components(separatedBy: "\n").first ?? out)"))
                }
                var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": out]
                if isErr { r["is_error"] = true }
                results.append(r)
            }
            // 모든 결과를 한 메시지로 돌려준다
            messages.append(["role": "user", "content": results])
        }
        items.append(ChatItem(role: .error, text: "작업 단계가 너무 많아 멈췄습니다. 요청을 나눠 주세요."))
    }

    static func label(_ tool: String) -> String {
        [
            "delete_words": "말 삭제", "delete_time_ranges": "구간 삭제", "remove_silences": "무음 제거",
            "remove_fillers": "군더더기 제거", "split_at": "분할", "set_speed": "속도 변경",
            "set_clip_properties": "클립 속성", "delete_clips": "클립 삭제", "move_clip": "클립 이동",
            "add_text": "텍스트 추가", "generate_captions": "자막 생성", "edit_captions": "자막 편집",
            "set_caption_style": "자막 스타일", "set_canvas": "화면 크기", "set_playhead": "재생헤드 이동",
            "set_playback_speed": "재생 속도", "transcribe": "음성 인식", "undo": "되돌리기",
            "get_project_state": "상태 확인", "get_transcript": "대본 읽기",
        ][tool] ?? tool
    }

    private func request(key: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // 안전 분류기가 거절하면 서버가 권장 모델로 자동 재시도
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "fallbacks": "default",
            "cache_control": ["type": "ephemeral"],
            "system": Self.system,
            "tools": AITools.definitions,
            "messages": messages,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaError.failed("Claude 응답을 읽지 못했습니다 (HTTP \(code))")
        }
        guard code == 200 else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
            switch code {
            case 401: throw MediaError.failed("API 키가 올바르지 않습니다. AI 설정에서 다시 입력하세요.")
            case 429: throw MediaError.failed("요청이 너무 많습니다. 잠시 후 다시 시도하세요. (\(msg))")
            case 529, 500...599: throw MediaError.failed("Claude 서버가 혼잡합니다. 잠시 후 다시 시도하세요. (\(msg))")
            default: throw MediaError.failed("Claude 오류: \(msg)")
            }
        }
        return obj
    }
}
