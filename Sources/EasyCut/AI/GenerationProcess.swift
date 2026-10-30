import Foundation
import Darwin

/// A generation job can reuse this runner for several commands. Cancellation is
/// sticky: a new job should create a new runner.
final class GenerationProcess: @unchecked Sendable {
    enum Failure: LocalizedError {
        case timedOut
        case outputLimitExceeded

        var errorDescription: String? {
            switch self {
            case .timedOut: return "영상 생성 명령의 실행 시간이 초과되었습니다. 다시 시도해 주세요."
            case .outputLimitExceeded: return "영상 생성 명령의 출력이 2MB를 초과했습니다."
            }
        }
    }

    private let lock = NSLock()
    private var cancelled = false
    private var invocations: [UUID: Invocation] = [:]

    func cancel() {
        lock.lock()
        cancelled = true
        let running = Array(invocations.values)
        lock.unlock()
        running.forEach { $0.stop(CancellationError()) }
    }

    func run(_ executable: String, _ arguments: [String], directory: URL,
             environment: [String: String] = AgentLink.environment,
             input: String? = nil, timeout: TimeInterval = 600) async throws -> String {
        try Task.checkCancellation()
        let id = UUID(), invocation = Invocation()
        try register(invocation, id: id)
        defer { unregister(id) }
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                invocation.start(executable, arguments, directory: directory,
                                 environment: environment, input: input,
                                 timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            invocation.stop(CancellationError())
        }
        try Task.checkCancellation()
        try checkCancellation()
        return result
    }

    private func register(_ invocation: Invocation, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        invocations[id] = invocation
    }

    private func unregister(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        invocations.removeValue(forKey: id)
    }

    private func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    /// All state and descriptor operations are confined to this queue. Both
    /// output pipes and stdin are nonblocking, including when a child stalls.
    private final class Invocation: @unchecked Sendable {
        private let queue = DispatchQueue(label: "kr.learntoday.easycut.generation-process", qos: .userInitiated)
        private let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        private var outputSource: DispatchSourceRead?
        private var errorSource: DispatchSourceRead?
        private var inputSource: DispatchSourceWrite?
        private var timer: DispatchSourceTimer?
        private var continuation: CheckedContinuation<String, Error>?
        private var pendingError: Error?
        private var output = Data(), errorTail = Data(), input = Data()
        private var inputOffset = 0
        private var launched = false, exited = false, completed = false
        private var outputEnded = false, errorEnded = false
        private var pid: pid_t = 0
        private var exitStatus: Int32 = 0
        private var exitedNormally = false
        private var reapAllowed = false, reaped = false
        private var commandName = ""
        private let outputLimit = 2 * 1024 * 1024
        private let diagnosticLimit = 32 * 1024

