import Foundation

/// 命令行自检：只跑扫描引擎，不启动界面
enum ScanOnly {
    /// 测试删除链路：--trash a,b,c
    static func trash(paths: [String]) {
        let out = Trasher.move(paths)
        print("ok=\(out.ok) freed=\(out.freed) failed=\(out.failed.count) blocked=\(out.blocked.count)")
        for f in out.failed.prefix(3) { print("  fail: \(f)") }
        for b in out.blocked.prefix(3) { print("  blocked: \(b)") }
        exit(0)
    }

    static func run(path: String) {
        let url = URL(fileURLWithPath: path)
        let engine = ScanEngine()
        var last = Date.distantPast
        let res = engine.scan(root: url) { count, current in
            let now = Date()
            guard now.timeIntervalSince(last) > 2 else { return }
            last = now
            FileHandle.standardError.write("  … \(count) files  \(current)\n".data(using: .utf8)!)
        }
        let gb = Double(res.totalSize) / 1_073_741_824
        print(String(format: "files=%d dirs=%d size=%.1fGB denied=%d time=%.1fs",
                     res.fileCount, res.dirCount, gb, res.denied.count, res.duration))
        print("top: " + res.root.children.prefix(8)
            .map { "\($0.name)=\(String(format: "%.1f", Double($0.size)/1_073_741_824))G" }
            .joined(separator: " "))
        exit(0)
    }
}
