import Foundation
import Darwin
import AppKit

// MARK: - 内存状态

struct MemStats {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Double = 0      // 0–1，越高越紧张
}

struct ProcUsage {
    let pid: Int32
    let name: String
    let rss: UInt64
    let bundleID: String?
}

enum MemoryScanner {

    static func stats() -> MemStats {
        var s = MemStats()

        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0 {
            s.total = total
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if kr == KERN_SUCCESS {
            let free = UInt64(info.free_count) * page
            let speculative = UInt64(info.speculative_count) * page
            let wired = UInt64(info.wire_count) * page
            let compressed = UInt64(info.compressor_page_count) * page
            let internalPages = UInt64(info.internal_page_count) * page
            let purgeable = UInt64(info.purgeable_count) * page
            let external = UInt64(info.external_page_count) * page

            s.wired = wired
            s.compressed = compressed
            s.cached = external
            s.appMemory = internalPages > purgeable ? internalPages - purgeable : internalPages
            s.free = free + speculative
            s.used = s.appMemory + s.wired + s.compressed

            if s.total > 0 {
                s.pressure = min(1, Double(s.wired + s.compressed) / Double(s.total))
            }
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
        }

        return s
    }

    /// 占用最高的进程（RSS），不包含本进程
    static func topProcesses(limit: Int = 8) -> [ProcUsage] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let myPid = ProcessInfo.processInfo.processIdentifier

        var list: [ProcUsage] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]),
                  let rssKB = UInt64(parts[1]) else { continue }
            if pid == myPid { continue }

            let full = String(parts[2])
            var name = (full as NSString).lastPathComponent
            var bid: String? = nil
            if let app = NSRunningApplication(processIdentifier: pid) {
                if let localized = app.localizedName, !localized.isEmpty { name = localized }
                bid = app.bundleIdentifier
            }
            // 过滤内核与系统守护进程的噪声
            if name.hasPrefix("kernel_task") { continue }

            list.append(ProcUsage(pid: pid, name: name, rss: rssKB * 1024, bundleID: bid))
        }

        return Array(list.sorted { $0.rss > $1.rss }.prefix(limit))
    }

    /// 释放内存：purge 只清理文件缓存与可回收页，不会终止任何进程
    static func purge(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"/usr/bin/purge\" with administrator privileges"]
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = Pipe()

            do {
                try p.run()
            } catch {
                completion(false, "无法启动清理进程：\(error.localizedDescription)")
                return
            }
            p.waitUntilExit()

            if p.terminationStatus == 0 {
                completion(true, "")
            } else {
                let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if err.contains("-128") || err.contains("User canceled") {
                    completion(false, "已取消授权")
                } else {
                    completion(false, err.isEmpty ? "清理失败（错误码 \(p.terminationStatus)）" : err)
                }
            }
        }
    }
}
