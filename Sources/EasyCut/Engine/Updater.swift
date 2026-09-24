import AppKit

/// GitHub 릴리스에서 새 버전을 확인하고, 사용자가 원하면 받아서 앱을 바꾼 뒤 다시 실행한다.
@MainActor
enum Updater {
    nonisolated static let repo = "contenjoo/easycut"
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// 업데이트 설치를 위해 종료 중 (저장 확인 창을 띄우지 않는다)
    static private(set) var installing = false
    private static var busy = false

    struct Release {
        let version: String
        let notes: String
        let dmg: URL
        let page: URL
    }

    /// "1.10.0" > "1.9.2" 처럼 숫자 단위로 비교
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    nonisolated static func latest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tag = o["tag_name"] as? String,
              let assets = o["assets"] as? [[String: Any]],
              let dmgS = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true })?["browser_download_url"] as? String,
              let dmg = URL(string: dmgS) else { return nil }
        let page = (o["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repo)/releases/latest")!
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), notes: o["body"] as? String ?? "", dmg: dmg, page: page)
    }

    /// 앱을 켤 때 조용히 확인 (건너뛴 버전은 다시 묻지 않음)
    static func checkInBackground(store: EditorStore) {
        check(store: store, userInitiated: false)
    }

    static func check(store: EditorStore, userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            let rel: Release?
            do { rel = try await latest() } catch {
                if userInitiated { store.alert = "업데이트를 확인하지 못했습니다. 인터넷 연결을 확인하세요." }
                return
            }
            guard let rel, isNewer(rel.version, than: current) else {
                if userInitiated { store.alert = "최신 버전을 쓰고 있습니다. (EasyCut \(current))" }
                return
            }
            let skipped = UserDefaults.standard.string(forKey: "skippedUpdateVersion")
            if !userInitiated, skipped == rel.version { return }
            ask(rel, store: store)
        }
    }

    private static func ask(_ rel: Release, store: EditorStore) {
        let a = NSAlert()
        a.messageText = "새 버전이 나왔습니다: EasyCut \(rel.version)"
        // 릴리스 노트의 마크다운 기호는 빼고 보여 준다
        var notes = rel.notes.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        a.informativeText = "지금 쓰는 버전은 \(current)입니다. 지금 업데이트할까요?\n작업 중인 프로젝트는 저장한 뒤 앱이 다시 시작됩니다.\n\n\(notes)"
        a.addButton(withTitle: "업데이트")
        a.addButton(withTitle: "나중에")
        a.addButton(withTitle: "이 버전 건너뛰기")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            Task { await install(rel, store: store) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(rel.version, forKey: "skippedUpdateVersion")
        default:
            break
        }
    }

    // MARK: 설치

    private static func install(_ rel: Release, store: EditorStore) async {
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        // 설치 위치에 쓸 수 없거나(권한), DMG에서 바로 실행 중이면 DMG만 열어 준다
        guard FileManager.default.isWritableFile(atPath: parent.path),
              !appURL.path.contains("/AppTranslocation/"), !appURL.path.hasPrefix("/Volumes/") else {
            store.showToast("업데이트 파일을 받는 중…")
            if let dmg = try? await download(rel.dmg) { NSWorkspace.shared.open(dmg) }
            store.alert = "자동으로 바꿀 수 없는 위치에서 실행 중입니다.\n열린 창에서 EasyCut을 응용 프로그램 폴더로 끌어 놓아 바꿔 주세요."
            return
        }
        store.converting["업데이트 \(rel.version)"] = JobProgress(value: 0.1, message: "업데이트 받는 중…")
        defer { store.converting["업데이트 \(rel.version)"] = nil }
        do {
            let dmg = try await download(rel.dmg)
            store.converting["업데이트 \(rel.version)"] = JobProgress(value: 0.8, message: "설치 준비 중…")
            let staged = try await stage(dmg: dmg)
            try? FileManager.default.removeItem(at: dmg)
            // 받은 앱이 정말 EasyCut 새 버전인지 확인
            guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  let v = info["CFBundleShortVersionString"] as? String, isNewer(v, than: current) else {
                throw MediaError.failed("받은 파일이 올바른 EasyCut 새 버전이 아닙니다.")
            }
            // 작업 저장: 파일이 있으면 그 파일에, 새 프로젝트는 복구용 파일에 (다시 켜면 복구 제안)
            let reopen = store.projectURL
            if store.dirty {
                if reopen != nil { store.autosaveNow() } else if !store.project.assets.isEmpty {
                    let enc = JSONEncoder()
                    try? enc.encode(store.project).write(to: EditorStore.recoveryURL, options: .atomic)
                }
            }
            try relaunchAfterReplacing(appURL, with: staged, reopen: reopen)
            installing = true
            NSApp.terminate(nil)
        } catch {
            store.alert = "업데이트 실패: \(error.localizedDescription)\n\(rel.page.absoluteString) 에서 직접 받을 수 있습니다."
        }
    }

    nonisolated private static func download(_ url: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.failed("업데이트 파일을 받지 못했습니다.") }
        let dest = AppPaths.temp.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// DMG를 붙여 안의 EasyCut.app을 임시 폴더로 복사
    nonisolated private static func stage(dmg: URL) async throws -> URL {
        let mount = AppPaths.temp.appendingPathComponent("update-mount-\(UUID().uuidString.prefix(8))")
        let out = AppPaths.temp.appendingPathComponent("update-app", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        guard let app = apps.first else { throw MediaError.failed("업데이트 파일 안에 앱이 없습니다.") }
        let dest = out.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", [app.path, dest.path])
        return dest
    }

    @discardableResult
    nonisolated private static func run(_ bin: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw MediaError.failed("\(URL(fileURLWithPath: bin).lastPathComponent) 실패: \(s.suffix(200))") }
        return s
    }

    /// 앱이 끝나길 기다렸다가 새 앱으로 바꾸고 다시 여는 스크립트를 띄운다 (실패하면 원래 앱을 되돌린다)
    private static func relaunchAfterReplacing(_ app: URL, with staged: URL, reopen: URL?) throws {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = app.path + ".old"
        let openCmd = reopen.map { "open -a \(q(app.path)) \(q($0.path))" } ?? "open \(q(app.path))"
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf \(q(old))
        if mv \(q(app.path)) \(q(old)) && ditto \(q(staged.path)) \(q(app.path)); then
          rm -rf \(q(old))
        else
          rm -rf \(q(app.path)); mv \(q(old)) \(q(app.path))
        fi
        xattr -dr com.apple.quarantine \(q(app.path)) 2>/dev/null
        rm -rf \(q(staged.deletingLastPathComponent().path))
        \(openCmd)
        """
        let url = AppPaths.temp.appendingPathComponent("update.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [url.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
