import Foundation
import CryptoKit

// MARK: - 扫描引擎

/// 单次 lstat 取全部属性，顶层子树并行，避免 URL/resourceValues 的额外开销
final class ScanEngine {

    private let lock = NSLock()
    private let fileCounter = Counter()

    /// 小于此体积且与垃圾清理无关的文件，只计入目录体积，不保留完整条目
    private static let keepFloor: Int64 = 64 * 1024

    private static func shouldKeepEntry(size: Int64, path: String, name: String) -> Bool {
        if size >= keepFloor { return true }
        if path.contains("/Caches/") || path.contains("/Logs/") || path.contains("/.Trash/") { return true }
        if name == ".DS_Store" || name.hasPrefix("._") || name.hasSuffix(".tmp") { return true }
        return false
    }

    /// 全盘扫描时必须跳过：/System/Volumes/Data 是数据卷的 firmlink 副本，
    /// 再走一遍会把 /Users、/Library 等全部算两次；/Volumes 是其它磁盘。
    static let skipAbsolute: Set<String> = [
        // 整个 Volumes 一并跳过：Data 是数据卷副本（会翻倍），
        // Preboot / Update / VM 是启动快照与交换文件，含数百万系统文件
        "/System/Volumes",
        "/Volumes",
        "/dev",
        "/net",
        "/home",
        // firmlink 命名空间：里面是整套文件系统的影子副本，扫了会重复计数数倍
        "/.vol",
        "/.nofollow",
        "/.resolve"
    ]

    static func shouldSkip(_ path: String) -> Bool {
        skipAbsolute.contains(path)
    }

    final class Counter {
        private var v = 0
        private let l = NSLock()
        func bump() -> Int { l.lock(); v += 1; let r = v; l.unlock(); return r }
        var value: Int { l.lock(); defer { l.unlock() }; return v }
        func reset() { l.lock(); v = 0; l.unlock() }
    }

    final class FileBox {
        var items: [FileEntry] = []
        init() { items.reserveCapacity(4096) }
    }

    struct Branch {
        var node: FNode
        var dirs: Int
        var denied: [String]
        var kindTotals: [FileKind: Int64]
    }

    // MARK: 入口

    func scan(root url: URL, progress: @escaping (Int, String) -> Void) -> ScanResult {
        let started = Date()
        // 解析符号链接，保证子路径与系统 API（Quick Look、废纸篓）一致
        let rootPath = url.resolvingSymlinksInPath().path
        let rootName = url.lastPathComponent.isEmpty ? rootPath : url.lastPathComponent

        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
        let counter = Counter()
        fileCounter.reset()

        // 先分类顶层条目
        var dirNames: [String] = []
        var topFiles: [FileEntry] = []
        var denied: [String] = []

        for name in names {
            let p = join(rootPath, name)
            if Self.shouldSkip(p) { continue }
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            if isLink(st) { continue }
            if isDir(st) {
                dirNames.append(name)
            } else if let (_, entry) = makeFile(path: p, name: name, st: st), let entry {
                topFiles.append(entry)
            }
        }

        // 顶层目录并行扫描
        var branches = [Branch?](repeating: nil, count: dirNames.count)
        var branchBoxes = [FileBox?](repeating: nil, count: dirNames.count)
        DispatchQueue.concurrentPerform(iterations: dirNames.count) { i in
            let name = dirNames[i]
            let p = self.join(rootPath, name)
            let b = self.walk(path: p, name: name, depth: 1,
                              box: FileBox(), counter: counter, progress: progress,
                              boxOut: { box in
                                  self.lock.lock(); branchBoxes[i] = box; self.lock.unlock()
                              })
            self.lock.lock()
            branches[i] = b
            self.lock.unlock()
        }

        var rootNode = FNode(name: rootName, size: 0, isDir: true,
                             modified: mtime(of: rootPath), children: [],
                             kind: .other, kindSize: 0)
        var files: [FileEntry] = []
        files.reserveCapacity(topFiles.count + 200_000)
        files.append(contentsOf: topFiles)

        var topTotals: [FileKind: Int64] = [:]
        for f in topFiles { topTotals[f.kind, default: 0] += f.size }

        var dirs = dirNames.count
        for (i, b) in branches.enumerated() {
            guard let b else { continue }
            rootNode.children.append(b.node)
            rootNode.size += b.node.size
            if let bb = branchBoxes[i] { files.append(contentsOf: bb.items) }
            dirs += b.dirs
            denied.append(contentsOf: b.denied)
            for (k, v) in b.kindTotals { topTotals[k, default: 0] += v }
        }

        rootNode.size += topFiles.reduce(Int64(0)) { $0 + $1.size }
        rootNode.children.sort { $0.size > $1.size }
        let rootDominant = topTotals.max { $0.value < $1.value }
        rootNode.kind = rootDominant?.key ?? .other
        rootNode.kindSize = rootDominant?.value ?? 0

        let kindStats = Self.aggregateKinds(files)
        let appStats = Self.aggregateApps(files)

        return ScanResult(
            rootPath: rootPath,
            root: rootNode,
            allFiles: files,
            totalSize: rootNode.size,
            fileCount: fileCounter.value,
            dirCount: dirs,
            denied: denied,
            duration: Date().timeIntervalSince(started),
            kindStats: kindStats,
            appStats: appStats
        )
    }

