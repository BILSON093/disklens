import Foundation
import AppKit

// MARK: - 已安装应用

struct Leftover {
    let path: String
    let label: String
    let size: Int64
    let risk: String
}

struct AppInfo {
    let path: String
    let name: String
    let bundleID: String
    let version: String
    var size: Int64
    let icon: String
    let leftovers: [Leftover]
    let isSystem: Bool
}

enum AppScanner {

    /// 应用可能存放的位置
    static var searchRoots: [String] {
        var roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        let utils = "/Applications/Utilities"
        if FileManager.default.fileExists(atPath: utils) { roots.append(utils) }
        return roots
    }

    static func installedApps(progress: (String) -> Void) -> [AppInfo] {
        var paths: [String] = []
        let fm = FileManager.default

        for root in searchRoots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names where n.hasSuffix(".app") {
                paths.append(root + "/" + n)
            }
        }

        var results = [AppInfo?](repeating: nil, count: paths.count)
        let lock = NSLock()
        var done = 0

        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let p = paths[i]
            let info = inspect(path: p)
            lock.lock()
            results[i] = info
            done += 1
            let d = done
            lock.unlock()
            if d % 4 == 0 { progress("已分析 \(d)/\(paths.count)") }
        }

        return results.compactMap { $0 }.sorted { $0.size > $1.size }
    }

    // MARK: 单个应用

    private static func inspect(path: String) -> AppInfo? {
        let url = URL(fileURLWithPath: path)
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]

        let bundleID = (info["CFBundleIdentifier"] as? String) ?? ""
        let display = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String) ?? "—"

        let size: Int64 = 0   // 体积稍后增量计算，避免阻塞列表
        let leftovers = findLeftovers(bundleID: bundleID, appName: display,
                                      appPath: path)
        return AppInfo(
            path: path,
            name: display,
            bundleID: bundleID,
            version: version,
            size: size,
            icon: "",   // 图标按需加载，避免一次性传输数 MB
            leftovers: leftovers,
            isSystem: path.hasPrefix("/System/")
        )
    }

    static func directorySize(path: String) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: path) else { return 0 }
        let base = path.hasSuffix("/") ? path : path + "/"
        for case let rel as String in en {
            var st = stat()
            guard lstat(base + rel, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFREG {
                total += Int64(st.st_blocks) * 512
            }
        }
        return total
    }

    static func iconDataURL(for path: String) -> String {
        let img = NSWorkspace.shared.icon(forFile: path)
        let side: CGFloat = 64
        let target = NSImage(size: NSSize(width: side, height: side))
        target.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                 from: .zero, operation: .copy, fraction: 1)
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    // MARK: 残留匹配

    private static func findLeftovers(bundleID: String, appName: String, appPath: String) -> [Leftover] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var out: [Leftover] = []
        var seen = Set<String>()

        func add(_ path: String, _ label: String, _ risk: String) {
            guard !seen.contains(path), fm.fileExists(atPath: path) else { return }
            seen.insert(path)
            out.append(Leftover(path: path, label: label, size: 0, risk: risk))
        }

        if !bundleID.isEmpty {
            let idPaths: [(String, String)] = [
                ("\(home)/Library/Containers/\(bundleID)", "沙盒容器"),
                ("\(home)/Library/Application Scripts/\(bundleID)", "应用脚本"),
                ("\(home)/Library/Application Support/\(bundleID)", "应用数据"),
                ("\(home)/Library/Caches/\(bundleID)", "缓存"),
                ("\(home)/Library/Preferences/\(bundleID).plist", "偏好设置"),
                ("\(home)/Library/Saved Application State/\(bundleID).savedState", "窗口状态"),
                ("\(home)/Library/WebKit/\(bundleID)", "WebKit 数据"),
                ("\(home)/Library/HTTPStorages/\(bundleID)", "网络存储"),
                ("\(home)/Library/HTTPStorages/\(bundleID).binarycookies", "Cookie"),
                ("\(home)/Library/Cookies/\(bundleID).binarycookies", "Cookie"),
                ("\(home)/Library/Logs/\(bundleID)", "日志"),
                ("\(home)/Library/LaunchAgents/\(bundleID).plist", "登录项"),
                ("/Library/Application Support/\(bundleID)", "全局应用数据"),
                ("/Library/Caches/\(bundleID)", "全局缓存"),
                ("/Library/Preferences/\(bundleID).plist", "全局偏好设置"),
                ("/Library/LaunchDaemons/\(bundleID).plist", "后台服务"),
                ("/Library/LaunchAgents/\(bundleID).plist", "全局登录项")
            ]
            for (p, label) in idPaths {
                add(p, label, p.hasPrefix("/Library/") ? "谨慎" : "安全")
            }

            // Group Containers 常以 TeamID. 前缀包含 bundle id
            let gc = "\(home)/Library/Group Containers"
            if let groups = try? fm.contentsOfDirectory(atPath: gc) {
                for g in groups where g.contains(bundleID) {
                    add(gc + "/" + g, "共享容器", "安全")
                }
            }
        }

        // 按应用显示名匹配（模糊，标为谨慎）
        let nameCandidates: [(String, String)] = [
            ("\(home)/Library/Application Support/\(appName)", "应用数据"),
            ("\(home)/Library/Caches/\(appName)", "缓存"),
            ("\(home)/Library/Logs/\(appName)", "日志"),
            ("\(home)/Library/Preferences/\(appName).plist", "偏好设置"),
            ("\(home)/Library/Containers/\(appName)", "容器")
        ]
        for (p, label) in nameCandidates {
            add(p, label + "（按名称匹配）", "谨慎")
        }

        // 卸载后可能残留的启动项
        let la = "\(home)/Library/LaunchAgents"
        if let items = try? fm.contentsOfDirectory(atPath: la) {
            for f in items where f.lowercased().contains(appName.lowercased()) && f.hasSuffix(".plist") {
                add(la + "/" + f, "登录项", "安全")
            }
        }

        _ = appPath
        return out.sorted { $0.size > $1.size }
    }

    static func sizeOf(_ path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) == S_IFREG { return Int64(st.st_blocks) * 512 }
        return directorySize(path: path)
    }
}
