import AppKit
import Foundation

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
