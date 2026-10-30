import Foundation
import Darwin

// Standalone dependencies only. Compile the production GenerationProcess.swift
// alongside this harness; no copy of the runner is maintained here.
enum AgentLink {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
}

enum MediaError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let text) = self { return text }
        return nil
    }
}

@main @MainActor
struct GenerationProcessRegression {
    private static var failures = 0

    private static func check(_ condition: Bool, _ name: String) {
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(name)")
    }

    private static func waitForPids(_ url: URL) async throws -> [String: Int32] {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int32],
               object["root"] != nil, object["child"] != nil, object["group"] != nil,
               FileManager.default.fileExists(atPath: url.path + ".child") {
                return object
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw MediaError.failed("Fixture PID or child heartbeat file was not created.")
    }

    static func main() async {
        let parent = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = parent.appendingPathComponent("easycut-generation-regression-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let candidates = [ProcessInfo.processInfo.environment["EASYCUT_TEST_PYTHON"],
                              "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].compactMap { $0 }
            guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw MediaError.failed("Python 3 is required; set EASYCUT_TEST_PYTHON to its executable path.")
            }
            let fixture = directory.appendingPathComponent("fixture.py")
            try fixtureSource.write(to: fixture, atomically: true, encoding: .utf8)
            await testPipes(python: python, fixture: fixture, directory: directory)
            await testErrors(python: python, fixture: fixture, directory: directory)
            await testPreCancelled(directory: directory)
            await testSubtree(mode: "tree", python: python, fixture: fixture, directory: directory)
            await testSubtree(mode: "exit-parent", python: python, fixture: fixture, directory: directory)
        } catch {
            check(false, "Harness setup: \(error.localizedDescription)")
        }
        print("FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func testPipes(python: String, fixture: URL, directory: URL) async {
        do {
            let runner = GenerationProcess()
            let output = try await runner.run(python, [fixture.path, "pipes"], directory: directory,
                                              input: String(repeating: "i", count: 1024 * 1024), timeout: 10)
            check(output.hasPrefix("1048576\n") && output.utf8.count == 96 * 16384 + 8,
                  "simultaneous 1MB stdin / 1.5MB stdout / 8MB stderr")
            let second = try await runner.run("/usr/bin/printf", ["second"], directory: directory)
            check(second == "second", "runner reusable; returns stdout only")
        } catch {
            check(false, "Pipe test: \(error.localizedDescription)")
        }
    }

    private static func testErrors(python: String, fixture: URL, directory: URL) async {
        do {
            _ = try await GenerationProcess().run(python, [fixture.path, "oversize"], directory: directory, timeout: 10)
            check(false, "stdout cap")
        } catch GenerationProcess.Failure.outputLimitExceeded {
            check(true, "stdout over 2MB rejected")
        } catch {
            check(false, "stdout cap: \(error.localizedDescription)")
        }
        do {
            _ = try await GenerationProcess().run(python, [fixture.path, "failed"], directory: directory)
            check(false, "nonzero error")
        } catch {
            check(error.localizedDescription.contains("코드 7") && error.localizedDescription.contains("stderr detail"),
                  "nonzero stderr diagnostic")
        }
        do {
            _ = try await GenerationProcess().run(python, [fixture.path, "sleep"], directory: directory, timeout: 0.1)
            check(false, "timeout")
        } catch GenerationProcess.Failure.timedOut {
            check(true, "distinct timeout")
        } catch {
            check(false, "Timeout: \(error.localizedDescription)")
        }
    }

    private static func testPreCancelled(directory: URL) async {
        let runner = GenerationProcess()
        let marker = directory.appendingPathComponent("must-not-launch")
        runner.cancel()
        do {
            _ = try await runner.run("/usr/bin/touch", [marker.path], directory: directory)
            check(false, "cancel before launch")
        } catch is CancellationError {
            check(true, "cancel before launch")
        } catch {
            check(false, "Cancel before launch: \(error.localizedDescription)")
        }
        check(!FileManager.default.fileExists(atPath: marker.path), "pre-cancel has no side effect")
    }

