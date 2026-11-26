import AppKit
import Foundation

// 命令行删除测试
if let i = CommandLine.arguments.firstIndex(of: "--trash"), i + 1 < CommandLine.arguments.count {
    ScanOnly.trash(paths: CommandLine.arguments[i + 1].split(separator: ",").map(String.init))
}

// 命令行自检模式
if let i = CommandLine.arguments.firstIndex(of: "--scanonly"), i + 1 < CommandLine.arguments.count {
    ScanOnly.run(path: CommandLine.arguments[i + 1])
}

// 全局持有 delegate，NSApplication.delegate 是弱引用
let appDelegate = AppDelegate()

let application = NSApplication.shared
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
