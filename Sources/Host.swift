import AppKit
import WebKit
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ImageIO

// MARK: - 支持拖入应用的 WebView

protocol AppDropDelegate: AnyObject {
    func dragEntered(paths: [String])
    func dragExited()
    func dropped(paths: [String])
}

final class DropWebView: WKWebView {

    weak var dropDelegate: AppDropDelegate?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func filePaths(_ sender: NSDraggingInfo) -> [String] {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.map { $0.resolvingSymlinksInPath().path }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let paths = filePaths(sender)
        guard !paths.isEmpty else { return [] }
        dropDelegate?.dragEntered(paths: paths)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        filePaths(sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropDelegate?.dragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !filePaths(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = filePaths(sender)
        guard !paths.isEmpty else { return false }
        dropDelegate?.dropped(paths: paths)
        return true
    }
}

// MARK: - 顶部拖动条

/// WKWebView 内部有私有内容视图会先接走鼠标事件，
/// 重写 WKWebView 的 mouseDown 不起作用，必须在它上面叠一层视图。
final class DragBarView: NSView {

    /// 左侧留出红绿灯按钮区域，避免挡住关闭/最小化
    private let trafficLightWidth: CGFloat = 84

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sup = superview else { return nil }
        let local = convert(point, from: sup)
        if local.x < trafficLightWidth { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - 应用入口

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: DropWebView!
    private let bridge = Bridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "native")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = DropWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        bridge.attach(webView)
        webView.dropDelegate = bridge

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DiskLens 磁盘透视"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 1040, height: 660)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1240, height: 820))
        container.autoresizingMask = [.width, .height]

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let dragBar = DragBarView()
        dragBar.frame = NSRect(x: 0, y: container.bounds.height - 28,
                               width: container.bounds.width, height: 28)
        dragBar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(dragBar)

        window.contentView = container
        bridge.hostWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<h2 style='font-family:-apple-system;padding:40px'>界面资源缺失</h2>", baseURL: nil)
        }

        NSApp.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments

        // 自检：--hittest x,y 打印该点命中的视图类型
        if let i = args.firstIndex(of: "--hittest"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let pt = NSPoint(x: parts[0], y: parts[1])
                    let hit = self.window.contentView?.hitTest(pt)
                    print("HITTEST \(pt): \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                    // 顶部点还应报出它的父链，确认落在 DragBarView
                    if let h = hit {
                        var chain: [String] = []
                        var v: NSView? = h
                        while let cur = v, cur !== self.window.contentView {
                            chain.append(String(describing: type(of: cur)))
                            v = cur.superview
                        }
                        print("CHAIN: " + chain.joined(separator: " < "))
                    }
                    NSApp.terminate(nil)
                }
            }
        }

