import Foundation

// MARK: - 文件类型

enum FileKind: String, CaseIterable, Identifiable {
    case video = "视频"
    case image = "图片"
    case audio = "音频"
    case code = "代码"
    case archive = "压缩包"
    case document = "文档"
    case app = "应用"
    case data = "数据"
    case other = "其他"

    var id: String { rawValue }

    var color: String {
        switch self {
        case .video: return "#7262fd"
        case .image: return "#f6bd16"
        case .audio: return "#f08bb4"
        case .code: return "#5b8ff9"
        case .archive: return "#f6903d"
        case .document: return "#61ddaa"
        case .app: return "#008685"
        case .data: return "#9661bc"
        case .other: return "#9aa2b1"
        }
    }

    var icon: String {
        switch self {
        case .video: return "film.fill"
        case .image: return "photo.fill"
        case .audio: return "music.note"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archive: return "shippingbox.fill"
        case .document: return "doc.text.fill"
        case .app: return "app.fill"
        case .data: return "cylinder.split.1x2.fill"
        case .other: return "doc.fill"
        }
    }

    static func of(ext: String) -> FileKind {
        switch ext {
        case "mp4", "mov", "mkv", "avi", "webm", "flv", "wmv", "m4v", "mpg", "mpeg":
            return .video
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "tif", "svg", "raw", "psd", "ai":
            return .image
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff", "ape":
            return .audio
        case "swift", "js", "ts", "tsx", "jsx", "py", "java", "go", "rs", "c", "cpp", "h", "m", "mm",
             "rb", "php", "sh", "zsh", "bash", "html", "css", "scss", "vue", "kt", "dart", "lua", "sql":
            return .code
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso":
            return .archive
        case "pdf", "doc", "docx", "pages", "txt", "md", "rtf", "xls", "xlsx", "numbers",
             "ppt", "pptx", "key", "csv", "epub":
            return .document
        case "db", "sqlite", "sqlite3", "realm", "plist", "json", "xml", "yaml", "yml",
             "safetensors", "ckpt", "gguf", "bin", "img", "rpa", "pak", "dat", "blob",
             "assets", "bundle", "car", "nib", "momd":
            return .data
        case "app": return .app
        default: return .other
        }
    }
}

// MARK: - 文件树节点

struct FNode {
    let name: String
    var size: Int64
    let isDir: Bool
    var modified: Date?
    var children: [FNode]
    /// 子树中占比最大的文件类型（用于着色）
    var kind: FileKind
    var kindSize: Int64

    var colorSeed: Int {
        var h = 5381
        for b in name.utf8 { h = (h &* 33) &+ Int(b) }
        return abs(h)
    }

    var icon: String { isDir ? "folder.fill" : kind.icon }
}

// MARK: - 文件条目

struct FileEntry {
    let path: String
    let name: String
    let size: Int64
    let modified: Date?
    let accessed: Date?
    let ext: String
    let inode: UInt64
    let device: UInt64

    var kind: FileKind { FileKind.of(ext: ext) }

    /// 硬链接唯一标识：同一 inode 的多个路径只算一份数据
    var fileKey: String { "\(device):\(inode)" }
}

// MARK: - 聚合

struct KindStat {
    let kind: FileKind
    let size: Int64
    let count: Int
}

struct AppStat {
    let name: String
    let path: String
    let size: Int64
    let count: Int
    let kind: FileKind
}

// MARK: - 扫描结果

struct ScanResult {
    var rootPath: String
    var root: FNode
    var allFiles: [FileEntry]
    var totalSize: Int64
    var fileCount: Int
    var dirCount: Int
    var denied: [String]
    var duration: TimeInterval
    var kindStats: [KindStat]
    var appStats: [AppStat]
}

// MARK: - 垃圾分类

enum JunkCategory: String, CaseIterable, Identifiable {
    case cache = "应用缓存"
    case log = "日志与崩溃报告"
    case temp = "临时文件"
    case metadata = "系统元数据"
    case installer = "安装包残留"
    case buildArtifact = "工程构建产物"
    case trash = "废纸篓"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cache: return "internaldrive"
        case .log: return "doc.text.magnifyingglass"
        case .temp: return "clock.arrow.circlepath"
        case .metadata: return "tag"
        case .installer: return "shippingbox"
        case .buildArtifact: return "hammer"
        case .trash: return "trash"
        }
    }
}

enum Risk: String {
    case safe = "安全"
    case careful = "谨慎"
}

struct JunkItem {
    let path: String
    let name: String
    let size: Int64
    let category: JunkCategory
    let risk: Risk
    let reason: String
    let isDirectory: Bool
}

// MARK: - 重复文件组

struct DupGroup {
    let hash: String
    let size: Int64
    var files: [FileEntry]
    /// 组内不同 inode 数量；小于文件数说明存在硬链接，删除不会释放全部空间
    var uniqueInodes: Int = 0

    var reclaimable: Int64 { size * Int64(max(0, uniqueInodes - 1)) }
    var hasHardlink: Bool { uniqueInodes < files.count }
}

// MARK: - 侧栏模块

enum AppMode: String, CaseIterable, Identifiable {
    case explorer = "空间树图"
    case kinds = "类型分析"
    case large = "大文件"
    case junk = "垃圾文件"
    case duplicates = "重复文件"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .explorer: return "square.grid.2x2.fill"
        case .kinds: return "chart.pie.fill"
        case .large: return "arrow.up.right.square.fill"
        case .junk: return "trash.slash.fill"
        case .duplicates: return "doc.on.doc.fill"
        }
    }
}

// MARK: - 格式化

enum Fmt {
    static func size(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(Int(v)) B" }
        return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func shorten(_ path: String, max: Int = 60) -> String {
        guard path.count > max else { return path }
        return "…" + path.suffix(max - 3)
    }
}
