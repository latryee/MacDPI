import AppKit
import Foundation

// Repo-native icon artwork. No downloaded artwork, fonts, or runtime dependencies.
let destination = URL(fileURLWithPath: "MacDPI/Assets.xcassets/AppIcon.appiconset")
let sizes = [16, 32, 128, 256, 512]
var entries = [[String: String]]()
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
        let background = NSBezierPath(roundedRect: rect, xRadius: 206, yRadius: 206)
        NSGradient(starting: NSColor(srgbRed: 0.04, green: 0.18, blue: 0.25, alpha: 1), ending: NSColor(srgbRed: 0.04, green: 0.43, blue: 0.5, alpha: 1))!.draw(in: background, angle: 60)
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: 512, y: 814))
        shield.curve(to: NSPoint(x: 264, y: 702), controlPoint1: NSPoint(x: 420, y: 760), controlPoint2: NSPoint(x: 340, y: 724))
        shield.line(to: NSPoint(x: 286, y: 434))
        shield.curve(to: NSPoint(x: 512, y: 204), controlPoint1: NSPoint(x: 306, y: 326), controlPoint2: NSPoint(x: 416, y: 236))
        shield.curve(to: NSPoint(x: 738, y: 434), controlPoint1: NSPoint(x: 608, y: 236), controlPoint2: NSPoint(x: 718, y: 326))
        shield.line(to: NSPoint(x: 760, y: 702))
        shield.curve(to: NSPoint(x: 512, y: 814), controlPoint1: NSPoint(x: 684, y: 724), controlPoint2: NSPoint(x: 604, y: 760))
        shield.close()
        NSColor.white.withAlphaComponent(0.92).setStroke(); shield.lineWidth = 24; shield.stroke()
        let lines = NSBezierPath()
        for (a,b) in [(NSPoint(x:390,y:584), NSPoint(x:634,y:584)), (NSPoint(x:390,y:584), NSPoint(x:512,y:390)), (NSPoint(x:634,y:584), NSPoint(x:512,y:390))] {
            lines.move(to: a); lines.line(to: b)
        }
        NSColor(srgbRed: 0.4, green: 0.95, blue: 0.79, alpha: 1).setStroke(); lines.lineWidth = 18; lines.stroke()
        for point in [NSPoint(x:390,y:584), NSPoint(x:634,y:584), NSPoint(x:512,y:390)] {
            NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x:point.x-32,y:point.y-32,width:64,height:64)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
        entries.append(["size":"\(size)x\(size)", "idiom":"mac", "filename":filename, "scale":"\(scale)x"])
    }
}
let json: [String: Any] = ["images":entries, "info":["version":1, "author":"xcode"]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