    // MARK: 递归

    private func walk(path: String, name: String, depth: Int,
                      box: FileBox,
                      counter: Counter,
                      progress: @escaping (Int, String) -> Void,
                      boxOut: ((FileBox) -> Void)? = nil) -> Branch {
        var node = FNode(name: name, size: 0, isDir: true,
                         modified: mtime(of: path), children: [],
                         kind: .other, kindSize: 0)

        boxOut?(box)
        var dirs = 1
        var denied: [String] = []
        var totals: [FileKind: Int64] = [:]

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            denied.append(path)
            return Branch(node: node, dirs: 0, denied: denied, kindTotals: [:])
        }

        var children: [FNode] = []
        children.reserveCapacity(names.count)
        var total: Int64 = 0

        // 浅层目录再展开一层并行：全盘扫描时 /Users 这类单分支不会被串行拖住
        let parallelHere = depth <= 2 && names.count > 8
        var results = [Branch?](repeating: nil, count: names.count)
        var fileResults = [(FNode, FileEntry?)?](repeating: nil, count: names.count)
        var subBoxes = [FileBox?](repeating: nil, count: names.count)
        // Swift Array 并发写下标并不安全，必须串行化
        let writeLock = NSLock()

        let body: (Int) -> Void = { i in
            let child = names[i]
            let p = self.join(path, child)
            if Self.shouldSkip(p) { return }
            var st = stat()
            guard lstat(p, &st) == 0 else { return }
            if self.isLink(st) { return }

            if self.isDir(st) {
                if parallelHere {
                    // 并行分支各用独立收集器，避免锁竞争
                    let cb = FileBox()
                    let r = self.walk(path: p, name: child, depth: depth + 1,
                                      box: cb, counter: counter, progress: progress)
                    writeLock.lock()
                    subBoxes[i] = cb
                    results[i] = r
                    writeLock.unlock()
                } else {
                    results[i] = self.walk(path: p, name: child, depth: depth + 1,
                                           box: box, counter: counter, progress: progress)
                }
            } else if let f = self.makeFile(path: p, name: child, st: st) {
                if parallelHere {
                    writeLock.lock(); fileResults[i] = f; writeLock.unlock()
                } else {
                    fileResults[i] = f
                }
            }
        }

        if parallelHere {
            DispatchQueue.concurrentPerform(iterations: names.count, execute: body)
        } else {
            for i in 0..<names.count { body(i) }
        }

        for i in 0..<names.count {
            if let sub = results[i] {
                children.append(sub.node)
                total += sub.node.size
                if parallelHere, let cb = subBoxes[i] { box.items.append(contentsOf: cb.items) }
                dirs += sub.dirs
                denied.append(contentsOf: sub.denied)
                for (k, v) in sub.kindTotals { totals[k, default: 0] += v }
            } else if let (node, entry) = fileResults[i] {
                children.append(node)
                total += node.size
                totals[node.kind, default: 0] += node.size
                if let entry { box.items.append(entry) }
            }

            let n = counter.bump()
            if n % 6000 == 0 { progress(n, path) }
        }

