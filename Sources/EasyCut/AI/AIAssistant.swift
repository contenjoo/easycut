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
    enum Role { case user, assistant, tool, error, thinking }
    let id = UUID()
    let role: Role
    var text: String
}

/// 고를 수 있는 Claude 모델
struct AIModel: Identifiable, Hashable {
    let id: String      // 모델 ID ("" = 계정 기본값, 플랜 방식에서만)
    let name: String
    let note: String
    var supportsEffort: Bool { id != "claude-haiku-4-5" }
    /// 거절 시 서버 자동 대체(fallbacks)를 쓰는 모델
    var usesFallback: Bool { ["claude-opus-5", "claude-opus-5-5", "claude-fable-5-1"].contains(id) }

    static let planDefault = AIModel(id: "", name: "계정 기본값", note: "Claude Code에 설정된 모델")
    static let all: [AIModel] = [
        .init(id: "claude-fable-5-1", name: "Claude Fable 5.1", note: "가장 뛰어남 · 느리고 사용량 많음"),
        .init(id: "claude-opus-5-5", name: "Claude Opus 5.5", note: "최신 Opus"),
        .init(id: "claude-opus-5", name: "Claude Opus 5", note: "균형 · 추천"),
        .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", note: "빠름 · 사용량 적음"),
        .init(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", note: "가장 빠름 · 간단한 편집"),
    ]
}

enum AIEffort: String, CaseIterable, Identifiable {
    case auto = "", low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "자동 (모델 기본)"
        case .low: return "낮음 · 빠름"
        case .medium: return "보통"
        case .high: return "높음"
        case .xhigh: return "매우 높음"
        case .max: return "최대 · 가장 깊게"
        }
    }
}

enum AIBackend: String, CaseIterable, Identifiable {
    case plan = "Claude 플랜 (Pro/Max 로그인)"
    case api = "API 키"
    var id: String { rawValue }
}