    private static func testSubtree(mode: String, python: String, fixture: URL, directory: URL) async {
        let pidFile = directory.appendingPathComponent("\(mode)-\(UUID().uuidString).json")
        let runner = GenerationProcess()
        let task = Task { try await runner.run(python, [fixture.path, mode, pidFile.path], directory: directory, timeout: 10) }
        do {
            // The child writes its first heartbeat only after ignoring SIGTERM.
            let pids = try await waitForPids(pidFile)
            if mode == "tree" { runner.cancel() } else { task.cancel() }
            do {
                _ = try await task.value
                check(false, "\(mode) throws cancellation")
            } catch is CancellationError {
                check(true, "\(mode) throws cancellation")
            } catch {
                check(false, "\(mode) cancellation: \(error.localizedDescription)")
            }
            try await Task.sleep(nanoseconds: 1_300_000_000)
            let root = pids["root"]!, child = pids["child"]!, group = pids["group"]!
            let rootBeat = try? String(contentsOfFile: pidFile.path + ".root", encoding: .utf8)
            let childBeat = try? String(contentsOfFile: pidFile.path + ".child", encoding: .utf8)
            try await Task.sleep(nanoseconds: 350_000_000)
            let rootAlive = rootBeat != (try? String(contentsOfFile: pidFile.path + ".root", encoding: .utf8))
            let childAlive = childBeat != (try? String(contentsOfFile: pidFile.path + ".child", encoding: .utf8))
            print("EVIDENCE \(mode) root=\(root) child=\(child) group=\(group) harness-group=\(getpgrp()) rootAlive=\(rootAlive) childAlive=\(childAlive)")
            check(group == root && group != getpgrp(), "\(mode) independent process group")
            check(childBeat != nil && !rootAlive && !childAlive, "\(mode) whole subtree terminated")
            // On regression, terminate only the exact fixture process that is
            // still actively updating this run's unique heartbeat file.
            if rootAlive { _ = kill(root, SIGKILL) }
            if childAlive { _ = kill(child, SIGKILL) }
        } catch {
            runner.cancel()
            _ = try? await task.value
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            check(false, "\(mode) fixture: \(error.localizedDescription)")
        }
    }

    private static let fixtureSource = #"""
import json, os, signal, subprocess, sys, threading, time
from pathlib import Path

mode = sys.argv[1]
if mode == 'pipes':
    def noisy():
        for _ in range(512):
            os.write(2, b'e' * 16384)
    thread = threading.Thread(target=noisy)
    thread.start()
    payload = sys.stdin.buffer.read()
    os.write(1, str(len(payload)).encode() + b'\n')
    for _ in range(96):
        os.write(1, b'o' * 16384)
    thread.join()
elif mode == 'oversize':
    os.write(1, b'x' * (2 * 1024 * 1024 + 1))
elif mode == 'failed':
    os.write(1, b'not-json\n')
    os.write(2, b'regression stderr detail\n')
    sys.exit(7)
elif mode == 'sleep':
    time.sleep(60)
elif mode == 'child':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        Path(sys.argv[2]).write_text(str(time.time_ns()))
        time.sleep(0.1)
elif mode == 'tree':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable, __file__, 'child', sys.argv[2] + '.child'])
    with open(sys.argv[2], 'w') as f:
        json.dump({'root': os.getpid(), 'child': child.pid, 'group': os.getpgrp()}, f)
    while True:
        Path(sys.argv[2] + '.root').write_text(str(time.time_ns()))
        time.sleep(0.1)
elif mode == 'exit-parent':
    child = subprocess.Popen([sys.executable, __file__, 'child', sys.argv[2] + '.child'])
    with open(sys.argv[2], 'w') as f:
        json.dump({'root': os.getpid(), 'child': child.pid, 'group': os.getpgrp()}, f)
    sys.exit(0)
"""#
}
