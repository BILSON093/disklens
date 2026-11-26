import AppKit
import Foundation

// 生成 DiskLens 应用图标：深蓝紫渐变 + 树图方块 + 玻璃质感高光
let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func drawIcon(size s: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

    let inset = s * 0.085
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.235
    let clay = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 1) 底色渐变（左上偏青蓝 → 右下偏紫）
    ctx.saveGState()
    ctx.addPath(clay)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.24, green: 0.47, blue: 0.98, alpha: 1),
        CGColor(red: 0.36, green: 0.36, blue: 0.96, alpha: 1),
        CGColor(red: 0.50, green: 0.28, blue: 0.92, alpha: 1)
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY),
                           options: [])

    // 2) 顶部玻璃高光
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY - body.height * 0.05),
                           options: [])

    // 3) 树图方块
    let pad = body.width * 0.175
    let area = body.insetBy(dx: pad, dy: pad)
    let gap = s * 0.017
    let r = s * 0.030

    func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ alpha: CGFloat) {
        let rect = CGRect(x: area.minX + area.width * x,
                          y: area.minY + area.height * y,
                          width: area.width * w - gap,
                          height: area.height * h - gap)
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

        // 轻微投影增加层次
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006),
                      blur: s * 0.018,
                      color: CGColor(red: 0.10, green: 0.08, blue: 0.35, alpha: 0.22))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }

    block(0.00, 0.54, 0.46, 0.46, 0.97)
    block(0.48, 0.54, 0.52, 0.25, 0.66)
    block(0.48, 0.81, 0.52, 0.19, 0.44)
    block(0.00, 0.00, 0.31, 0.52, 0.50)
    block(0.33, 0.00, 0.36, 0.52, 0.34)
    block(0.71, 0.00, 0.29, 0.52, 0.24)

    // 4) 内描边，让边缘更利落
    ctx.restoreGState()
    ctx.addPath(clay)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()

    img.unlockFocus()
    return img
}

for s in sizes {
    let img = drawIcon(size: CGFloat(s))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(s)x\(s).png"))
}
print("icon png written")
