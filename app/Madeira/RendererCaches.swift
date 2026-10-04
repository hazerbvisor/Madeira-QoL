import Foundation
import CryptoKit
import SQLite3

/// Manages namespaces and maintenance for the renderer's real caches. It does
/// not persist executable FEX code: the current iOS cache loader is unsafe.
enum RendererCaches {
    private static let queue = DispatchQueue(label: "madeira.renderer-cache-maintenance", qos: .utility)
    private static var sessionActive = false // accessed only on queue
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MadeiraPerformance/v1", isDirectory: true)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func fileDigest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static var runtimeIdentity: String?
    static func gameDirectory(_ entry: LibraryEntry) -> URL {
        root.appendingPathComponent(digest(Data(entry.launchWindowsPath.lowercased().utf8)), isDirectory: true)
    }

    /// Call on the existing launch worker, before Wine initializes any cache.
    static func prepare(_ entry: LibraryEntry) {
        queue.sync {
            sessionActive = true
            do {
                if runtimeIdentity == nil, let app = Bundle.main.executableURL {
                    runtimeIdentity = try fileDigest(app)
                }
                let executable = try LibraryModel.executable(entry.launchRelativePath)
                let regular = (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                let gameIdentity = regular ? try fileDigest(executable) : entry.launchWindowsPath
                let compatibility = "pipeline-v1|\(runtimeIdentity ?? "unknown")|\(gameIdentity)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
                let path = gameDirectory(entry).appendingPathComponent(digest(Data(compatibility.utf8)), isDirectory: true)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                validateShaderDatabases(in: path)
                setenv("DXMT_IOS_CACHE_DIR", MadeiraConfig.get("env.DXMT_IOS_CACHE_DIR") ?? "1", 1)
                setenv("DXMT_SHADER_CACHE_PATH", path.path, 1)
                setenv("MADEIRA_SHADER_CACHE_PATH", path.path, 1)
                // Keep Metal's normal system cache. Public binary archives below
                // add persistence without calling MTLSetShaderCachePath (private).
                setenv("DXMT_USE_DEFAULT_METAL_CACHE", "1", 1)
                let profile = entry.performanceUpgrade ?? PerformanceProfile()
                madeira_performance_configure(Int32(profile.fpsCap ?? -1), entry.performance || profile.automaticPerformance ? 1 : 0,
                                               path.appendingPathComponent("pipelines.metalarc").path)
                prune(excluding: path)
            } catch {
                // Disk pressure, sandbox denial and missing executables must not
                // prevent launch. The shader compiler remains the fallback.
                setenv("DXMT_IOS_CACHE_DIR", "1", 1)
                madeira_performance_configure(Int32(entry.performanceUpgrade?.fpsCap ?? -1), entry.performance ? 1 : 0, nil)
                fputs("[cache] persistent renderer cache unavailable: \(error.localizedDescription)\n", stderr)
            }
        }
    }
    static func finish() { queue.async { sessionActive = false } }

    private static func validateShaderDatabases(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "db" {
            var database: OpaquePointer?
            var query: OpaquePointer?
            var valid = false
            if sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
               sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &query, nil) == SQLITE_OK,
               sqlite3_step(query) == SQLITE_ROW, let text = sqlite3_column_text(query, 0) {
                valid = String(cString: text) == "ok"
            }
            sqlite3_finalize(query); sqlite3_close(database)
            if !valid {
                for suffix in ["", "-wal", "-shm", "-lock"] {
                    try? FileManager.default.removeItem(atPath: file.path + suffix)
                }
            }
        }
    }

    private static func prune(excluding active: URL) {
        let manager = FileManager.default
        guard let games = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var folders: [(url: URL, date: Date, bytes: Int)] = []
        for game in games {
            guard let versions = try? manager.contentsOfDirectory(at: game, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for version in versions {
                guard let files = manager.enumerator(at: version, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
                var bytes = 0
                for case let file as URL in files {
                    let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if info?.isRegularFile == true { bytes += info?.fileSize ?? 0 }
                }
                folders.append((version, (try? version.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast, bytes))
            }
        }
        var total = folders.reduce(0) { $0 + $1.bytes }
        for folder in folders.sorted(by: { $0.date < $1.date }) where total > 512 * 1024 * 1024 && folder.url != active {
            do { try manager.removeItem(at: folder.url); total -= folder.bytes } catch { }
        }
    }
    static func clear(_ entry: LibraryEntry? = nil, completion: @escaping (String) -> Void) {
        queue.async {
            let message: String
            if sessionActive { message = "Close the game before clearing its caches." }
            else {
                let path = entry.map(gameDirectory) ?? root
                do {
                    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                    message = "Renderer caches cleared. Shaders and pipelines will compile normally on the next launch."
                } catch { message = error.localizedDescription }
            }
            DispatchQueue.main.async { completion(message) }
        }
    }
}
