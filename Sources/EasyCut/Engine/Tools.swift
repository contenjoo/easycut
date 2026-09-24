import Foundation
import AppKit

/// 외부 도구 찾기: 앱에 내장된 것 → 앱이 받은 것 → Homebrew 순서
enum Tools {
    static var bundledDir: URL? { Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true) }

    static var userDir: URL {
        let d = AppPaths.support.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func find(_ name: String) -> String? {
        var candidates: [String] = []
        if let b = bundledDir { candidates.append(b.appendingPathComponent(name).path) }
        candidates += [userDir.appendingPathComponent(name).path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: yt-dlp (유튜브 받기) — 자주 바뀌므로 앱이 공식 배포본을 받아 쓴다

    static let ytdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// 공식 yt-dlp를 받아 설치하거나 최신으로 바꾼다
    static func installYtdlp(progress: @escaping (Double) -> Void) async throws -> String {
        let dest = userDir.appendingPathComponent("yt-dlp")
        let (tmp, resp) = try await URLSession.shared.download(from: ytdlpURL, delegate: nil)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.failed("yt-dlp를 받지 못했습니다.") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        removexattr(dest.path, "com.apple.quarantine", 0)
        progress(1)
        return version(of: dest.path) ?? "설치됨"
    }

    static func version(of bin: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 터미널에서 명령 실행 (.command 파일)

    /// 터미널 창을 열어 명령을 실행한다 (자동화 권한 없이)
    static func runInTerminal(_ script: String, name: String) {
        let url = AppPaths.temp.appendingPathComponent("\(name).command")
        let body = "#!/bin/zsh -l\nclear\n\(script)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}

/// Claude(Claude Code·Claude 데스크톱) 연결 도우미
enum ClaudeLink {
    static var appBinary: String { Bundle.main.executableURL?.path ?? "/Applications/EasyCut.app/Contents/MacOS/EasyCut" }

    static var desktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var desktopInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: desktopConfigURL.deletingLastPathComponent().path)
    }

    static var desktopConnected: Bool {
        guard let d = try? Data(contentsOf: desktopConfigURL),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any],
              let e = servers["easycut"] as? [String: Any] else { return false }
        return (e["command"] as? String) == appBinary
    }

    /// Claude 데스크톱 설정에 EasyCut 연결을 추가 (기존 설정은 백업 후 보존)
    static func connectDesktop() throws {
        let url = desktopConfigURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var obj: [String: Any] = [:]
        if let d = try? Data(contentsOf: url) {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw MediaError.failed("Claude 데스크톱 설정 파일을 읽을 수 없습니다. 직접 확인해 주세요:\n\(url.path)")
            }
            obj = o
            try? d.write(to: url.deletingPathExtension().appendingPathExtension("backup.json"))
        }
        var servers = obj["mcpServers"] as? [String: Any] ?? [:]
        servers["easycut"] = ["command": appBinary, "args": ["--mcp"]]
        obj["mcpServers"] = servers
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    /// Claude Code에 EasyCut 연결 (claude mcp add)
    static func connectCode() async throws {
        guard let bin = AIAssistant.claudeBinary else { throw MediaError.failed("Claude Code가 설치되어 있지 않습니다.") }
        _ = await run(bin, ["mcp", "remove", "-s", "user", "easycut"])
        let (code, out) = await run(bin, ["mcp", "add", "-s", "user", "easycut", "--", appBinary, "--mcp"])
        guard code == 0 else { throw MediaError.failed("연결 실패: \(out.suffix(300))") }
    }

    static var codeConnected: Bool {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let d = try? Data(contentsOf: f), let s = String(data: d, encoding: .utf8) else { return false }
        return s.contains("\"easycut\"") && s.contains(appBinary)
    }

    /// Codex에 EasyCut 연결 (codex mcp add)
    static func connectCodex() async throws {
        guard let bin = AgentLink.codexBinary else { throw MediaError.failed("Codex가 설치되어 있지 않습니다.") }
        _ = await AgentLink.run(bin, ["mcp", "remove", "easycut"])
        let (code, out) = await AgentLink.run(bin, ["mcp", "add", "easycut", "--", appBinary, "--mcp"])
        guard code == 0 else { throw MediaError.failed("연결 실패: \(out.suffix(300))") }
    }

    static var codexConnected: Bool {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let s = try? String(contentsOf: f, encoding: .utf8) else { return false }
        return s.contains("[mcp_servers.easycut]") && s.contains(appBinary)
    }

    static func run(_ bin: String, _ args: [String], stdin: String? = nil) async -> (Int32, String) {
        await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            p.environment = ["HOME": home, "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                             "USER": NSUserName(), "LANG": "ko_KR.UTF-8"]
            p.currentDirectoryURL = AppPaths.temp
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = inp
            p.terminationHandler = { proc in
                let d = out.fileHandleForReading.readDataToEndOfFile()
                c.resume(returning: (proc.terminationStatus, String(decoding: d, as: UTF8.self)))
            }
            do {
                try p.run()
                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()
            } catch {
                c.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
