import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 生成 macOS 应用图标（苹果设计风格：满幅圆角矩形 + 深空渐变 + 简化键盘 + 灯控高亮）
///
/// 用法: swift icon_gen.swift <输出目录>
/// 输出: 1024×1024 PNG，随后由 make_app.sh 用 sips/iconutil 缩放并转 icns
func drawIcon(size: Int) -> CGImage? {
    let w = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!

    guard let ctx = CGContext(data: nil, width: Int(w), height: Int(w),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: w))

    let r = w * 0.2237   // Apple 连续曲率圆角近似

    // MARK: 背景圆角矩形
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: w),
                        cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // 深空蓝黑渐变（左上 → 右下）
    let bgColors = [UIColor(0x0A1420).cgColor, UIColor(0x14263F).cgColor, UIColor(0x1E3A5C).cgColor] as CFArray
    if let g = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: 0, y: w),
                               end: CGPoint(x: w, y: 0),
                               options: [])
    }

    // 顶部柔和高光（模拟玻璃质感）
    let glowColors = [UIColor(0x3D6FB4, alpha: 0.35).cgColor, UIColor(0x3D6FB4, alpha: 0).cgColor] as CFArray
    if let g = CGGradient(colorsSpace: cs, colors: glowColors, locations: nil) {
        ctx.drawRadialGradient(g,
                               startCenter: CGPoint(x: w * 0.30, y: w * 0.18),
                               startRadius: 0,
                               endCenter: CGPoint(x: w * 0.30, y: w * 0.18),
                               endRadius: w * 0.75,
                               options: [])
    }

    // MARK: 键盘（三行错落的圆角键）
    let cols = 5, rows = 3
    let gap = w * 0.030
    let keyW = (w * 0.62 - gap * CGFloat(cols - 1)) / CGFloat(cols)
    let keyH = w * 0.135
    let originX = (w - (w * 0.62)) / 2
    let originY = (w - (keyH * CGFloat(rows) + gap * CGFloat(rows - 1))) / 2 + w * 0.03

    // 高亮键位置（第 2 行第 3 列）
    let hiRow = 1, hiCol = 2

    for row in 0..<rows {
        // 每行左右错落，模拟真实键盘的阶梯感
        let indent: CGFloat
        switch row {
        case 0: indent = 0
        case 1: indent = keyW * 0.30
        default: indent = keyW * 0.15
        }
        for col in 0..<cols where !(row == 0 && col == cols - 1) {
            let x = originX + indent + CGFloat(col) * (keyW + gap)
            let y = originY + CGFloat(row) * (keyH + gap)
            let rect = CGRect(x: x, y: y, width: keyW, height: keyH)
            let cr = keyW * 0.26
            let path = CGPath(roundedRect: rect, cornerWidth: cr, cornerHeight: cr, transform: nil)

            if row == hiRow && col == hiCol {
                // 高亮键：苹果橙渐变 + 外发光
                let haloColors = [UIColor(0xFF9F0A, alpha: 0.55).cgColor,
                                  UIColor(0xFF9F0A, alpha: 0).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: cs, colors: haloColors, locations: nil) {
                    ctx.drawRadialGradient(g,
                                           startCenter: CGPoint(x: rect.midX, y: rect.midY),
                                           startRadius: keyW * 0.45,
                                           endCenter: CGPoint(x: rect.midX, y: rect.midY),
                                           endRadius: keyW * 1.5,
                                           options: [])
                }
                let hiColors = [UIColor(0xFFB340).cgColor, UIColor(0xFF8A00).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: cs, colors: hiColors, locations: nil) {
                    ctx.saveGState()
                    ctx.addPath(path)
                    ctx.clip()
                    ctx.drawLinearGradient(g,
                                           start: CGPoint(x: rect.minX, y: rect.maxY),
                                           end: CGPoint(x: rect.maxX, y: rect.minY),
                                           options: [])
                    ctx.restoreGState()
                }
                // 键面内侧高光
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                let sheen = [UIColor(0xFFFFFF, alpha: 0.45).cgColor,
                             UIColor(0xFFFFFF, alpha: 0.0).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: cs, colors: sheen, locations: nil) {
                    ctx.drawLinearGradient(g,
                                           start: CGPoint(x: rect.midX, y: rect.maxY),
                                           end: CGPoint(x: rect.midX, y: rect.midY),
                                           options: [])
                }
                ctx.restoreGState()
                ctx.addPath(path)
                ctx.setStrokeColor(UIColor(0xFFFFFF, alpha: 0.6).cgColor)
                ctx.setLineWidth(w * 0.006)
                ctx.strokePath()
            } else {
                // 普通键：半透明白，底部微弱渐变营造立体感
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                let keyColors = [UIColor(0xFFFFFF, alpha: 0.92).cgColor,
                                 UIColor(0xD8E4F2, alpha: 0.78).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: cs, colors: keyColors, locations: nil) {
                    ctx.drawLinearGradient(g,
                                           start: CGPoint(x: rect.midX, y: rect.maxY),
                                           end: CGPoint(x: rect.midX, y: rect.minY),
                                           options: [])
                }
                ctx.restoreGState()
                ctx.addPath(path)
                ctx.setStrokeColor(UIColor(0xFFFFFF, alpha: 0.35).cgColor)
                ctx.setLineWidth(w * 0.004)
                ctx.strokePath()
            }
        }
    }

    // MARK: 底部柔和反光，让图标更通透
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: w),
                       cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    let sheen = [UIColor(0xFFFFFF, alpha: 0.10).cgColor,
                 UIColor(0xFFFFFF, alpha: 0.0).cgColor] as CFArray
    if let g = CGGradient(colorsSpace: cs, colors: sheen, locations: nil) {
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: w / 2, y: w),
                               end: CGPoint(x: w / 2, y: w * 0.45),
                               options: [])
    }
    ctx.restoreGState()

    return ctx.makeImage()
}

struct UIColor {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ hex: Int, alpha: CGFloat = 1.0) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
        a = alpha
    }
    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [r, g, b, a])!
    }
}

// MARK: - main

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

guard let img = drawIcon(size: 1024) else {
    fputs("生成图标失败\n", stderr); exit(1)
}
let url = URL(fileURLWithPath: outDir + "/AppIcon1024.png")
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("无法创建目标\n", stderr); exit(1)
}
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fputs("写入失败\n", stderr); exit(1) }
print("已生成 \(url.path)")
