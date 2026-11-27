import Foundation

// MARK: - 扫描快照

struct SnapNode: Codable {
    var n: String        // 名称
    var s: Int64         // 体积
    var d: Bool          // 是否目录
    var k: Int           // 类型序号
    var t: Double?       // 修改时间
    var c: [SnapNode]?   // 子项
    var x: Bool?         // 更深层级未缓存
}

struct SnapKind: Codable { var k: String; var s: Int64; var c: Int }
struct SnapApp: Codable { var n: String; var p: String; var s: Int64; var c: Int; var k: String }
struct SnapJunk: Codable { var p: String; var n: String; var s: Int64; var c: String; var r: String; var rs: String; var d: Bool }
struct SnapFile: Codable { var p: String; var n: String; var s: Int64; var m: Double?; var a: Double?; var e: String }

struct ScanSnapshot: Codable {
    var version: Int
    var path: String
    var date: Date
    var totalSize: Int64
    var fileCount: Int
    var dirCount: Int
    var deniedCount: Int
    var kinds: [SnapKind]
    var apps: [SnapApp]
    var junk: [SnapJunk]
    var large: [SnapFile]
    var tree: SnapNode
}

enum SnapshotStore {

    /// 缓存深度：超过这个层级的子项不落盘，需要时重新扫描
    static let maxDepth = 5
    static let maxNodes = 120_000
    static let maxJunk = 2000
    static let maxLarge = 500

    static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("DiskLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-scan.json")
    }

    // MARK: 保存

    static func save(_ res: ScanResult,
                     junk: [JunkItem],
                     files: [FileEntry]) {
        guard let url = fileURL else { return }

        var budget = maxNodes
        let tree = toSnap(res.root, depth: 0, budget: &budget)

        let largeFiles = files
            .filter { $0.size >= 100 * 1024 * 1024 }
            .sorted { $0.size > $1.size }
            .prefix(maxLarge)
            .map {
                SnapFile(p: $0.path, n: $0.name, s: $0.size,
                         m: $0.modified?.timeIntervalSince1970,
                         a: $0.accessed?.timeIntervalSince1970,
                         e: $0.ext)
            }

        let snap = ScanSnapshot(
            version: 1,
            path: res.rootPath,
            date: Date(),
            totalSize: res.totalSize,
            fileCount: res.fileCount,
            dirCount: res.dirCount,
            deniedCount: res.denied.count,
            kinds: res.kindStats.map { SnapKind(k: $0.kind.rawValue, s: $0.size, c: $0.count) },
            apps: res.appStats.prefix(150).map {
                SnapApp(n: $0.name, p: $0.path, s: $0.size, c: $0.count, k: $0.kind.rawValue)
            },
            junk: junk.prefix(maxJunk).map {
                SnapJunk(p: $0.path, n: $0.name, s: $0.size, c: $0.category.rawValue,
                         r: $0.risk.rawValue, rs: $0.reason, d: $0.isDirectory)
            },
            large: Array(largeFiles),
            tree: tree
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(snap) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // macOS 14+ 会给文件打 com.apple.provenance 标记，
            // 之后再用“临时文件改名覆盖”的原子写法会返回 EPERM，
            // 这里退化为先删除再写入
            try? FileManager.default.removeItem(at: url)
            try? data.write(to: url)
        }
        if ProcessInfo.processInfo.environment["DL_DEBUG_SNAP"] != nil {
            let onDisk = (try? Data(contentsOf: url)).map { $0.count } ?? -1
            FileHandle.standardError.write("snapshot saved: \(res.totalSize / 1_048_576)MB files=\(res.fileCount) disk=\(onDisk)B\n".data(using: .utf8)!)
        }
    }

    private static func toSnap(_ node: FNode, depth: Int, budget: inout Int) -> SnapNode {
        budget -= 1
        let kindIndex = FileKind.allCases.firstIndex(of: node.kind) ?? 8

        var snap = SnapNode(n: node.name, s: node.size, d: node.isDir, k: kindIndex,
                            t: node.modified?.timeIntervalSince1970, c: nil, x: nil)

        guard node.isDir, !node.children.isEmpty else { return snap }

        if depth + 1 >= maxDepth || budget <= 0 {
            snap.x = true
            return snap
        }

        var kids: [SnapNode] = []
        kids.reserveCapacity(min(node.children.count, 400))
        for (i, child) in node.children.enumerated() {
            if budget <= 0 || i >= 400 { snap.x = true; break }
            kids.append(toSnap(child, depth: depth + 1, budget: &budget))
        }
        snap.c = kids
        return snap
    }

    // MARK: 读取

    static func load() -> ScanSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScanSnapshot.self, from: data)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func toFNode(_ snap: SnapNode) -> FNode {
        let kind = FileKind.allCases[min(snap.k, FileKind.allCases.count - 1)]
        return FNode(
            name: snap.n,
            size: snap.s,
            isDir: snap.d,
            modified: snap.t.map { Date(timeIntervalSince1970: $0) },
            children: (snap.c ?? []).map { toFNode($0) },
            kind: kind,
            kindSize: snap.s
        )
    }
}
