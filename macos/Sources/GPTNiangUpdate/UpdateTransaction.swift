import Foundation
import Darwin

public enum UpdateFiles {
    public static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    public static func inside(_ child: URL, _ parent: URL) -> Bool { child.standardizedFileURL.path.hasPrefix(parent.standardizedFileURL.path + "/") }
    public static func checkPath(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.path), try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw UpdateFailure("更新路徑不能包含目錄連結。")
            }
            current.deleteLastPathComponent()
        }
    }
    public static func checkTree(_ root: URL) throws {
        try checkPath(root)
        for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw UpdateFailure("更新檔案不能包含目錄連結。") }
            if values.isDirectory == true { try checkTree(item) }
        }
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    public static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
public enum UpdatePhase: String, Codable {
    case prepared, replacing, replaced, committed, restoring, rolledBack, recoveryFailed
    public var terminal: Bool { self == .committed || self == .rolledBack }
}
public struct UpdateOwnership: Codable, Equatable {
    public let schema: Int
    public let uid: UInt32
    public let token: String
    public let appPath: String
    public let dataPath: String
}
public struct UpdateJournal: Codable {
    public let schema: Int
    public let uid: UInt32
    public let token: String
    public let appPath: String
    public let dataPath: String
    public let version: String
    public let oldVersion: String
    public let hash: String
    public let parentPID: Int32
    public var helperPID: Int32?
    public var phase: UpdatePhase
    public var cleanupPending: Bool
    public init(token: String, app: URL, data: URL, version: String, oldVersion: String, hash: String, parentPID: Int32) {
        schema = 1; uid = getuid(); self.token = token; appPath = app.path; dataPath = data.path
        self.version = version; self.oldVersion = oldVersion; self.hash = hash; self.parentPID = parentPID
        phase = .prepared; cleanupPending = true
    }
}
public struct UpdateHealth: Codable {
    public let token: String
    public let version: String
    public let appPath: String
    public let pid: Int32
    public init(token: String, version: String, appPath: String, pid: Int32) {
        self.token = token; self.version = version; self.appPath = appPath; self.pid = pid
    }
}
public final class UpdateLock {
    private let descriptor: Int32
    public init(at data: URL) throws {
        descriptor = Darwin.open(data.appendingPathComponent("mac-update.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UpdateFailure("無法取得更新鎖。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw UpdateFailure("另一項更新或清理正在執行。") }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
public struct UpdateStore {
    public let app: URL
    public let data: URL
    public var journalURL: URL { data.appendingPathComponent("mac-update-transaction.json") }
    public init(app: URL, data: URL) throws {
        self.app = UpdateFiles.canonical(app); self.data = UpdateFiles.canonical(data)
        guard self.app.pathExtension == "app", !UpdateFiles.inside(self.data, self.app), self.app != self.data else { throw UpdateFailure("更新資料不能位於應用包內。") }
        try FileManager.default.createDirectory(at: self.data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try UpdateFiles.checkPath(self.app); try UpdateFiles.checkPath(self.data)
    }
    public func journal() throws -> UpdateJournal? { try UpdateFiles.read(UpdateJournal.self, at: journalURL) }
    public func save(_ journal: UpdateJournal) throws { try validate(journal); try UpdateFiles.write(journal, to: journalURL) }
    public func cache(_ token: String) -> URL { data.appendingPathComponent("mac-updates/" + token, isDirectory: true) }
    public func artifact(_ token: String) -> URL { app.deletingLastPathComponent().appendingPathComponent(".GPTNiangMac-update-" + token, isDirectory: true) }
    public func staged(_ token: String) -> URL { artifact(token).appendingPathComponent(app.lastPathComponent, isDirectory: true) }
    public func ownership(_ token: String) -> UpdateOwnership { UpdateOwnership(schema: 1, uid: getuid(), token: token, appPath: app.path, dataPath: data.path) }
    public func validate(_ journal: UpdateJournal) throws {
        guard journal.schema == 1, journal.uid == getuid(), UUID(uuidString: journal.token) != nil,
              journal.appPath == app.path, journal.dataPath == data.path,
              StableVersion(journal.version) != nil, StableVersion(journal.oldVersion) != nil else { throw UpdateFailure("更新記錄不屬於目前的應用。") }
        try UpdateFiles.checkPath(app); try UpdateFiles.checkPath(data); try UpdateFiles.checkPath(artifact(journal.token))
    }
    public func createOwned(_ directory: URL, token: String) throws {
        guard UUID(uuidString: token) != nil, directory == cache(token) || directory == artifact(token),
              !FileManager.default.fileExists(atPath: directory.path) else { throw UpdateFailure("更新暫存目錄已存在。") }
        try UpdateFiles.checkPath(directory)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try UpdateFiles.write(ownership(token), to: directory.appendingPathComponent("owner.json"))
    }
    public func removeOwned(_ directory: URL, token: String) throws {
        guard directory == cache(token) || directory == artifact(token), UUID(uuidString: token) != nil,
              !UpdateFiles.inside(app, directory), !UpdateFiles.inside(data, directory) else { throw UpdateFailure("清理路徑超出更新目錄。") }
        try UpdateFiles.checkPath(directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard try UpdateFiles.read(UpdateOwnership.self, at: directory.appendingPathComponent("owner.json")) == ownership(token) else { throw UpdateFailure("清理目錄歸屬不符。") }
        try UpdateFiles.checkTree(directory); try FileManager.default.removeItem(at: directory)
    }
    public func cleanup() throws {
        var record = try journal()
        if let journal = record {
            try validate(journal)
            guard journal.phase.terminal else { throw UpdateFailure("未完成的更新需要先恢復，檔案已保留。") }
            let expected = journal.phase == .committed ? journal.version : journal.oldVersion
            guard try NativeArchive.version(of: app) == expected else { throw UpdateFailure("目前應用版本不符，恢復檔案已保留。") }
            try removeOwned(artifact(journal.token), token: journal.token)
            try removeOwned(cache(journal.token), token: journal.token)
        }
        let directory = data.appendingPathComponent("mac-updates", isDirectory: true)
        try UpdateFiles.checkPath(directory)
        if FileManager.default.fileExists(atPath: directory.path) {
            for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
                try UpdateFiles.checkPath(entry)
                guard try UpdateFiles.read(UpdateOwnership.self, at: entry.appendingPathComponent("owner.json")) == ownership(entry.lastPathComponent) else { continue }
                try removeOwned(artifact(entry.lastPathComponent), token: entry.lastPathComponent)
                try removeOwned(entry, token: entry.lastPathComponent)
            }
        }
        if var journal = record { journal.cleanupPending = false; try save(journal); record = journal }
    }
    public func diagnose(_ error: Error) { try? Data(error.localizedDescription.utf8).write(to: data.appendingPathComponent("mac-update-diagnostic.txt"), options: .atomic) }
}
public enum NativeInstaller {
    public static func exchange(_ app: URL, _ staged: URL) throws {
        let result = app.path.withCString { a in staged.path.withCString { b in renamex_np(a, b, UInt32(RENAME_SWAP)) } }
        guard result == 0 else { throw UpdateFailure("無法替換應用，原版已保留：" + String(cString: strerror(errno))) }
    }
    public static func restore(_ store: UpdateStore, journal: inout UpdateJournal) throws {
        try store.validate(journal)
        guard journal.phase != .recoveryFailed else { throw UpdateFailure("上次恢復失敗，請先檢查保留的恢復檔案。") }
        let current = try NativeArchive.version(of: store.app)
        if current == journal.version {
            guard try NativeArchive.version(of: store.staged(journal.token)) == journal.oldVersion else { throw UpdateFailure("上一版備份無法確認，檔案已保留。") }
            journal.phase = .restoring; try store.save(journal)
            try exchange(store.app, store.staged(journal.token))
        } else if current != journal.oldVersion { throw UpdateFailure("目前應用與更新記錄不符。") }
        journal.phase = .rolledBack; journal.cleanupPending = true; try store.save(journal)
    }
    public static func install(_ store: UpdateStore, journal: inout UpdateJournal,
                               verify: (URL, String) throws -> Void,
                               launch: (URL) async throws -> Int32,
                               health: (Int32, UpdateJournal) async throws -> Bool,
                               stop: (Int32) async throws -> Void) async throws {
        try store.validate(journal)
        guard journal.phase == .prepared, try NativeArchive.version(of: store.app) == journal.oldVersion else { throw UpdateFailure("應用版本已變更，更新已取消。") }
        guard UpdatePolicy.hash(try Data(contentsOf: store.cache(journal.token).appendingPathComponent("release.zip"))) == journal.hash else { throw UpdateFailure("下載包在安裝前發生變更。") }
        try verify(store.staged(journal.token), journal.version)
        journal.phase = .replacing; try store.save(journal)
        var launchedPID: Int32?
        do {
            try exchange(store.app, store.staged(journal.token))
            journal.phase = .replaced; try store.save(journal)
            let pid = try await launch(store.app); launchedPID = pid
            guard try await health(pid, journal) else { throw UpdateFailure("新版沒有完成啟動，正在恢復上一版。") }
            journal.phase = .committed; journal.cleanupPending = true; try store.save(journal)
        } catch {
            let failure = error
            do {
                if let pid = launchedPID { try await stop(pid) }
                try restore(store, journal: &journal); _ = try await launch(store.app)
            }
            catch { journal.phase = .recoveryFailed; try? store.save(journal); store.diagnose(error) }
            if journal.phase.terminal { do { try store.cleanup() } catch { store.diagnose(error) } }
            throw failure
        }
        do { try store.cleanup() } catch { store.diagnose(error) }
    }
}
