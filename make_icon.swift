import AppKit

let projectDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let iconsetPath = "\(projectDir)/build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, name) in sizes {
    let size = NSSize(width: px, height: px)
    let img = NSImage(size: size)
    img.lockFocus()

    let rect = NSRect(origin: .zero, size: size).insetBy(dx: CGFloat(px) * 0.06, dy: CGFloat(px) * 0.06)
    let radius = CGFloat(px) * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.62, alpha: 1.0),
        NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.38, alpha: 1.0)
    ])!
    grad.draw(in: path, angle: -60)

    if let sym = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.48, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        if let configured = sym.withSymbolConfiguration(config) {
            let symSize = configured.size
            let symOrigin = NSPoint(
                x: (CGFloat(px) - symSize.width) / 2.0,
                y: (CGFloat(px) - symSize.height) / 2.0
            )
            configured.draw(in: NSRect(origin: symOrigin, size: symSize))
        }
    }

    img.unlockFocus()
    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    }
}
