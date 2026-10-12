import Foundation
import AppKit
import Darwin
import GPTNiangUpdate

@main
enum UpdaterMain {
    @MainActor static func belongs(_ pid: Int32, to app: URL) -> Bool {
        guard let process = NSRunningApplication(processIdentifier: pid) else { return false }
        return !process.isTerminated && process.bundleURL.map(UpdateFiles.canonical) == app
    }
    static func stop(_ pid: Int32, app: URL) async throws {
        guard await belongs(pid, to: app) else { return }
        let requested = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.terminate() ?? true }
        guard requested else { throw UpdateFailure("新版未能退出，恢復檔案已保留。") }
        for _ in 0..<100 {
            if !(await belongs(pid, to: app)) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw UpdateFailure("新版仍在執行，恢復檔案已保留。")
    }
    @MainActor static func launch(_ app: URL, data: URL) async throws -> Int32 {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--data-dir", data.path]; configuration.createsNewApplicationInstance = true
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, error in
                if let error { continuation.resume(throwing: error) }
                else if let running { continuation.resume(returning: running.processIdentifier) }
                else { continuation.resume(throwing: UpdateFailure("無法重新開啟 GPT 娘。")) }
            }
        }
    }
    static func main() async {
        let arguments = CommandLine.arguments
        do {
            if arguments.count >= 4, arguments[1] == "--validate-bundle" {
                try NativeArchive.validate(URL(fileURLWithPath: arguments[2]), version: arguments[3], universal: arguments.contains("--universal")); return
            }
            guard arguments.count == 3, ["--install", "--recover"].contains(arguments[1]) else { throw UpdateFailure("更新輔助程序參數無效。") }
            let file = URL(fileURLWithPath: arguments[2])
            guard var journal = try UpdateFiles.read(UpdateJournal.self, at: file) else { throw UpdateFailure("更新記錄缺失。") }
            let store = try UpdateStore(app: URL(fileURLWithPath: journal.appPath), data: URL(fileURLWithPath: journal.dataPath))
            guard file.standardizedFileURL == store.journalURL else { throw UpdateFailure("更新記錄路徑不符。") }
            let lock = try UpdateLock(at: store.data)
            defer { withExtendedLifetime(lock) {} }
            try store.validate(journal); journal.helperPID = getpid(); try store.save(journal)
            let parentPID = journal.parentPID
            for _ in 0..<300 {
                if !(await belongs(parentPID, to: store.app)) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if await belongs(parentPID, to: store.app) { throw UpdateFailure("目前掛件未退出，原版已保留。") }
            do {
                if arguments[1] == "--recover" {
                    try NativeInstaller.restore(store, journal: &journal)
                    _ = try await launch(store.app, data: store.data)
                    try store.cleanup()
                } else {
                    try await NativeInstaller.install(store, journal: &journal,
                        verify: { try NativeArchive.validate($0, version: $1) },
                        launch: { try await launch($0, data: store.data) }, health: { pid, record in
                            for _ in 0..<120 {
                                if let ready = try? UpdateFiles.read(UpdateHealth.self, at: store.data.appendingPathComponent("mac-update-health.json")),
                                   ready.token == record.token, ready.version == record.version, ready.appPath == record.appPath, ready.pid == pid {
                                    let valid = await MainActor.run { () -> Bool in
                                        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                                        return !app.isTerminated && app.bundleURL.map(UpdateFiles.canonical) == store.app
                                    }
                                    if valid { return true }
                                }
                                try await Task.sleep(nanoseconds: 250_000_000)
                            }
                            return false
                        }, stop: { try await stop($0, app: store.app) })
                }
            } catch {
                store.diagnose(error)
                if !journal.phase.terminal && journal.phase != .recoveryFailed {
                    do { try NativeInstaller.restore(store, journal: &journal); _ = try await launch(store.app, data: store.data); try store.cleanup() }
                    catch { journal.phase = .recoveryFailed; try? store.save(journal); store.diagnose(error) }
                }
                throw error
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}
