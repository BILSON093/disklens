import Foundation
import CoreGraphics
import ImageIO
import AppKit

// MARK: - 相似照片

struct PhotoItem {
    let path: String
    let name: String
    let size: Int64
    let modified: Date?
    let width: Int
    let height: Int
}

struct PhotoGroup {
    let hash: UInt64
    let files: [PhotoItem]
}

enum SimilarScanner {

    /// 可参与比对的图片扩展名
    static let photoExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp"
    ]

    /// 256 位差值哈希（16×16 dHash）。位数越多越能区分构图相近但不同的照片，
    /// 对缩放、重压缩、轻微调色依然不敏感。
    static func dHash(path: String) -> (hi: UInt64, lo: UInt64, w: Int, h: Int, rgb: (Int, Int, Int))? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        // 原始分辨率取自元数据，缩略图本身只有 64px
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pw = (props?[kCGImagePropertyPixelWidth] as? Int) ?? img.width
        let ph = (props?[kCGImagePropertyPixelHeight] as? Int) ?? img.height
        guard pw >= 64, ph >= 64 else { return nil }

        // 画到 17x16 灰度图，横向比较相邻像素 → 256 位
        let gw = 17, gh = 16
        var pixels = [UInt8](repeating: 0, count: gw * gh)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: gw, height: gh,
                bitsPerComponent: 8, bytesPerRow: gw,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: gw, height: gh))
            return true
        }
        guard ok else { return nil }

        var hi: UInt64 = 0, lo: UInt64 = 0
        for row in 0..<gh {
            for col in 0..<16 {
                let a = pixels[row * gw + col]
                let b = pixels[row * gw + col + 1]
                guard a > b else { continue }
                let bit = row * 16 + col
                if bit < 64 { lo |= (1 << UInt64(bit)) }
                else { hi |= (1 << UInt64(bit - 64)) }
            }
        }
        // 顺带取平均色：同一张图的不同版本颜色几乎一致，不同照片通常差很多
        var rgba = [UInt8](repeating: 0, count: 4 * 4 * 4)
        var rgb: (Int, Int, Int) = (128, 128, 128)
        _ = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(
                data: buf.baseAddress, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            c.interpolationQuality = .medium
            c.draw(img, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            return true
        }
        var rs = 0, gs = 0, bs = 0
        for i in 0..<16 {
            rs += Int(rgba[i * 4]); gs += Int(rgba[i * 4 + 1]); bs += Int(rgba[i * 4 + 2])
        }
        rgb = (rs / 16, gs / 16, bs / 16)

        return (hi, lo, pw, ph, rgb)
    }

    /// 平均色差异（0–255），用于排除"构图像但颜色完全不同"的误判
    static func colorDistance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        (abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)) / 3
    }

    static func distance(_ a: (UInt64, UInt64), _ b: (UInt64, UInt64)) -> Int {
        (a.0 ^ b.0).nonzeroBitCount + (a.1 ^ b.1).nonzeroBitCount
    }

    /// 主入口：返回相似组（每组 ≥2 张）
    static func find(images: [FileEntry],
                     tolerance: Int,
                     progress: (String, Double) -> Void) -> [PhotoGroup] {

        let candidates = images.filter {
            photoExts.contains($0.ext) && $0.size >= 20_000
        }
        guard candidates.count > 1 else { return [] }

        progress("正在分析 \(candidates.count) 张图片…", 0.02)

        var items = [PhotoItem?](repeating: nil, count: candidates.count)
        var hashes = [(UInt64, UInt64)](repeating: (0, 0), count: candidates.count)
        var valid = [Bool](repeating: false, count: candidates.count)
        var colors = [(Int, Int, Int)](repeating: (0, 0, 0), count: candidates.count)

        let lock = NSLock()
        var done = 0
        let total = candidates.count

        DispatchQueue.concurrentPerform(iterations: total) { i in
            let f = candidates[i]
            if let r = dHash(path: f.path) {
                let item = PhotoItem(path: f.path, name: f.name, size: f.size,
                                     modified: f.modified, width: r.w, height: r.h)
                // Swift Array 并发写下标不安全，统一加锁
                lock.lock()
                items[i] = item
                hashes[i] = (r.hi, r.lo)
                colors[i] = r.rgb
                valid[i] = true
                lock.unlock()
            }
            lock.lock()
            done += 1
            let d = done
            lock.unlock()
            if d % 120 == 0 {
                progress("已分析 \(d)/\(total) 张", 0.02 + 0.83 * Double(d) / Double(total))
            }
        }

        progress("正在聚类…", 0.88)

        // BK-tree 做汉明距离近邻搜索，避免两两比对
        let tree = BKTree()
        var parent = Array(0..<total)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = root(a), rb = root(b)
            if ra != rb { parent[rb] = ra }
        }

        // 同一个哈希可能对应多张图（灰度结构相同、颜色不同），因此存列表
        var byHash: [String: [Int]] = [:]
        func key(_ h: (UInt64, UInt64)) -> String { "\(h.0)-\(h.1)" }

        for i in 0..<total where valid[i] {
            let h = hashes[i]
            let k = key(h)
            var linked = false

            // 1) 灰度哈希完全相同的候选，仍需颜色校验
            if let sameList = byHash[k] {
                for other in sameList where SimilarScanner.colorDistance(colors[other], colors[i]) <= 30 {
                    union(other, i)
                    linked = true
                    break
                }
            }

            // 2) 哈希相近的候选，再按平均色筛一遍
            if !linked {
                let near = tree.query(h, tolerance: tolerance)
                    .filter { SimilarScanner.colorDistance(colors[$0], colors[i]) <= 30 }
                if let anchor = near.first {
                    if ProcessInfo.processInfo.environment["DL_DEBUG_SIM"] != nil {
                        FileHandle.standardError.write("union \(candidates[anchor].name) <- \(candidates[i].name)\n".data(using: .utf8)!)
                    }
                    union(anchor, i)
                }
            }

            byHash[k, default: []].append(i)
            if !linked { tree.insert(index: i, hash: h) }
        }

        progress("整理结果…", 0.95)

        var buckets: [Int: [Int]] = [:]
        for i in 0..<total where valid[i] {
            buckets[root(i), default: []].append(i)
        }

        var groups: [PhotoGroup] = []
        for (_, idxs) in buckets where idxs.count > 1 {
            let files = idxs.compactMap { items[$0] }.sorted { $0.size > $1.size }
            guard files.count > 1 else { continue }
            groups.append(PhotoGroup(hash: hashes[idxs[0]].1, files: files))
        }

        progress("完成", 1.0)

        // 可回收空间大的排前面
        return groups.sorted {
            let a = ($0.files.dropFirst().reduce(Int64(0)) { $0 + $1.size })
            let b = ($1.files.dropFirst().reduce(Int64(0)) { $0 + $1.size })
            return a > b
        }
    }
}

// MARK: - BK 树（汉明距离近邻）

final class BKTree {

    private final class Node {
        let hash: (UInt64, UInt64)
        var index: Int
        var children: [Int: Node] = [:]
        init(hash: (UInt64, UInt64), index: Int) {
            self.hash = hash
            self.index = index
        }
    }

    private var root: Node?

    func insert(index: Int, hash: (UInt64, UInt64)) {
        guard let root else {
            self.root = Node(hash: hash, index: index)
            return
        }
        var current = root
        while true {
            let d = SimilarScanner.distance(hash, current.hash)
            if d == 0 { return }
            if let next = current.children[d] {
                current = next
            } else {
                current.children[d] = Node(hash: hash, index: index)
                return
            }
        }
    }

    func query(_ hash: (UInt64, UInt64), tolerance: Int) -> [Int] {
        guard let root else { return [] }
        var results: [Int] = []
        var stack = [root]

        while let node = stack.popLast() {
            let d = SimilarScanner.distance(hash, node.hash)
            if d <= tolerance { results.append(node.index) }
            let low = max(0, d - tolerance)
            let high = d + tolerance
            if low <= high {
                for (dist, child) in node.children where dist >= low && dist <= high {
                    stack.append(child)
                }
            }
        }
        return results
    }
}
