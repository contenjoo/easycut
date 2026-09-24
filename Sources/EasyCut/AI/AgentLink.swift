import AppKit

/// Claude Code · Codex(ChatGPT) CLI를 버튼 하나로 설치·로그인해 AI 편집에 연결한다 (터미널 없이).
@MainActor
final class AgentLink: ObservableObject {
    static let shared = AgentLink()

    enum Provider: String { case claude, codex }

    enum State: Equatable {
        case unknown
        case notInstalled
        case loggedOut
        case working(String)
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
        var isWorking: Bool { if case .working = self { return true } else { return false } }
    }

    @Published var claude: State = .unknown
    @Published var codex: State = .unknown
    /// 로그인 중 CLI가 알려 준 로그인 주소 (브라우저가 안 열렸을 때 다시 열기용)
    @Published var loginURL: URL?

    private var loginProcess: Process?

    // MARK: 실행 환경

    /// 로그인 정보(키체인·~/.claude·~/.codex)를 쓰도록 사용자 환경 일부만 넘긴다
    nonisolated static var environment: [String: String] {
        let parent = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = ["\(home)/.local/bin", Tools.userDir.path, "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
        // npm으로 설치한 codex는 node가 필요하다
        if let nodes = try? FileManager.default.contentsOfDirectory(atPath: "/opt/homebrew/opt") {
            path += nodes.filter { $0.hasPrefix("node") }.map { "/opt/homebrew/opt/\($0)/bin" }
        }
        path += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var env: [String: String] = [
            "HOME": home,
            "PATH": path.joined(separator: ":"),
            "LANG": "ko_KR.UTF-8",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
        ]
        for k in ["TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"] { env[k] = parent[k] }
        return env
    }

    /// 명령 실행 (출력은 stdout+stderr 합쳐서)
    nonisolated static func run(_ bin: String, _ args: [String], stdin: String? = nil, timeout: Double = 120) async -> (Int32, String) {
        await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.environment = environment
            p.currentDirectoryURL = AppPaths.temp
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = inp
            final class Once: @unchecked Sendable { var done = false; let lock = NSLock() }
            let once = Once()
            let finish: @Sendable (Int32, String) -> Void = { code, text in
                once.lock.lock(); defer { once.lock.unlock() }
                guard !once.done else { return }
                once.done = true
                c.resume(returning: (code, text))
            }
            p.terminationHandler = { proc in
                let d = out.fileHandleForReading.readDataToEndOfFile()
                finish(proc.terminationStatus, String(decoding: d, as: UTF8.self))
            }
            do {
                try p.run()
                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.terminate(); finish(-2, "시간이 초과되었습니다.") }
                }
            } catch {
                finish(-1, error.localizedDescription)
            }
        }
    }

    // MARK: Claude Code

    nonisolated static var claudeBinary: String? { AIAssistant.claudeBinary }

    nonisolated static func claudeLoggedIn() async -> Bool {
        guard let bin = claudeBinary else { return false }
        let (code, out) = await run(bin, ["auth", "status", "--json"], timeout: 30)
        guard code == 0, let start = out.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] else { return false }
        return obj["loggedIn"] as? Bool ?? false
    }

    // MARK: Codex (ChatGPT)

    nonisolated static var codexBinary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [Tools.userDir.appendingPathComponent("codex").path, "\(home)/.local/bin/codex",
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.npm-global/bin/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func codexLoggedIn() async -> Bool {
        guard let bin = codexBinary else { return false }
        let (code, out) = await run(bin, ["login", "status"], timeout: 30)
        return code == 0 && out.lowercased().contains("logged in")
    }

    /// 한글 경로가 명령 인자로 넘어가면 깨지므로(자모 분해) 앱 실행 파일을 가리키는 영문 경로 링크를 만든다
    nonisolated static var mcpCommandPath: String {
        let link = AppPaths.support.appendingPathComponent("easycut-mcp")
        let target = Bundle.main.executableURL?.path ?? "/Applications/EasyCut.app/Contents/MacOS/EasyCut"
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != target {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
        return link.path
    }

    // MARK: 상태

    func refresh() async {
        claude = Self.claudeBinary == nil ? .notInstalled : (await Self.claudeLoggedIn() ? .ready : .loggedOut)
        codex = Self.codexBinary == nil ? .notInstalled : (await Self.codexLoggedIn() ? .ready : .loggedOut)
    }

    func state(_ p: Provider) -> State { p == .claude ? claude : codex }

    private func set(_ p: Provider, _ s: State) {
        if p == .claude { claude = s } else { codex = s }
    }

    // MARK: 원클릭 연결

    /// 설치 → 브라우저 로그인 → 로그인 확인까지 한 번에. 성공하면 true
    @discardableResult
    func connect(_ p: Provider) async -> Bool {
        guard !state(p).isWorking else { return false }
        do {
            if (p == .claude ? Self.claudeBinary : Self.codexBinary) == nil {
                set(p, .working(p == .claude ? "Claude Code 설치 중…" : "Codex 설치 중…"))
                try await (p == .claude ? Self.installClaude() : Self.installCodex())
            }
            if await (p == .claude ? Self.claudeLoggedIn() : Self.codexLoggedIn()) {
                set(p, .ready)
                return true
            }
            set(p, .working("브라우저에서 로그인을 마쳐 주세요…"))
            try await login(p)
            set(p, .ready)
            return true
        } catch {
            set(p, .failed(error.localizedDescription))
            return false
        }
    }

    func cancelLogin() {
        loginProcess?.terminate()
        loginProcess = nil
    }

    /// OpenAI API 키로 Codex 로그인
    func connectCodexWithKey(_ key: String) async -> Bool {
        do {
            if Self.codexBinary == nil {
                codex = .working("Codex 설치 중…")
                try await Self.installCodex()
            }
            guard let bin = Self.codexBinary else { throw MediaError.failed("Codex를 설치하지 못했습니다.") }
            codex = .working("API 키 확인 중…")
            let (code, out) = await Self.run(bin, ["login", "--with-api-key"], stdin: key.trimmingCharacters(in: .whitespacesAndNewlines), timeout: 60)
            guard code == 0 else { throw MediaError.failed("API 키로 로그인하지 못했습니다: \(out.suffix(200))") }
            codex = await Self.codexLoggedIn() ? .ready : .failed("API 키로 로그인하지 못했습니다.")
            return codex.isReady
        } catch {
            codex = .failed(error.localizedDescription)
            return false
        }
    }

    /// 로그인 명령을 띄우고(브라우저가 열림) 로그인될 때까지 기다린다 (최대 5분)
    private func login(_ p: Provider) async throws {
        guard let bin = p == .claude ? Self.claudeBinary : Self.codexBinary else { throw MediaError.failed("설치를 확인할 수 없습니다.") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = p == .claude ? ["auth", "login", "--claudeai"] : ["login"]
        proc.environment = Self.environment
        proc.currentDirectoryURL = AppPaths.temp
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = Pipe()
        // CLI가 브라우저를 연다. 출력에 나온 주소는 [브라우저 다시 열기]용으로 보관
        loginURL = nil
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard let r = s.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression), let u = URL(string: String(s[r])) else { return }
            Task { @MainActor in if self?.loginURL == nil { self?.loginURL = u } }
        }
        try proc.run()
        loginProcess = proc
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            if proc.isRunning { proc.terminate() }
            loginProcess = nil
            loginURL = nil
        }
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if await (p == .claude ? Self.claudeLoggedIn() : Self.codexLoggedIn()) { return }
            if !proc.isRunning, proc.terminationStatus != 0 {
                throw MediaError.failed("로그인을 마치지 못했습니다. 다시 눌러 주세요.")
            }
            if loginProcess == nil { throw MediaError.failed("로그인을 취소했습니다.") }
        }
        throw MediaError.failed("로그인 시간이 초과되었습니다. 다시 눌러 주세요.")
    }

    // MARK: 설치

    /// Claude Code 공식 설치 스크립트 (claude.ai/install.sh)
    nonisolated static func installClaude() async throws {
        let (code, out) = await run("/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"], timeout: 600)
        guard code == 0, claudeBinary != nil else {
            throw MediaError.failed("Claude Code를 설치하지 못했습니다. 인터넷 연결을 확인하세요.\n\(out.suffix(200))")
        }
    }

    /// Codex 공식 배포본(GitHub openai/codex)을 받아 앱 전용 폴더에 설치
    nonisolated static func installCodex() async throws {
        let url = URL(string: "https://github.com/openai/codex/releases/latest/download/codex-aarch64-apple-darwin.tar.gz")!
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.failed("Codex를 받지 못했습니다.") }
        let work = AppPaths.temp.appendingPathComponent("codex-install", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (code, out) = await run("/usr/bin/tar", ["-xzf", tmp.path, "-C", work.path], timeout: 120)
        guard code == 0 else { throw MediaError.failed("Codex 압축을 풀지 못했습니다: \(out.suffix(200))") }
        let files = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        guard let bin = files.first(where: { $0.lastPathComponent.hasPrefix("codex") }) else { throw MediaError.failed("받은 파일에 Codex가 없습니다.") }
        let dest = Tools.userDir.appendingPathComponent("codex")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: bin, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        removexattr(dest.path, "com.apple.quarantine", 0)
        try? FileManager.default.removeItem(at: work)
    }
}