        children.sort { $0.size > $1.size }
        node.children = children
        node.size = total
        let dominant = totals.max { $0.value < $1.value }
        node.kind = dominant?.key ?? .other
        node.kindSize = dominant?.value ?? 0
        return Branch(node: node, dirs: dirs, denied: denied, kindTotals: totals)
    }

    // MARK: 工具

    private func join(_ a: String, _ b: String) -> String {
        a.hasSuffix("/") ? a + b : a + "/" + b
    }

    private func isLink(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFLNK }
    private func isDir(_ st: stat) -> Bool { (st.st_mode & S_IFMT) == S_IFDIR }

    private func mtime(of path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    private func makeFile(path: String, name: String, st: stat) -> (FNode, FileEntry?)? {
        // 稀疏文件用实际分配块数，更贴近真实占用
        let allocated = Int64(st.st_blocks) * 512
        let size = allocated > 0 ? allocated : Int64(st.st_size)
        guard size > 0 else { return nil }

        _ = fileCounter.bump()

        let ext = (name as NSString).pathExtension.lowercased()
        let kind = FileKind.of(ext: ext)
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        let node = FNode(name: name, size: size, isDir: false, modified: modified,
                         children: [], kind: kind, kindSize: size)

        guard Self.shouldKeepEntry(size: size, path: path, name: name) else {
            return (node, nil)
        }

        let entry = FileEntry(
            path: path, name: name, size: size, modified: modified,
            accessed: Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec)),
            ext: ext, inode: UInt64(st.st_ino), device: UInt64(st.st_dev)
        )
        return (node, entry)
    }

    // MARK: 聚合

    static func aggregateKinds(_ files: [FileEntry]) -> [KindStat] {
        var map: [FileKind: (Int64, Int)] = [:]
        for f in files {
            let k = f.kind
            var cur = map[k] ?? (0, 0)
            cur.0 += f.size
            cur.1 += 1
            map[k] = cur
        }
        return map.map { KindStat(kind: $0.key, size: $0.value.0, count: $0.value.1) }
            .sorted { $0.size > $1.size }
    }

    static func aggregateApps(_ files: [FileEntry]) -> [AppStat] {
        var map: [String: (name: String, size: Int64, count: Int, kind: FileKind, kindSize: Int64)] = [:]

        for f in files {
            guard let (key, display) = appKey(for: f.path) else { continue }
            var cur = map[key] ?? (display, 0, 0, .other, 0)
            cur.size += f.size
            cur.count += 1
            let k = f.kind
            if cur.kind == k {
                cur.kindSize += f.size
            } else if f.size > cur.kindSize {
                cur.kind = k
                cur.kindSize = f.size
            }
            map[key] = cur
        }

        return map.map { AppStat(name: $0.value.name, path: $0.key, size: $0.value.size,
                                 count: $0.value.count, kind: $0.value.kind) }
            .sorted { $0.size > $1.size }
    }

    /// 把路径归到「哪个应用」名下
    static func appKey(for path: String) -> (String, String)? {
        let home = NSHomeDirectory()

        if path.hasPrefix("/Applications/") {
            let rest = path.dropFirst("/Applications/".count)
            if let r = rest.range(of: ".app/") {
                let name = String(rest[rest.startIndex..<r.lowerBound])
                return ("/Applications/\(name).app", name)
            }
            if rest.hasSuffix(".app") {
                return (path, String(rest.dropLast(4)))
            }
        }

        let prefixes = [
            "/Library/Containers/",
            "/Library/Group Containers/",
            "/Library/Application Support/",
            "/Library/Caches/",
            "/Library/Preferences/",
            "/Library/Saved Application State/"
        ]

        for prefix in prefixes {
            let full = home + prefix
            guard path.hasPrefix(full) else { continue }
            let rest = path.dropFirst(full.count)
            guard let first = rest.split(separator: "/").first else { continue }
            let id = String(first)
            return (full + id, prettyName(id))
        }

        return nil
    }

    private static func prettyName(_ id: String) -> String {
        if id.contains(".") {
            let parts = id.split(separator: ".")
            if parts.count >= 3, ["com", "cn", "org", "net", "io"].contains(String(parts[0])) {
                return String(parts.suffix(2).joined(separator: "."))
            }
            return String(parts.suffix(1).joined())
        }
        return id
    }
}

// MARK: - 垃圾文件识别

enum JunkScanner {

    private static let installExts: Set<String> = ["dmg", "pkg", "iso"]