        // 自检模式：--snapshot <目录> <输出png> [tab]
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count {
            let dir = args[i + 1]
            let out = args[i + 2]
            let tab: String? = (i + 3 < args.count && !args[i + 3].hasPrefix("--")) ? args[i + 3] : nil
            let probeJS: String? = {
                guard let j = args.firstIndex(of: "--probe"), j + 1 < args.count else { return nil }
                return args[j + 1]
            }()

            bridge.onScanDone = { [weak self] () -> Void in
                guard let self else { return }
                if let probeJS {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.webView.evaluateJavaScript(probeJS) { result, error in
                            print("PROBE: \(result ?? error?.localizedDescription ?? "nil")")
                            NSApp.terminate(nil)
                        }
                    }
                    return
                }
                if let tab {
                    DispatchQueue.main.async {
                        self.webView.evaluateJavaScript(
                            "document.querySelector('[data-mode=\"\(tab)\"]').click(); S.mode;") { r, e in
                            print("click -> \(String(describing: r)) err=\(String(describing: e))")
                        }
                    }
                    if let probeJS {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            self.webView.evaluateJavaScript(probeJS) { r, e in
                                print("PROBE: \(r ?? e?.localizedDescription ?? "nil")")
                                NSApp.terminate(nil)
                            }
                        }
                        return
                    }
                    if args.contains("--script") {
                        if let si = args.firstIndex(of: "--script"), si + 1 < args.count {
                            let js = args[si + 1]
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                DispatchQueue.main.async {
                                    self.webView.evaluateJavaScript(js, completionHandler: nil)
                                }
                            }
                        }
                        var delay = 8.0
                        if let di = args.firstIndex(of: "--delay"), di + 1 < args.count,
                           let v = Double(args[di + 1]) { delay = v }
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.writeSnapshot(out) }
                        return
                    }
                    if tab == "duplicates" && !args.contains("--script") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            DispatchQueue.main.async {
                                self.webView.evaluateJavaScript(
                                    "document.getElementById('dupScan').click();", completionHandler: nil)
                            }
                        }
                        if args.contains("--focus") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                                DispatchQueue.main.async {
                                    self.webView.evaluateJavaScript(
                                        "document.querySelector('.frow')?.click();", completionHandler: nil)
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 19) { self.writeSnapshot(out) }
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { self.writeSnapshot(out) }
                        return
                    }
                    if let ci = args.firstIndex(of: "--click"), ci + 1 < args.count {
                        let sel = args[ci + 1]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            DispatchQueue.main.async {
                                self.webView.evaluateJavaScript(
                                    "document.querySelector('\(sel)')?.click();", completionHandler: nil)
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.writeSnapshot(out) }
                        return
                    }
                }
                if args.contains("--drill") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        DispatchQueue.main.async {
                            self.webView.evaluateJavaScript(
                                "document.querySelector('.childlist .row').click();", completionHandler: nil)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { self.writeSnapshot(out) }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.writeSnapshot(out) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.bridge.debugScan(path: dir)
            }
        }

        if let i = args.firstIndex(of: "--sleep"), i + 1 < args.count, let n = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + n) {
                print("ALIVE after \(n)s")
                NSApp.terminate(nil)
            }
        }

        if let i = args.firstIndex(of: "--probe"), i + 1 < args.count, !args.contains("--snapshot") {
            let js = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.webView.evaluateJavaScript(js) { result, error in
                    print("PROBE: \(result ?? error?.localizedDescription ?? "nil")")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func writeSnapshot(_ out: String) {
        webView.takeSnapshot(with: nil) { image, _ in
            if let image,
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
                print("snapshot written: \(out)")
            }
            NSApp.terminate(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面就绪后回放上次扫描结果，避免每次都重新扫
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.bridge.loadCachedScan()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 DiskLens", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 DiskLens", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DiskLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - 历史记录

struct HistoryRecord: Codable {
    var path: String
    var total: Int64
    var files: Int
    var date: Date
}

enum History {
    static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("DiskLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> [HistoryRecord] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return [] }
        return list
    }

    static func previous(for path: String) -> HistoryRecord? {
        load().filter { $0.path == path }.max { $0.date < $1.date }
    }

    static func save(_ record: HistoryRecord) {
        guard let url = fileURL else { return }
        var list = load().filter { !($0.path == record.path && abs($0.date.timeIntervalSince(record.date)) < 5) }
        list.append(record)
        if list.count > 200 { list = Array(list.suffix(200)) }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url) }
    }
}

// MARK: - 通信桥

final class Bridge: NSObject, WKScriptMessageHandler, AppDropDelegate {

    private weak var webView: WKWebView?
    weak var hostWindow: NSWindow?
    private var result: ScanResult?
    private var junkItems: [JunkItem] = []
    private var isScanning = false
    private var isDupRunning = false
    private var apps: [AppInfo] = []
    private var largeCache: [FileEntry] = []
    private var isCachedResult = false
    private var cachedDate: Date?
    private var isAppScanning = false
    private var isSimilarRunning = false
    var onScanDone: (() -> Void)?

    func attach(_ web: WKWebView) { webView = web }

    func debugScan(path: String) { startScan(path: path) }

    // MARK: JS → Native

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "scan":
            let raw = body["path"] as? String ?? ""
            startScan(path: raw.isEmpty ? NSHomeDirectory() : raw)
        case "chooseFolder":
            chooseFolder()
        case "children":
            sendChildren(path: body["path"] as? String ?? "")
        case "junk":
            sendJunk()
        case "aggregates":
            sendAggregates()
        case "largeFiles":
            sendLargeFiles(minSize: (body["minSize"] as? NSNumber)?.int64Value ?? 500_000_000)
        case "listApps":
            startAppScan()
        case "findSimilar":
            let tol = (body["tolerance"] as? NSNumber)?.intValue ?? 14
            startSimilar(tolerance: tol,
                         minSize: (body["minSize"] as? NSNumber)?.int64Value ?? 0)
        case "findDuplicateVideos":
            startDuplicates(minSize: (body["minSize"] as? NSNumber)?.int64Value ?? 10_485_760,
                            extensions: Self.videoExtensions)
        case "findDuplicates":
            startDuplicates(minSize: (body["minSize"] as? NSNumber)?.int64Value ?? 1_048_576)
        case "trash":
            performTrash(body["paths"] as? [String] ?? [])
        case "export":
            export(scope: body["scope"] as? String ?? "junk")
        case "reveal":
            if let p = body["path"] as? String {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }
        case "open":
            if let p = body["path"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        case "openPrivacy":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case "memoryInfo":
            sendMemory()
        case "cleanMemory":
            cleanMemory()
        case "quitProcess":
            if let pid = body["pid"] as? Int { quitProcess(pid: Int32(pid), force: false) }
        case "forceQuitProcess":
            if let pid = body["pid"] as? Int { quitProcess(pid: Int32(pid), force: true) }
        case "inspectApp":
            if let p = body["path"] as? String { sendAppInfo(path: p) }
        case "appIcon":
            if let p = body["path"] as? String {
                emit(["type": "appIcon", "path": p, "data": AppScanner.iconDataURL(for: p)])
            }
        case "thumbnail":
            if let p = body["path"] as? String {
                makeThumbnail(path: p, size: (body["size"] as? NSNumber)?.doubleValue ?? 96)
            }
        case "diskInfo":
            let raw = body["path"] as? String ?? ""
            sendDiskInfo(path: raw.isEmpty ? NSHomeDirectory() : raw)
        case "log":
            print("JSERR: \(body["message"] ?? "")")
        default:
            break
        }
    }

    // MARK: 发送

    private func emit(_ payload: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            webView.evaluateJavaScript("window.native && window.native.on(\(json));", completionHandler: nil)
        }
    }

    /// 能否读取受 TCC 保护的目录（等价于完全磁盘访问是否生效）
    private static func hasFullDiskAccess() -> Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Safari",
            "/Library/Application Support/com.apple.TCC"
        ]
        for p in probes {
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil { return true }
        }
        return false
    }

    // MARK: 扫描

    private func startScan(path: String) {
        guard !isScanning else { return }
        isScanning = true
        junkItems = []
        result = nil

        let url = URL(fileURLWithPath: path)
        emit(["type": "scanStarted", "path": path])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let engine = ScanEngine()

            var lastEmit = Date.distantPast
            let res = engine.scan(root: url) { count, current in
                if count % 200_000 == 0 {
                    FileHandle.standardError.write("scan progress: \(count) files \(current)\n".data(using: .utf8)!)
                }
                let now = Date()
                guard now.timeIntervalSince(lastEmit) > 0.12 else { return }
                lastEmit = now
                self.emit(["type": "progress", "files": count, "path": current])
            }

            let junk = JunkScanner.analyze(files: res.allFiles, rootPath: res.rootPath)
            let arts = JunkScanner.artifactDirs(root: res.root, rootPath: res.rootPath)
            let merged = (junk + arts).sorted { $0.size > $1.size }

            let previous = History.previous(for: res.rootPath)
            History.save(HistoryRecord(path: res.rootPath, total: res.totalSize,
                                       files: res.fileCount, date: Date()))

            self.result = res
            self.junkItems = merged
            self.isScanning = false

            self.emit([
                "type": "scanDone",
                "rootName": res.root.name,
                "rootPath": res.rootPath,
                "totalSize": res.totalSize,
                "fileCount": res.fileCount,
                "dirCount": res.dirCount,
                "deniedCount": res.denied.count,
                "deniedSamples": Array(res.denied.prefix(8)),
                "hasFDA": Self.hasFullDiskAccess(),
                "duration": res.duration,
                "junkCount": merged.count,
                "junkSize": merged.reduce(Int64(0)) { $0 + $1.size },
                "prevTotal": previous?.total ?? -1,
                "prevDate": previous.map { ISO8601DateFormatter().string(from: $0.date) } ?? ""
            ])
            DispatchQueue.main.async { self.onScanDone?() }

            // 落盘，供下次打开直接回放
            self.largeCache = res.allFiles
                .filter { $0.size >= 100 * 1024 * 1024 }
                .sorted { $0.size > $1.size }
                .prefix(500)
                .map { $0 }
            SnapshotStore.save(res, junk: merged, files: res.allFiles)
        }
    }

    /// 混合内容的目录用一组区分度更高的颜色
    static let nodePalette = [
        "#5b8ff9", "#61ddaa", "#f6bd16", "#7262fd", "#78d3f8",
        "#9661bc", "#f6903d", "#008685", "#f08bb4", "#52c41a"
    ]

    static func paletteColor(_ name: String) -> String {
        var h = 5381
        for b in name.utf8 { h = (h &* 33) &+ Int(b) }
        return nodePalette[abs(h) % nodePalette.count]
    }

    /// 按路径逐级定位节点
    private func node(at path: String) -> FNode? {
        guard let res = result else { return nil }
        let root = res.root
        if path == res.rootPath { return root }
        guard path.hasPrefix(res.rootPath) else { return nil }
        let base = res.rootPath.hasSuffix("/") ? res.rootPath : res.rootPath + "/"
        let rel = String(path.dropFirst(base.count))
        var current = root
        for part in rel.split(separator: "/").map(String.init) {
            guard let next = current.children.first(where: { $0.name == part }) else { return nil }
            current = next
        }
        return current
    }

    private func sendChildren(path: String) {
        guard let node = node(at: path) else {
            emit(["type": "children", "path": path, "items": [], "total": 0])
            return
        }
        let base = path.hasSuffix("/") ? path : path + "/"
        let limited = node.children.prefix(400)
        let items: [[String: Any]] = limited.map { c in
            // 主导类型占比不足 55%、或主要成分是"其他"时，按名字散列取色，
            // 否则大片目录都会是同一个灰色，失去区分度
            let share = c.size > 0 ? Double(c.kindSize) / Double(c.size) : 1
            let mixed = c.isDir && (share < 0.55 || c.kind == .other)
            var d: [String: Any] = [
                "name": c.name, "path": base + c.name, "size": c.size, "isDir": c.isDir,
                "icon": c.icon,
                "kind": mixed ? "混合" : c.kind.rawValue,
                "color": mixed ? Self.paletteColor(c.name) : c.kind.color,
                "mixed": mixed
            ]
            if let m = c.modified { d["modified"] = ISO8601DateFormatter().string(from: m) }
            return d
        }
        emit([
            "type": "children", "path": path, "name": node.name, "size": node.size,
            "truncated": node.isDir && node.children.isEmpty && node.size > 0,
            "kind": node.kind.rawValue, "color": node.kind.color,
            "items": items, "total": node.children.count
        ])
    }

    private func sendJunk() {
        let limited = junkItems.prefix(2500)
        let items: [[String: Any]] = limited.map { j in
            [
                "path": j.path, "name": j.name, "size": j.size,
                "category": j.category.rawValue, "risk": j.risk.rawValue,
                "reason": j.reason, "isDir": j.isDirectory
            ]
        }
        emit([
            "type": "junk", "items": items, "total": junkItems.count,
            "shown": items.count, "totalSize": junkItems.reduce(Int64(0)) { $0 + $1.size }
        ])
    }

    private func sendAggregates() {
        guard let result else { return }
        let kinds: [[String: Any]] = result.kindStats.map {
            ["kind": $0.kind.rawValue, "color": $0.kind.color, "size": $0.size, "count": $0.count]
        }
        let apps: [[String: Any]] = result.appStats.prefix(120).map {
            ["name": $0.name, "path": $0.path, "size": $0.size, "count": $0.count,
             "kind": $0.kind.rawValue, "color": $0.kind.color]
        }
        emit(["type": "aggregates", "kinds": kinds, "apps": apps, "total": result.totalSize])
    }

    private func sendLargeFiles(minSize: Int64) {
        guard let result else { return }
        let now = Date()
        let pool = result.allFiles.isEmpty ? largeCache : result.allFiles
        let files = pool
            .filter { $0.size >= minSize }
            .sorted { $0.size > $1.size }
            .prefix(600)

        let items: [[String: Any]] = files.map { f in
            var d: [String: Any] = [
                "path": f.path, "name": f.name, "size": f.size,
                "kind": f.kind.rawValue, "color": f.kind.color, "ext": f.ext
            ]
            if let m = f.modified { d["modified"] = ISO8601DateFormatter().string(from: m) }
            if let a = f.accessed {
                d["accessed"] = ISO8601DateFormatter().string(from: a)
                d["idleDays"] = Int(now.timeIntervalSince(max(a, f.modified ?? a)) / 86400)
            } else if let m = f.modified {
                d["idleDays"] = Int(now.timeIntervalSince(m) / 86400)
            }
            return d
        }
        let matched = pool.filter { $0.size >= minSize }
        emit([
            "type": "largeFiles", "items": Array(items), "count": matched.count,
            "totalSize": matched.reduce(Int64(0)) { $0 + $1.size }, "minSize": minSize
        ])
    }

    // MARK: 缓存的上次扫描

    func loadCachedScan() {
        guard result == nil, let snap = SnapshotStore.load() else { return }
        // 缓存的目录已被删除或移走时不再回放，避免展示不存在的路径
        guard FileManager.default.fileExists(atPath: snap.path) else {
            SnapshotStore.clear()
            return
        }

        let root = SnapshotStore.toFNode(snap.tree)
        let kinds: [KindStat] = snap.kinds.compactMap {
            guard let k = FileKind(rawValue: $0.k) else { return nil }
            return KindStat(kind: k, size: $0.s, count: $0.c)
        }
        let apps: [AppStat] = snap.apps.map {
            AppStat(name: $0.n, path: $0.p, size: $0.s, count: $0.c,
                    kind: FileKind(rawValue: $0.k) ?? .other)
        }

        result = ScanResult(rootPath: snap.path, root: root, allFiles: [],
                            totalSize: snap.totalSize, fileCount: snap.fileCount,
                            dirCount: snap.dirCount, denied: [], duration: 0,
                            kindStats: kinds, appStats: apps)
        junkItems = snap.junk.compactMap {
            guard let cat = JunkCategory(rawValue: $0.c), let risk = Risk(rawValue: $0.r) else { return nil }
            return JunkItem(path: $0.p, name: $0.n, size: $0.s, category: cat,
                            risk: risk, reason: $0.rs, isDirectory: $0.d)
        }
        largeCache = snap.large.map {
            FileEntry(path: $0.p, name: $0.n, size: $0.s,
                      modified: $0.m.map { Date(timeIntervalSince1970: $0) },
                      accessed: $0.a.map { Date(timeIntervalSince1970: $0) },
                      ext: $0.e, inode: 0, device: 0)
        }
        isCachedResult = true
        cachedDate = snap.date

        emit([
            "type": "scanDone",
            "rootName": root.name,
            "rootPath": snap.path,
            "totalSize": snap.totalSize,
            "fileCount": snap.fileCount,
            "dirCount": snap.dirCount,
            "deniedCount": snap.deniedCount,
            "deniedSamples": [],
            "duration": 0,
            "junkCount": junkItems.count,
            "junkSize": junkItems.reduce(Int64(0)) { $0 + $1.size },
            "prevTotal": -1,
            "prevDate": "",
            "fromCache": true,
            "hasFDA": Self.hasFullDiskAccess(),
            "scannedAt": ISO8601DateFormatter().string(from: snap.date)
        ])
    }

    // MARK: 拖拽

    func dragEntered(paths: [String]) {
        let apps = paths.filter { $0.hasSuffix(".app") }
        emit(["type": "dragEnter", "appCount": apps.count, "fileCount": paths.count])
    }

    func dragExited() {
        emit(["type": "dragExit"])
    }

    func dropped(paths: [String]) {
        emit(["type": "dragExit"])
        let apps = paths.filter { $0.hasSuffix(".app") }
        guard !apps.isEmpty else {
            emit(["type": "dropRejected",
                  "reason": "只能拖入 .app 应用包（拖进来的是 \(paths.count) 个其它项）"])
            return
        }
        if apps.count > 1 {
            emit(["type": "dropInfo", "reason": "一次只处理一个应用，已取第一个"])
        }
        sendAppInfo(path: apps[0], focus: true)
    }

    // MARK: 内存

    private func sendMemory() {
        let s = MemoryScanner.stats()
        let procs = MemoryScanner.topProcesses()
        emit([
            "type": "memory",
            "total": s.total, "used": s.used, "appMemory": s.appMemory,
            "wired": s.wired, "compressed": s.compressed, "cached": s.cached,
            "free": s.free, "swapUsed": s.swapUsed, "pressure": s.pressure,
            "processes": procs.map {
                ["pid": Int($0.pid), "name": $0.name, "rss": $0.rss,
                 "bundleID": $0.bundleID ?? ""]
            }
        ])
    }

    private func cleanMemory() {
        let before = MemoryScanner.stats()
        emit(["type": "memoryCleaning"])
        MemoryScanner.purge { [weak self] ok, message in
            guard let self else { return }
            let after = MemoryScanner.stats()
            let freed = before.used > after.used ? before.used - after.used : 0
            self.emit([
                "type": "memoryCleaned", "ok": ok, "message": message,
                "freed": freed,
                "stats": [
                    "total": after.total, "used": after.used, "appMemory": after.appMemory,
                    "wired": after.wired, "compressed": after.compressed,
                    "cached": after.cached, "free": after.free,
                    "swapUsed": after.swapUsed, "pressure": after.pressure
                ]
            ])
            self.sendMemory()
        }
    }

    private func quitProcess(pid: Int32, force: Bool) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            emit(["type": "quitResult", "ok": false, "pid": Int(pid), "message": "该进程已不存在"])
            return
        }
        let name = app.localizedName ?? "该进程"

        if force {
            let ok = app.forceTerminate()
            emit(["type": "quitResult", "ok": ok, "forced": true, "pid": Int(pid),
                  "message": ok ? "已强制退出 \(name)，未保存的修改可能丢失"
                                : "无法强制退出 \(name)，可能属于系统进程"])
            return
        }

        guard app.terminate() else {
            emit(["type": "quitBlocked", "pid": Int(pid), "name": name,
                  "message": "\(name) 拒绝退出请求"])
            return
        }

        // 给应用 2.5 秒正常退出，超时则交给用户决定是否强制
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let still = NSRunningApplication(processIdentifier: pid)
            if still == nil || still?.isTerminated == true {
                self.emit(["type": "quitResult", "ok": true, "pid": Int(pid),
                           "message": "已退出 \(name)"])
            } else {
                self.emit(["type": "quitBlocked", "pid": Int(pid), "name": name,
                           "message": "\(name) 没有响应退出请求（可能在等待保存或已卡住）。可再次点击强制退出，但未保存的内容会丢失。"])
            }
        }
    }

    // MARK: 单个应用信息

    private func sendAppInfo(path: String, focus: Bool = false) {
        guard FileManager.default.fileExists(atPath: path) else {
            emit(["type": "appInfoFailed", "path": path, "reason": "找不到这个应用，可能已被移除"])
            return
        }
        // 体积要遍历目录，放到后台算，避免卡住界面
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard var a = AppScanner.inspectApp(path: path) else {
                self.emit(["type": "appInfoFailed", "path": path,
                           "reason": "无法读取应用的 Info.plist，可能不是标准 .app 包"])
                return
            }
            a.size = AppScanner.directorySize(path: path)

            // 逐个算出残留体积
            var leftovers: [Leftover] = []
            for l in a.leftovers {
                leftovers.append(Leftover(path: l.path, label: l.label,
                                          size: AppScanner.sizeOf(l.path), risk: l.risk))
            }
            a = AppInfo(path: a.path, name: a.name, bundleID: a.bundleID, version: a.version,
                        size: a.size, icon: a.icon, leftovers: leftovers,
                        isSystem: a.isSystem, lastUsed: a.lastUsed, installed: a.installed,
                        isRunning: a.isRunning)

            self.emit(["type": "appInfo", "app": self.appPayload(a), "focus": focus])
        }
    }

    private func appPayload(_ a: AppInfo) -> [String: Any] {
        let items: [[String: Any]] = a.leftovers.map {
            ["path": $0.path, "label": $0.label, "size": $0.size, "risk": $0.risk]
        }
        return [
            "name": a.name, "path": a.path, "bundleID": a.bundleID,
            "version": a.version, "size": a.size, "icon": "",
            "lastUsed": a.lastUsed.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "installed": a.installed.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "isSystem": a.isSystem, "isRunning": a.isRunning,
            "leftoverSize": a.leftovers.reduce(Int64(0)) { $0 + $1.size },
            "leftovers": items
        ]
    }

    // MARK: 已安装应用

    private func startAppScan() {
        guard !isAppScanning else { return }
        isAppScanning = true
        emit(["type": "appsStarted"])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var last = Date.distantPast
            let list = AppScanner.installedApps { msg in
                let now = Date()
                guard now.timeIntervalSince(last) > 0.2 else { return }
                last = now
                self.emit(["type": "appProgress", "message": msg])
            }

            self.apps = list
            self.isAppScanning = false

            var payload: [[String: Any]] = list.map { a in
                let items: [[String: Any]] = a.leftovers.map {
                    ["path": $0.path, "label": $0.label, "size": $0.size, "risk": $0.risk]
                }
                return [
                    "name": a.name, "path": a.path, "bundleID": a.bundleID,
                    "version": a.version, "size": a.size, "icon": "",
                    "lastUsed": a.lastUsed.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                    "installed": a.installed.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                    "isSystem": a.isSystem,
                    "leftoverSize": a.leftovers.reduce(Int64(0)) { $0 + $1.size },
                    "leftovers": items
                ]
            }

            self.emit([
                "type": "appsDone",
                "apps": payload,
                "count": list.count,
                "totalSize": 0,
                "leftoverSize": list.reduce(Int64(0)) { $0 + $1.leftovers.reduce(Int64(0)) { $0 + $1.size } }
            ])

            // 体积在后台逐个填充，列表先可用
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                for (i, a) in list.enumerated() {
                    let appSize = AppScanner.directorySize(path: a.path)
                    var loTotal: Int64 = 0
                    var loPayload: [[String: Any]] = []
                    for l in a.leftovers {
                        let s = AppScanner.sizeOf(l.path)
                        loTotal += s
                        loPayload.append(["path": l.path, "size": s])
                    }
                    self.apps[i].size = appSize
                    self.emit([
                        "type": "appDetail",
                        "path": a.path,
                        "size": appSize,
                        "leftoverSize": loTotal,
                        "leftovers": loPayload,
                        "done": i + 1,
                        "total": list.count
                    ])
                }
            }

            self.apps = list
        }
    }

    // MARK: 相似照片

    private func startSimilar(tolerance: Int, minSize: Int64 = 0) {
        guard let result, !isSimilarRunning else { return }
        guard !result.allFiles.isEmpty else {
            emit(["type": "needRescan", "reason": "图片比对需要完整文件清单，请先重新扫描"])
            return
        }
        isSimilarRunning = true
        // 体积筛选同样适用于照片：太小的图标/缩略图参与比对只会增加噪声
        let images = result.allFiles.filter { $0.size >= minSize }
        emit(["type": "similarStarted"])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var last = Date.distantPast
            let groups = SimilarScanner.find(images: images, tolerance: tolerance) { msg, p in
                let now = Date()
                guard now.timeIntervalSince(last) > 0.2 else { return }
                last = now
                self.emit(["type": "similarProgress", "message": msg, "value": p])
            }

            var payload: [[String: Any]] = []
            for g in groups.prefix(300) {
                var fs: [[String: Any]] = []
                for f in g.files {
                    var d: [String: Any] = [
                        "path": f.path, "name": f.name, "size": f.size,
                        "width": f.width, "height": f.height
                    ]
                    if let m = f.modified { d["modified"] = ISO8601DateFormatter().string(from: m) }
                    fs.append(d)
                }
                let reclaimable = g.files.dropFirst().reduce(Int64(0)) { $0 + $1.size }
                payload.append([
                    "hash": String(format: "%016llx", g.hash),
                    "size": g.files[0].size,
                    "reclaimable": reclaimable,
                    "files": fs
                ])
            }

            self.isSimilarRunning = false
            self.emit([
                "type": "similarDone",
                "groups": payload,
                "count": groups.count,
                "reclaimable": groups.reduce(Int64(0)) {
                    $0 + $1.files.dropFirst().reduce(Int64(0)) { $0 + $1.size }
                }
            ])
        }
    }

    // MARK: 查重

    /// 常见视频容器格式
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm",
        "mpg", "mpeg", "ts", "m2ts", "3gp", "rmvb", "rm", "vob"
    ]

    private func startDuplicates(minSize: Int64, extensions: Set<String>? = nil) {
        guard let result, !isDupRunning else { return }
        guard !result.allFiles.isEmpty else {
            emit(["type": "needRescan", "reason": "查重需要完整的文件清单，请先重新扫描"])
            return
        }
        isDupRunning = true
        let files = result.allFiles
        emit(["type": "dupStarted"])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var last = Date.distantPast
            let groups = DupScanner.find(files: files, minSize: minSize,
                                         extensions: extensions) { msg, p in
                let now = Date()
                guard now.timeIntervalSince(last) > 0.15 else { return }
                last = now
                self.emit(["type": "dupProgress", "message": msg, "value": p])
            }

            var payload: [[String: Any]] = []
            for g in groups.prefix(400) {
                var fs: [[String: Any]] = []
                var linkIndex: [String: Int] = [:]
                for f in g.files {
                    let key = f.fileKey
                    if linkIndex[key] == nil { linkIndex[key] = linkIndex.count }
                    var d: [String: Any] = ["path": f.path, "name": f.name,
                                            "size": f.size, "linkId": linkIndex[key]!]
                    if let m = f.modified { d["modified"] = ISO8601DateFormatter().string(from: m) }
                    fs.append(d)
                }
                payload.append([
                    "hash": g.hash, "size": g.size, "reclaimable": g.reclaimable,
                    "hardlink": g.hasHardlink, "uniqueInodes": g.uniqueInodes,
                    "files": fs
                ])
            }

            self.isDupRunning = false
            self.emit([
                "type": "dupDone", "groups": payload, "count": groups.count,
                "reclaimable": groups.reduce(Int64(0)) { $0 + $1.reclaimable }
            ])
        }
    }

    // MARK: 删除

    private func performTrash(_ paths: [String]) {
        guard !paths.isEmpty else { return }

        let blocked = paths.filter { Trasher.isProtected($0) }
        let allowed = paths.filter { !Trasher.isProtected($0) }

        guard !allowed.isEmpty else {
            emit(["type": "trashDone", "ok": 0, "freed": 0, "failed": [], "paths": [], "blocked": blocked])
            return
        }

        // 缓存结果没有完整文件清单，回退到大文件缓存或树节点
        let totalSize = allowed.reduce(Int64(0)) { acc, p in
            if let f = result?.allFiles.first(where: { $0.path == p }) { return acc + f.size }
            if let f = largeCache.first(where: { $0.path == p }) { return acc + f.size }
            if let n = node(at: p) { return acc + n.size }
            return acc
        }

        // 测试环境可跳过确认框
        if ProcessInfo.processInfo.environment["DL_AUTOCONFIRM"] == "1" {
            executeTrash(allowed, blocked: blocked)
            return
        }

        let alert = NSAlert()
        alert.messageText = "将 \(allowed.count) 个项目移到废纸篓？"
        var info = "预计释放 \(Fmt.size(totalSize))。项目进入废纸篓后，清空才会真正归还空间，也可以先拖回来。"
        if !blocked.isEmpty {
            info += "\n其中 \(blocked.count) 项位于系统受保护位置，将被跳过。"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        // 用挂载在窗口上的 sheet，避免弹窗被主窗口挡住
        NSApp.activate(ignoringOtherApps: true)
        if let win = hostWindow {
            alert.beginSheetModal(for: win) { [weak self] resp in
                guard resp == .alertFirstButtonReturn else {
                    self?.emit(["type": "trashCancelled"])
                    return
                }
                self?.executeTrash(allowed, blocked: blocked)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            executeTrash(allowed, blocked: blocked)
        } else {
            emit(["type": "trashCancelled"])
        }
    }

    private func executeTrash(_ allowed: [String], blocked: [String]) {
        // 删除前记录体积，用于更新树图
        var deletedSizes: [String: Int64] = [:]
        for p in allowed {
            if let f = result?.allFiles.first(where: { $0.path == p }) { deletedSizes[p] = f.size }
            else if let n = node(at: p) { deletedSizes[p] = n.size }
        }

        let res = Trasher.move(allowed)
        let set = Set(allowed)

        junkItems.removeAll { set.contains($0.path) }
        applyDeletions(deletedSizes)

        emit([
            "type": "trashDone", "ok": res.ok, "freed": res.freed,
            "failed": res.failed, "blocked": blocked,
            "paths": Array(set),
            "newTotal": result?.totalSize ?? 0,
            "newFileCount": result?.fileCount ?? 0
        ])

        // 让磁盘上的快照与当前状态保持一致
        if var res2 = result {
            res2.allFiles = res2.allFiles.filter { !set.contains($0.path) }
            res2.fileCount = max(0, res2.fileCount - set.count)
            let remainingJunk = junkItems
            let cachedLarge = largeCache.filter { !set.contains($0.path) }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                SnapshotStore.save(res2, junk: remainingJunk, files: res2.allFiles.isEmpty ? cachedLarge : res2.allFiles)
            }
        }
    }

    /// 从树里扣掉已删节点，保持界面数字一致
    private func applyDeletions(_ deleted: [String: Int64]) {
        guard var res = result else { return }
        var root = res.root
        subtract(&root, basePath: res.rootPath, deleted: deleted)
        res.root = root
        res.totalSize = root.size
        result = res
    }

    @discardableResult
    private func subtract(_ node: inout FNode, basePath: String, deleted: [String: Int64]) -> Int64 {
        var delta: Int64 = 0
        var kept: [FNode] = []
        kept.reserveCapacity(node.children.count)
        let base = basePath.hasSuffix("/") ? basePath : basePath + "/"

        for child in node.children {
            let childPath = base + child.name
            if deleted[childPath] != nil {
                delta += child.size
                continue
            }
            var c = child
            if c.isDir { delta += subtract(&c, basePath: childPath, deleted: deleted) }
            kept.append(c)
        }

        node.children = kept
        node.size = max(0, node.size - delta)
        return delta
    }

    // MARK: 导出

    private func export(scope: String) {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.title = "导出报告"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "DiskLens-\(scope)-\(Self.stamp()).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text: String
        switch scope {
        case "junk":
            var lines = ["名称,大小(字节),类别,风险,路径,说明"]
            for j in junkItems {
                lines.append([j.name, "\(j.size)", j.category.rawValue, j.risk.rawValue, j.path, j.reason]
                    .map(Self.csv).joined(separator: ","))
            }
            text = lines.joined(separator: "\n")
        case "kinds":
            var lines = ["类型,大小(字节),文件数"]
            for k in result.kindStats {
                lines.append([k.kind.rawValue, "\(k.size)", "\(k.count)"].map(Self.csv).joined(separator: ","))
            }
            text = lines.joined(separator: "\n")
        case "apps":
            var lines = ["应用,大小(字节),文件数,路径"]
            for a in result.appStats {
                lines.append([a.name, "\(a.size)", "\(a.count)", a.path].map(Self.csv).joined(separator: ","))
            }
            text = lines.joined(separator: "\n")
        default:
            var lines = ["大小(字节),文件数,目录数,扫描路径,扫描时间"]
            lines.append([ "\(result.totalSize)", "\(result.fileCount)", "\(result.dirCount)",
                           result.rootPath, Self.stamp() ].map(Self.csv).joined(separator: ","))
            text = lines.joined(separator: "\n")
        }

        // 加 BOM，Excel 打开中文不乱码
        let data = ("\u{FEFF}" + text).data(using: .utf8) ?? Data()
        do {
            try data.write(to: url)
            emit(["type": "exported", "path": url.path])
        } catch {
            emit(["type": "exportFailed", "message": error.localizedDescription])
        }
    }

    private static func csv(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    // MARK: 缩略图

    private func makeThumbnail(path: String, size: Double) {
        let req = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: size, height: size),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let self else { return }

            var image: NSImage? = rep?.nsImage
            if image == nil || image!.size.width < 1 {
                // Quick Look 不可用时，自己解码缩放（对图片格式更可靠）
                image = Self.decodeThumbnail(path: path, maxSide: max(64, size))
            }
            guard let image, let png = Self.pngData(from: image) else {
                self.emit(["type": "thumbnail", "path": path, "data": ""])
                return
            }
            self.emit(["type": "thumbnail", "path": path,
                       "data": "data:image/png;base64," + png.base64EncodedString()])
        }
    }

    /// ImageIO 兜底：直接解码图片并缩放，不依赖 Quick Look 服务
    private static func decodeThumbnail(path: String, maxSide: Double) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxSide * 2)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func pngData(from image: NSImage) -> Data? {
        var w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, 340 / max(w, h))
        w *= scale; h *= scale

        let target = NSImage(size: NSSize(width: w, height: h))
        target.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        target.unlockFocus()

        guard let tiff = target.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) else { return nil }
        return bmp.representation(using: .png, properties: [:])
    }

    // MARK: 系统交互

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "扫描此目录"
        panel.message = "选择要分析的目录或磁盘"
        if panel.runModal() == .OK, let url = panel.url {
            emit(["type": "folderChosen", "path": url.path])
        }
    }

    private func sendDiskInfo(path: String) {
        let url = URL(fileURLWithPath: path)
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                     .volumeAvailableCapacityForImportantUsageKey]),
           let total = v.volumeTotalCapacity,
           let free = v.volumeAvailableCapacityForImportantUsage {
            emit(["type": "diskInfo", "free": Int64(free), "total": Int64(total)])
        }
    }
}
