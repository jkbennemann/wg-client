// Renders the WG Client app-icon master PNG (1024×1024) to the path given as arg 1.
// Pure CoreGraphics so it runs headless. Design: a macOS "squircle" with a blue→indigo
// gradient and a white shield carrying a keyhole (secure-tunnel motif). Deliberately
// distinct from the official WireGuard mark.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("context")
}
let s = CGFloat(S)

// --- rounded-rect background (macOS icon grid: 824pt content, 100pt margins) ---
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
let bg = CGPath(roundedRect: rect, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()
let gradColors = [
    CGColor(red: 0.30, green: 0.57, blue: 1.00, alpha: 1),
    CGColor(red: 0.12, green: 0.23, blue: 0.62, alpha: 1),
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: gradColors, locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: margin, y: s - margin),
                       end: CGPoint(x: s - margin, y: margin),
                       options: [])
ctx.restoreGState()

// --- white shield ---
let cx = s / 2
let sw: CGFloat = 400        // shield width
let topY: CGFloat = 770      // top edge (CG y-up)
let botY: CGFloat = 250      // bottom point
let midY: CGFloat = 470      // where the sides begin curving in
let left = cx - sw / 2
let right = cx + sw / 2
let cornerR: CGFloat = 46

let shield = CGMutablePath()
shield.move(to: CGPoint(x: left, y: topY - cornerR))
shield.addQuadCurve(to: CGPoint(x: left + cornerR, y: topY), control: CGPoint(x: left, y: topY))
shield.addLine(to: CGPoint(x: right - cornerR, y: topY))
shield.addQuadCurve(to: CGPoint(x: right, y: topY - cornerR), control: CGPoint(x: right, y: topY))
shield.addLine(to: CGPoint(x: right, y: midY))
shield.addQuadCurve(to: CGPoint(x: cx, y: botY), control: CGPoint(x: right, y: botY + 30))
shield.addQuadCurve(to: CGPoint(x: left, y: midY), control: CGPoint(x: left, y: botY + 30))
shield.closeSubpath()

// subtle drop shadow under the shield
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
ctx.addPath(shield)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// --- keyhole (gradient-blue), centered in the shield ---
let holeColor = CGColor(red: 0.16, green: 0.30, blue: 0.72, alpha: 1)
let holeCenter = CGPoint(x: cx, y: 575)
let holeR: CGFloat = 62
ctx.setFillColor(holeColor)
ctx.addEllipse(in: CGRect(x: holeCenter.x - holeR, y: holeCenter.y - holeR, width: holeR * 2, height: holeR * 2))
ctx.fillPath()
let slot = CGMutablePath()   // tapered slot below the circle
slot.move(to: CGPoint(x: cx - 30, y: holeCenter.y))
slot.addLine(to: CGPoint(x: cx + 30, y: holeCenter.y))
slot.addLine(to: CGPoint(x: cx + 52, y: 452))
slot.addLine(to: CGPoint(x: cx - 52, y: 452))
slot.closeSubpath()
ctx.addPath(slot)
ctx.fillPath()

// --- export PNG ---
guard let image = ctx.makeImage() else { fatalError("image") }
let url = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("dest")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write") }
print("wrote \(outPath)")
