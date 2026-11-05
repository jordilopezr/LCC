// Regenerates the macOS app icon from assets/app_icon_transparent.png:
//   swift scripts/make_macos_icon.swift assets/app_icon_transparent.png /tmp/icon_1024.png
//   for s in 16 32 64 128 256 512 1024; do sips -z $s $s /tmp/icon_1024.png --out macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$s.png; done
import AppKit
let args = CommandLine.arguments
// The source PNG is tagged with an HDR Rec.2020 PQ profile that makes AppKit
// oversaturate it; its pixel values are plain sRGB (that is how Linux shows it).
let srcRep = (NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!).retagging(with: .sRGB)!
let logo = NSImage(size: NSSize(width: srcRep.pixelsWide, height: srcRep.pixelsHigh))
logo.addRepresentation(srcRep)
let size = 1024
let rep = (NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))!.retagging(with: .sRGB)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// macOS icon grid: 824x824 body centered, ~185 corner radius, soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 20
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()
// Logo fitted to 620px wide, centered.
let lw: CGFloat = 620
let lh = lw * logo.size.height / logo.size.width
let lr = NSRect(x: (CGFloat(size) - lw) / 2, y: (CGFloat(size) - lh) / 2 - 8, width: lw, height: lh)
logo.draw(in: lr, from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
