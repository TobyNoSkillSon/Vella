import AppKit
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.065, green: 0.067, blue: 0.085, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 224, yRadius: 224).fill()
NSColor(calibratedRed: 0.77, green: 0.71, blue: 0.99, alpha: 1).setFill()
for (i, height) in [180.0, 350.0, 540.0, 350.0, 180.0].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 270 + Double(i) * 100, y: 512 - height / 2, width: 64, height: height), xRadius: 32, yRadius: 32).fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
