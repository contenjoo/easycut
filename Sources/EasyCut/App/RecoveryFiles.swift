import Foundation

/// 저장한 적 없는 새 프로젝트를 보관하는 복구용 파일.
/// EasyCut을 여러 개 띄우거나 업데이트로 다시 시작해도 서로 덮어쓰거나 지우지 않도록 실행마다 따로 둔다.
/// 실행 중에는 파일 옆의 `.lock`을 flock으로 쥐고 있어서(강제 종료되면 OS가 풀어 줌)
/// 다음 실행은 잠금이 풀린 파일만 '끝난 실행이 남긴 작업'으로 본다.
enum RecoveryFiles {
    /// 예전 버전이 쓰던 하나뿐인 복구 파일 (읽기·정리만 한다)
    static var legacyURL: URL { AppPaths.support.appendingPathComponent("복구용 프로젝트.easycut") }

    static var directory: URL {
        let dir = AppPaths.support.appendingPathComponent("recovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 이 실행만의 이름 (pid만 쓰면 재사용될 수 있어 임의 값을 붙인다)
    static let instanceID = "\(getpid())-\(UUID().uuidString.prefix(8))"

    /// 이 실행의 복구 파일
    static var ownURL: URL { directory.appendingPathComponent("복구용 프로젝트 \(instanceID).easycut") }

    static func lockURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("lock")
    }

    private static let mutex = NSLock()
    nonisolated(unsafe) private static var held: [String: Int32] = [:]

    /// 이 실행이 끝날 때까지 자기 복구 파일의 잠금을 쥔다
    @discardableResult
    static func holdLock(for url: URL) -> Bool {
        let path = lockURL(for: url).path
        mutex.lock(); defer { mutex.unlock() }
        if held[path] != nil { return true }
        let fd = Darwin.open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        held[path] = fd
        return true
    }

    /// 이 실행의 복구 파일에 쓴다
    static func write(_ data: Data) throws {
        let url = ownURL
        holdLock(for: url)
        try data.write(to: url, options: .atomic)
    }

    /// 이 실행의 복구 파일만 지운다 (다른 실행·지난 실행의 파일은 건드리지 않는다)
    static func clearOwn() {
        try? FileManager.default.removeItem(at: ownURL)
    }

    /// 지금 실행 중인 EasyCut(이 실행 포함)이 쥐고 있는 복구 파일인지
    static func isHeldByRunningInstance(_ url: URL) -> Bool {
        if url.standardizedFileURL.path == ownURL.standardizedFileURL.path { return true }
        let fd = Darwin.open(lockURL(for: url).path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 끝난 실행이 남긴 복구 파일, 최근 것부터. 예전 버전의 단일 복구 파일도 포함한다.
    static func leftovers() -> [URL] {
        let fm = FileManager.default
        var urls = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "easycut" && !isHeldByRunningInstance($0) }
        if fm.fileExists(atPath: legacyURL.path) { urls.append(legacyURL) }
        return urls.sorted { (modificationDate($0) ?? .distantPast) > (modificationDate($1) ?? .distantPast) }
    }

    /// 처리한(복구했거나 버린) 지난 실행의 복구 파일을 지운다
    static func remove(_ url: URL) {
        guard !isHeldByRunningInstance(url) else { return }
        try? FileManager.default.removeItem(at: url)
        if url.standardizedFileURL.path != legacyURL.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: lockURL(for: url))
        }
    }

    /// 복구 파일 없이 남은, 끝난 실행의 잠금 파일 정리
    static func removeStaleLocks() {
        let fm = FileManager.default
        for lock in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where lock.pathExtension == "lock" {
            let file = lock.deletingPathExtension().appendingPathExtension("easycut")
            guard !fm.fileExists(atPath: file.path), !isHeldByRunningInstance(file) else { continue }
            try? fm.removeItem(at: lock)
        }
    }
}