/// 앱 안의 AI 편집 도우미: Claude가 편집 도구(AITools)를 호출해 타임라인을 직접 고친다.
@MainActor
final class AIAssistant: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var busy = false
    @Published var hasKey = Keychain.load() != nil
    @Published var status = ""
    @Published var needsLogin = false
    @Published var backend: AIBackend = AIBackend(rawValue: UserDefaults.standard.string(forKey: "aiBackend") ?? "") ?? .plan {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "aiBackend"); reset() }
    }

    /// 선택한 모델 ("" = 플랜 기본값)
    @Published var modelID: String = UserDefaults.standard.string(forKey: "aiModel") ?? "" {
        didSet { UserDefaults.standard.set(modelID, forKey: "aiModel"); if oldValue != modelID { reset() } }
    }
    @Published var effort: AIEffort = AIEffort(rawValue: UserDefaults.standard.string(forKey: "aiEffort") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(effort.rawValue, forKey: "aiEffort") }
    }
    /// Claude가 어떻게 생각했는지 요약을 대화에 보여 준다
    @Published var showThinking: Bool = UserDefaults.standard.bool(forKey: "aiShowThinking") {
        didSet { UserDefaults.standard.set(showThinking, forKey: "aiShowThinking") }
    }

    /// API 방식에서 실제로 쓸 모델
    var apiModel: AIModel { AIModel.all.first { $0.id == modelID } ?? AIModel.all[2] }
    var currentModelName: String {
        if backend == .plan && modelID.isEmpty { return "계정 기본 모델" }
        return (AIModel.all.first { $0.id == modelID } ?? AIModel.all[2]).name
    }

    private var process: Process?
    private var planSession: String?

    /// 설치된 Claude Code CLI (플랜 로그인으로 동작)
    nonisolated static var claudeBinary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var ready: Bool { backend == .plan ? Self.claudeBinary != nil : hasKey }
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
        process?.terminate()
        process = nil
        planSession = nil
        messages = []
        items = []
        busy = false
        status = ""
    }

    func cancel() {
        task?.cancel()
        process?.terminate()
        busy = false
        status = "중지됨"
    }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        if backend == .plan { sendPlan(t); return }
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

    // MARK: Claude 플랜 (Claude Code CLI 경유)

    private func sendPlan(_ text: String) {
        guard let bin = Self.claudeBinary else {
            items.append(ChatItem(role: .error, text: "Claude Code가 설치되어 있지 않습니다. claude.com/claude-code 에서 설치 후 로그인하세요."))
            return
        }
        items.append(ChatItem(role: .user, text: text))
        busy = true
        needsLogin = false
        status = "Claude에 연결 중…"

        let appBin = Bundle.main.executableURL?.path ?? "/Applications/EasyCut.app/Contents/MacOS/EasyCut"
        let work = AppPaths.support.appendingPathComponent("ai-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // 한글이 명령 인자로 넘어가면 자모로 분해되므로(파일시스템 표기) 프롬프트는 stdin, 나머지는 파일로 전달한다
        let mcp: [String: Any] = ["mcpServers": ["easycut": ["command": appBin, "args": ["--mcp"]]]]
        let mcpFile = work.appendingPathComponent("mcp.json")
        let sysFile = work.appendingPathComponent("system.txt")
        try? JSONSerialization.data(withJSONObject: mcp).write(to: mcpFile)
        try? (Self.system + "\n편집 도구 이름은 mcp__easycut__ 로 시작합니다. 이 앱 편집 외의 작업(파일 수정, 명령 실행)은 하지 않습니다.")
            .write(to: sysFile, atomically: true, encoding: .utf8)
        var args = ["-p",
                    "--output-format", "stream-json", "--verbose",
                    "--tools", "",
                    // 사용자의 개인 Claude Code 설정(플러그인·훅)은 앱 AI에 섞지 않는다
                    "--setting-sources", "project",
                    "--strict-mcp-config", "--mcp-config", mcpFile.path,
                    "--allowedTools", "mcp__easycut",
                    "--append-system-prompt-file", sysFile.path]
        if !modelID.isEmpty { args += ["--model", modelID] }
        if effort != .auto, (AIModel.all.first { $0.id == modelID }?.supportsEffort ?? true) { args += ["--effort", effort.rawValue] }
        if let sid = planSession { args += ["--resume", sid] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.currentDirectoryURL = work
        // 사용자 플랜 로그인만 쓰도록 최소 환경으로 실행 (API 키·다른 Claude 세션 변수가 섞이지 않게)
        let parent = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env: [String: String] = [
            "HOME": home,
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "ko_KR.UTF-8",
            "SHELL": "/bin/zsh",
        ]
        for k in ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"] { env[k] = parent[k] }
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        let logURL = work.appendingPathComponent("last-run.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        final class LineBuffer: @unchecked Sendable { var data = Data() }
        let buf = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            log?.write(chunk)
            buf.data.append(chunk)
            while let nl = buf.data.firstIndex(of: 0x0A) {
                let line = buf.data[..<nl]
                buf.data.removeSubrange(...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                Task { @MainActor in self?.handlePlanEvent(obj) }
            }
        }
        let errBuf = LineBuffer()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            errBuf.data.append(d)
            log?.write(d)
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                if proc.terminationStatus != 0 && proc.terminationReason != .uncaughtSignal && self.busy {
                    let msg = String(decoding: errBuf.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !msg.isEmpty { self.report(msg) }
                }
                self.busy = false
                self.status = ""
                self.process = nil
            }
        }
        do {
            try p.run()
            inp.fileHandleForWriting.write(Data(text.utf8))
            try? inp.fileHandleForWriting.close()
            process = p
        } catch {
            busy = false
            items.append(ChatItem(role: .error, text: "Claude Code 실행 실패: \(error.localizedDescription)"))
        }
    }

    private var lastAssistantText = ""

    private func handlePlanEvent(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "system":
            if let sid = e["session_id"] as? String { planSession = sid }
            status = "생각 중…"
        case "assistant":
            let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for b in content {
                switch b["type"] as? String {
                case "thinking":
                    let t = (b["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if showThinking && !t.isEmpty { items.append(ChatItem(role: .thinking, text: t)) }
                case "text":
                    let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    if Self.isAuthError(t) { report(t); continue }
                    lastAssistantText = t
                    items.append(ChatItem(role: .assistant, text: t))
                case "tool_use":
                    let name = (b["name"] as? String ?? "").replacingOccurrences(of: "mcp__easycut__", with: "")
                    status = "실행: \(Self.label(name))"
                    if !name.hasPrefix("get_") { items.append(ChatItem(role: .tool, text: Self.label(name))) }
                default: break
                }
            }
        case "user":
            status = "생각 중…"
        case "result":
            if let sid = e["session_id"] as? String { planSession = sid }
            let text = (e["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if (e["is_error"] as? Bool) == true {
                let dupAuth = Self.isAuthError(text) && needsLogin
                if !dupAuth && text != lastAssistantText { report(text.isEmpty ? "Claude 오류" : text) }
            } else if !text.isEmpty && text != lastAssistantText {
                items.append(ChatItem(role: .assistant, text: text))
            }
            busy = false
            status = ""
        default:
            break
        }
    }

    nonisolated static func isAuthError(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.contains("authenticate") || l.contains("oauth") || l.contains("/login") || l.contains("not logged in") || l.contains("invalid api key")
    }

    private func report(_ t: String) {
        if Self.isAuthError(t) {
            needsLogin = true
            items.append(ChatItem(role: .error, text: "Claude 로그인이 필요합니다. 터미널에서 claude 를 실행하고 /login 으로 Pro/Max 계정에 로그인한 뒤 다시 시도하세요."))
            planSession = nil
        } else {
            items.append(ChatItem(role: .error, text: t))
        }
    }

    // MARK: API 키 경로

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
            for block in content {
                switch block["type"] as? String {
                case "thinking":
                    if showThinking, let t = block["thinking"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(ChatItem(role: .thinking, text: t))
                    }
                case "text":
                    if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(ChatItem(role: .assistant, text: t))
                    }
                default: break
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
        let m = apiModel
        var body: [String: Any] = [
            "model": m.id,
            "max_tokens": 16000,
            "cache_control": ["type": "ephemeral"],
            "system": Self.system,
            "tools": AITools.definitions,
            "messages": messages,
        ]
        if m.supportsEffort {
            // 적응형 사고 (생각 과정 요약을 보려면 summarized)
            body["thinking"] = showThinking ? ["type": "adaptive", "display": "summarized"] : ["type": "adaptive"]
            if effort != .auto { body["output_config"] = ["effort": effort.rawValue] }
        } else if showThinking {
            body["thinking"] = ["type": "enabled", "budget_tokens": 4000]
        }
        if m.usesFallback {
            // 안전 분류기가 거절하면 서버가 권장 모델로 자동 재시도
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
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