        func start(_ executable: String, _ arguments: [String], directory: URL,
                   environment: [String: String], input: String?, timeout: TimeInterval,
                   continuation: CheckedContinuation<String, Error>) {
            queue.async {
                self.continuation = continuation
                if let error = self.pendingError { self.finish(.failure(error)); return }
                self.commandName = URL(fileURLWithPath: executable).lastPathComponent
                self.input = input.map { Data($0.utf8) } ?? Data()
                do {
                    try self.makeNonblocking(self.stdout.fileHandleForReading.fileDescriptor)
                    try self.makeNonblocking(self.stderr.fileHandleForReading.fileDescriptor)
                    try self.makeNonblocking(self.stdin.fileHandleForWriting.fileDescriptor)
                    // A child closing stdin must never deliver SIGPIPE to EasyCut.
                    guard fcntl(self.stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    self.outputSource = self.reader(self.stdout, isError: false)
                    self.errorSource = self.reader(self.stderr, isError: true)
                    try self.spawn(executable, arguments, directory: directory, environment: environment)
                    self.launched = true
                    try? self.stdout.fileHandleForWriting.close()
                    try? self.stderr.fileHandleForWriting.close()
                    try? self.stdin.fileHandleForReading.close()
                    self.beginWait()
                    self.beginInput()
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    self.timer = timer
                    timer.schedule(deadline: .now() + (timeout.isFinite ? max(0.01, timeout) : 600))
                    timer.setEventHandler { [weak self] in self?.stopOnQueue(Failure.timedOut) }
                    timer.resume()
                } catch {
                    self.stopOnQueue(MediaError.failed("\(self.commandName) 실행 실패: \(error.localizedDescription)"))
                }
            }
        }

        func stop(_ error: Error) {
            queue.async { self.stopOnQueue(error) }
        }

        /// SETPGROUP creates the group before exec, unlike setpgid after
        /// Process.run(), which can race with exec and leave renderers behind.
        private func spawn(_ executable: String, _ arguments: [String], directory: URL,
                           environment: [String: String]) throws {
            let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
            guard ([executable, directory.path] + arguments + environmentStrings).allSatisfy({ !$0.utf8.contains(0) }) else {
                throw MediaError.failed("명령 인자에 사용할 수 없는 문자가 있습니다.")
            }
            var actions: posix_spawn_file_actions_t?
            try checkSpawn(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            let handles = [stdin.fileHandleForReading, stdin.fileHandleForWriting,
                           stdout.fileHandleForReading, stdout.fileHandleForWriting,
                           stderr.fileHandleForReading, stderr.fileHandleForWriting]
            try checkSpawn(posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO))
            try checkSpawn(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
            try checkSpawn(posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
            for handle in handles where handle.fileDescriptor > STDERR_FILENO {
                try checkSpawn(posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor))
            }
            try directory.path.withCString { path in
                try checkSpawn(posix_spawn_file_actions_addchdir_np(&actions, path))
            }
            var attributes: posix_spawnattr_t?
            try checkSpawn(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            try checkSpawn(posix_spawnattr_setpgroup(&attributes, 0))
            var signalMask = sigset_t(), defaultSignals = sigset_t()
            sigemptyset(&signalMask)
            sigemptyset(&defaultSignals)
            sigaddset(&defaultSignals, SIGPIPE)
            sigaddset(&defaultSignals, SIGTERM)
            try checkSpawn(posix_spawnattr_setsigmask(&attributes, &signalMask))
            try checkSpawn(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
            let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
            try checkSpawn(posix_spawnattr_setflags(&attributes, Int16(flags)))
            try withCStringArray([executable] + arguments) { argv in
                try withCStringArray(environmentStrings) { envp in
                    try executable.withCString { path in
                        try checkSpawn(posix_spawn(&pid, path, &actions, &attributes, argv, envp))
                    }
                }
            }
        }

        private func checkSpawn(_ result: Int32) throws {
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        }

        private func withCStringArray<T>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) rethrows -> T {
            var pointers = strings.map { strdup($0) } + [nil]
            defer { pointers.dropLast().forEach { free($0) } }
            return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
        }

        private func beginWait() {
            let child = pid
            DispatchQueue.global(qos: .utility).async {
                var info = siginfo_t()
                var result: Int32
                repeat { result = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) }
                while result == -1 && errno == EINTR
                let waitError = result == -1 ? errno : 0
                let status = info.si_status, normal = info.si_code == CLD_EXITED
                self.queue.async {
                    self.exited = true
                    self.exitStatus = status
                    self.exitedNormally = normal
                    if waitError != 0 {
                        self.reaped = waitError == ECHILD
                        self.stopOnQueue(MediaError.failed("\(self.commandName) 종료 확인 실패: \(String(cString: strerror(waitError)))"))
                    }
                    self.reapIfPossible()
                    self.completeIfReady()
                }
            }
        }

        private func reapIfPossible() {
            guard launched, exited, reapAllowed, !reaped else { return }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { reaped = true }
        }

        private func makeNonblocking(_ fd: Int32) throws {
            let flags = fcntl(fd, F_GETFL)
            guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        private func reader(_ pipe: Pipe, isError: Bool) -> DispatchSourceRead {
            let source = DispatchSource.makeReadSource(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain(pipe, isError: isError) }
            source.resume()
            return source
        }

        private func drain(_ pipe: Pipe, isError: Bool) {
            guard !completed else { return }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            // Yield between batches so an endlessly noisy stderr cannot delay
            // cancellation or the timeout handler on this queue.
            for _ in 0..<32 {
                guard !completed else { return }
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(pipe.fileHandleForReading.fileDescriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    if isError {
                        errorTail.append(contentsOf: buffer.prefix(count))
                        if errorTail.count > diagnosticLimit { errorTail.removeFirst(errorTail.count - diagnosticLimit) }
                    } else {
                        guard output.count + count <= outputLimit else {
                            stopOnQueue(Failure.outputLimitExceeded)
                            return
                        }
                        output.append(contentsOf: buffer.prefix(count))
                    }
                } else if count == 0 {
                    if isError { errorEnded = true; errorSource?.cancel() }
                    else { outputEnded = true; outputSource?.cancel() }
                    completeIfReady()
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    stopOnQueue(MediaError.failed("\(commandName) 출력을 읽지 못했습니다: \(String(cString: strerror(errno)))"))
                    return
                }
            }
        }

        private func beginInput() {
            guard !input.isEmpty else { try? stdin.fileHandleForWriting.close(); return }
            let source = DispatchSource.makeWriteSource(fileDescriptor: stdin.fileHandleForWriting.fileDescriptor, queue: queue)
            inputSource = source
            source.setEventHandler { [weak self] in self?.writeInput() }
            source.resume()
        }

        private func writeInput() {
            guard !completed, !input.isEmpty, inputOffset < input.count else { return }
            let count = input.withUnsafeBytes { bytes in
                Darwin.write(stdin.fileHandleForWriting.fileDescriptor,
                             bytes.baseAddress!.advanced(by: inputOffset),
                             min(16 * 1024, input.count - inputOffset))
            }
            if count > 0 {
                inputOffset += count
                if inputOffset == input.count {
                    inputSource?.cancel()
                    inputSource = nil
                    try? stdin.fileHandleForWriting.close()
                    input = Data()
                }
            } else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                // Early exit is reported with the child's stderr and exit code.
                inputSource?.cancel()
                inputSource = nil
                try? stdin.fileHandleForWriting.close()
                input = Data()
            }
        }

        private func completeIfReady() {
            guard !completed, exited, outputEnded, errorEnded else { return }
            if let error = pendingError { finish(.failure(error)); return }
            guard exitedNormally, exitStatus == 0 else {
                let diagnostic = String(decoding: errorTail.isEmpty ? output.suffix(diagnosticLimit) : errorTail, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = diagnostic.isEmpty ? "오류 내용이 없습니다." : String(diagnostic.suffix(4000))
                finish(.failure(MediaError.failed("\(commandName) 실행 실패 (코드 \(exitStatus))\n\(detail)")))
                return
            }
            finish(.success(String(decoding: output, as: UTF8.self)))
        }

        private func stopOnQueue(_ error: Error) {
            guard !completed else { return }
            if pendingError == nil { pendingError = error }
            guard continuation != nil else { return }
            if launched {
                signalChild(SIGTERM)
                // Retain this invocation until escalation, even after resuming
                // its caller. The application process is never a signal target.
                queue.asyncAfter(deadline: .now() + 1) {
                    self.signalChild(SIGKILL)
                    self.reapAllowed = true
                    self.reapIfPossible()
                }
            }
            finish(.failure(pendingError ?? error))
        }

        private func signalChild(_ signal: Int32) {
            guard launched, !reaped, pid > 0, pid != getpid() else { return }
            // waitid(WNOWAIT) reserves this exact child PID until the last
            // group signal, preventing PID reuse from targeting another job.
            _ = kill(-pid, signal)
        }

        private func finish(_ result: Result<String, Error>) {
            guard !completed, let continuation else { return }
            completed = true
            self.continuation = nil
            timer?.cancel(); timer = nil
            outputSource?.cancel(); outputSource = nil
            errorSource?.cancel(); errorSource = nil
            inputSource?.cancel(); inputSource = nil
            for handle in [stdout.fileHandleForReading, stdout.fileHandleForWriting,
                           stderr.fileHandleForReading, stderr.fileHandleForWriting,
                           stdin.fileHandleForReading, stdin.fileHandleForWriting] {
                try? handle.close()
            }
            if pendingError == nil {
                reapAllowed = true
                reapIfPossible()
            }
            continuation.resume(with: result)
        }
    }
}
