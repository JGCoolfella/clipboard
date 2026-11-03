import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (size, scale) in sizes {
    let pixels = size * scale
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let outer = CGPath(roundedRect: CGRect(x: 65, y: 65, width: 894, height: 894), cornerWidth: 200, cornerHeight: 200, transform: nil)
    context.saveGState()
    context.addPath(outer); context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.32, alpha: 1), CGColor(gray: 0.2, alpha: 1)] as CFArray, locations: [0, 0.6, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 960), end: CGPoint(x: 800, y: 70), options: [])
    context.setFillColor(CGColor(gray: 1, alpha: 0.12)); context.fillEllipse(in: CGRect(x: -60, y: 480, width: 950, height: 780))
    context.restoreGState()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 25, color: CGColor(gray: 0, alpha: 0.2))
    context.setFillColor(CGColor(gray: 1, alpha: 0.25)); context.addPath(CGPath(roundedRect: CGRect(x: 245, y: 230, width: 480, height: 540), cornerWidth: 60, cornerHeight: 60, transform: nil)); context.fillPath()
    context.setFillColor(CGColor(gray: 1, alpha: 0.96)); context.addPath(CGPath(roundedRect: CGRect(x: 290, y: 190, width: 480, height: 540), cornerWidth: 60, cornerHeight: 60, transform: nil)); context.fillPath()
    context.restoreGState()
    context.setFillColor(CGColor(gray: 0.4, alpha: 1)); context.addPath(CGPath(roundedRect: CGRect(x: 405, y: 685, width: 250, height: 100), cornerWidth: 32, cornerHeight: 32, transform: nil)); context.fillPath()
    context.setFillColor(CGColor(gray: 0.45, alpha: 0.26))
    for (y, width) in [(550, 285), (440, 285), (330, 185)] { context.addPath(CGPath(roundedRect: CGRect(x: 385, y: y, width: width, height: 36), cornerWidth: 18, cornerHeight: 18, transform: nil)); context.fillPath() }
    let image = context.makeImage()!
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
}