    static func analyze(files: [FileEntry], rootPath: String) -> [JunkItem] {
        var items: [JunkItem] = []
        items.reserveCapacity(1024)

        for f in files {
            let p = f.path
            let lower = p.lowercased()

            if lower.contains("/.trash/") {
                items.append(JunkItem(path: p, name: f.name, size: f.size, category: .trash,
                                      risk: .safe, reason: "已在废纸篓中，清空后释放", isDirectory: false))
                continue
            }

            if lower.contains("/library/caches/") || lower.contains("/caches/") {
                items.append(JunkItem(path: p, name: f.name, size: f.size, category: .cache,
                                      risk: .safe, reason: "应用缓存，删除后按需自动重建", isDirectory: false))
                continue
            }

            if lower.contains("diagnosticreports") || f.ext == "crash" || f.ext == "dmp" || f.ext == "ips" {
                items.append(JunkItem(path: p, name: f.name, size: f.size, category: .log,
                                      risk: .safe, reason: "崩溃转储或诊断报告，仅供开发调试", isDirectory: false))
                continue
            }

            if lower.contains("/library/logs/") && (f.ext == "log" || f.ext == "logarchive") {
                items.append(JunkItem(path: p, name: f.name, size: f.size, category: .log,
                                      risk: .safe, reason: "运行日志，排查问题后可清理", isDirectory: false))
                continue
            }

            if f.name == ".DS_Store" || f.name == "Thumbs.db" || f.name.hasPrefix("._") {
                items.append(JunkItem(path: p, name: f.name, size: f.size, category: .metadata,
                                      risk: .safe, reason: "Finder 元数据或资源分支残留", isDirectory: false))
                continue
            }

            if f.ext == "bc" || lower.hasSuffix(".bc!") || f.ext == "crdownload"
                || f.ext == "part" || f.ext == "download" {
                items.append(JunkItem(path: p, name: f.name, size: f.size, category: .temp,
                                      risk: .careful, reason: "下载未完成的分片，可能在写入中", isDirectory: false))
                continue
            }

            if f.ext == "tmp" || f.ext == "temp" {
                items.append(JunkItem(path: p, name: f.name, size: f.size, category: .temp,
                                      risk: .safe, reason: "临时文件，程序退出后无保留价值", isDirectory: false))
                continue
            }

            if lower.hasPrefix("/private/var/folders/") && lower.contains("/c/") {
                items.append(JunkItem(path: p, name: f.name, size: f.size, category: .temp,
                                      risk: .careful, reason: "系统临时区，重启会自动回收", isDirectory: false))
                continue
            }

            if lower.contains("/downloads/") && installExts.contains(f.ext) && f.size > 20 * 1024 * 1024 {
                items.append(JunkItem(path: p, name: f.name, size: f.size, category: .installer,
                                      risk: .careful, reason: "安装镜像，对应应用装好后即可删除", isDirectory: false))
                continue
            }
        }

        return items
    }

    private static let artifactDirs: [String: String] = [
        "node_modules": "Node 依赖，可由 npm/pnpm install 重建",
        ".next": "Next.js 构建缓存，重新构建即生成",
        ".nuxt": "Nuxt 构建缓存，重新构建即生成",
        "dist": "打包产物，可重新构建",
        "build": "构建中间产物，可重新构建",
        "target": "Rust/Java 构建产物，可重新构建",
        "__pycache__": "Python 字节码缓存，自动重建",
        ".venv": "Python 虚拟环境，可重建",
        "venv": "Python 虚拟环境，可重建",
        "DerivedData": "Xcode 派生数据，重新构建即生成",
        ".gradle": "Gradle 缓存，可重建",
        "Pods": "CocoaPods 依赖，可 pod install 重建"
    ]

    static func artifactDirs(root: FNode, rootPath: String, limit: Int = 400) -> [JunkItem] {
        var found: [JunkItem] = []

        func visit(_ node: FNode, base: String, depth: Int) {
            guard depth < 14, found.count < limit else { return }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            for child in node.children where child.isDir {
                let childPath = prefix + child.name
                if let reason = artifactDirs[child.name], child.size > 5 * 1024 * 1024 {
                    found.append(JunkItem(path: childPath, name: child.name, size: child.size,
                                          category: .buildArtifact, risk: .careful,
                                          reason: reason, isDirectory: true))
                } else {
                    visit(child, base: childPath, depth: depth + 1)
                }
            }
        }

        visit(root, base: rootPath, depth: 0)
        return found
    }
}

// MARK: - 重复文件检测

enum DupScanner {

    /// 三阶段查重，并按 inode 去重：硬链接不算可回收空间
    static func find(files: [FileEntry],
                     minSize: Int64,
                     extensions: Set<String>? = nil,
                     progress: (String, Double) -> Void) -> [DupGroup] {

        var bySize: [Int64: [FileEntry]] = [:]
        for f in files where f.size >= minSize {
            // 视频模式只比对指定扩展名
            if let exts = extensions, !exts.contains(f.ext) { continue }
            bySize[f.size, default: []].append(f)
        }
        let candidates = bySize.filter { $0.value.count > 1 }
        let candidateTotal = candidates.reduce(0) { $0 + $1.value.count }
        guard candidateTotal > 0 else { return [] }

        progress("按大小分组：\(candidates.count) 组候选", 0.08)

        // 按 inode 归并：同 inode 的多个路径是同一份数据，删了不释放空间
        var reps: [FileEntry] = []
        var pathsByKey: [String: [FileEntry]] = [:]
        for (_, group) in candidates {
            for f in group {
                let key = f.fileKey
                if pathsByKey[key] == nil {
                    pathsByKey[key] = [f]
                    reps.append(f)
                } else {
                    pathsByKey[key]?.append(f)
                }
            }
        }

        let repTotal = reps.count
        guard repTotal > 0 else { return [] }

        // 首段哈希
        var partial: [String: [FileEntry]] = [:]
        var done = 0
        for f in reps {
            if let h = hash(url: f.path, limit: 4096) {
                partial[h, default: []].append(f)
            }
            done += 1
            if done % 20 == 0 {
                progress("快速比对中…", 0.08 + 0.42 * Double(done) / Double(repTotal))
            }
        }

        // 全文哈希
        var result: [DupGroup] = []
        let refining = partial.filter { $0.value.count > 1 }
        let refineTotal = refining.reduce(0) { $0 + $1.value.count }
        var done2 = 0

        for (_, group) in refining {
            var exact: [String: [FileEntry]] = [:]
            for f in group {
                if let h = hash(url: f.path, limit: nil) {
                    exact[h, default: []].append(f)
                }
                done2 += 1
                if done2 % 10 == 0 {
                    progress("完整校验中…", 0.5 + 0.5 * Double(done2) / Double(max(1, refineTotal)))
                }
            }
            for (h, sameInodes) in exact where sameInodes.count > 1 {
                let allFiles = sameInodes.flatMap { pathsByKey[$0.fileKey] ?? [$0] }
                result.append(DupGroup(hash: h, size: sameInodes[0].size,
                                       files: allFiles, uniqueInodes: sameInodes.count))
            }
        }

        progress("完成", 1.0)
        return result.sorted { $0.reclaimable > $1.reclaimable }
    }

    static func hash(url: String, limit: Int?) -> String? {
        guard let fh = FileHandle(forReadingAtPath: url) else { return nil }
        defer { try? fh.close() }

        var hasher = SHA256()
        do {
            if let limit {
                let data = try fh.read(upToCount: limit) ?? Data()
                hasher.update(data: data)
            } else {
                while true {
                    let chunk = try fh.read(upToCount: 256 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 删除（含安全护栏）

enum Trasher {

    /// 系统关键路径，一律拒绝删除
    static let protectedPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db",
        "/private/var/vm", "/dev", "/cores", "/Library/Apple", "/Library/Extensions"
    ]

    static func isProtected(_ path: String) -> Bool {
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        if p == "/" || p == NSHomeDirectory() { return true }
        return protectedPrefixes.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    struct Outcome {
        var ok: Int = 0
        var freed: Int64 = 0
        var failed: [String] = []
        var blocked: [String] = []
    }

    static func move(_ paths: [String]) -> Outcome {
        var out = Outcome()
        let fm = FileManager.default

        for p in paths {
            if isProtected(p) {
                out.blocked.append(p)
                continue
            }
            let url = URL(fileURLWithPath: p)
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]))
                .map { Int64($0.totalFileAllocatedSize ?? $0.fileSize ?? 0) } ?? 0
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                out.ok += 1
                out.freed += size
            } catch {
                out.failed.append("\(p) — \(error.localizedDescription)")
            }
        }
        return out
    }
}
