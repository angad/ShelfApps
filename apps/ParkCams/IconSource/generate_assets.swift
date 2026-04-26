import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("ParkCams")

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

func savePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG")
    }
    try! data.write(to: url)
}

func drawLandscape(in rect: NSRect, scale: CGFloat) {
    let gradient = NSGradient(colors: [
        color(0.05, 0.22, 0.24),
        color(0.12, 0.39, 0.33),
        color(0.03, 0.07, 0.08)
    ])!
    gradient.draw(in: rect, angle: -90)

    color(0.98, 0.82, 0.43, 0.94).setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.maxX - 0.26 * rect.width, y: rect.maxY - 0.24 * rect.height, width: 0.12 * rect.width, height: 0.12 * rect.width)).fill()

    func mountain(_ points: [NSPoint], _ fill: NSColor) {
        let path = NSBezierPath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        path.close()
        fill.setFill()
        path.fill()
    }

    mountain([
        NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.40),
        NSPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.66),
        NSPoint(x: rect.minX + rect.width * 0.48, y: rect.minY + rect.height * 0.45),
        NSPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.72),
        NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.42),
        NSPoint(x: rect.maxX, y: rect.minY),
        NSPoint(x: rect.minX, y: rect.minY)
    ], color(0.03, 0.10, 0.11, 0.54))

    mountain([
        NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.25),
        NSPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.50),
        NSPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.29),
        NSPoint(x: rect.minX + rect.width * 0.61, y: rect.minY + rect.height * 0.58),
        NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.32),
        NSPoint(x: rect.maxX, y: rect.minY),
        NSPoint(x: rect.minX, y: rect.minY)
    ], color(0.04, 0.17, 0.15, 1.0))

    let waterRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.24)
    color(0.10, 0.36, 0.39, 0.88).setFill()
    waterRect.fill()
    color(1, 1, 1, 0.18).setStroke()
    for i in 0..<5 {
        let y = waterRect.minY + waterRect.height * CGFloat(i + 1) / 6.0
        let line = NSBezierPath()
        line.lineWidth = max(1.0, 1.5 * scale)
        line.move(to: NSPoint(x: rect.minX + rect.width * 0.12, y: y))
        line.curve(to: NSPoint(x: rect.maxX - rect.width * 0.12, y: y),
                   controlPoint1: NSPoint(x: rect.minX + rect.width * 0.35, y: y + 7 * scale),
                   controlPoint2: NSPoint(x: rect.minX + rect.width * 0.62, y: y - 7 * scale))
        line.stroke()
    }
}

func makeIcon(size: CGFloat, path: String) {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    drawLandscape(in: NSRect(x: 0, y: 0, width: size, height: size), scale: size / 180.0)

    let lensRect = NSRect(x: size * 0.30, y: size * 0.29, width: size * 0.42, height: size * 0.30)
    color(0.02, 0.05, 0.05, 0.90).setFill()
    NSBezierPath(roundedRect: lensRect, xRadius: size * 0.05, yRadius: size * 0.05).fill()
    color(0.98, 0.82, 0.43, 1.0).setStroke()
    let lens = NSBezierPath(ovalIn: NSRect(x: size * 0.39, y: size * 0.335, width: size * 0.13, height: size * 0.13))
    lens.lineWidth = max(2.0, size * 0.018)
    lens.stroke()
    color(0.98, 0.82, 0.43, 1.0).setFill()
    NSBezierPath(roundedRect: NSRect(x: size * 0.54, y: size * 0.395, width: size * 0.08, height: size * 0.028), xRadius: size * 0.01, yRadius: size * 0.01).fill()
    image.unlockFocus()
    savePNG(image, to: out.appendingPathComponent(path))
}

func makeLaunch() {
    let size = NSSize(width: 750, height: 1334)
    let image = NSImage(size: size)
    image.lockFocus()
    drawLandscape(in: NSRect(x: 0, y: 0, width: size.width, height: size.height), scale: 4.0)

    let title = "RangerLens"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 76, weight: .black),
        .foregroundColor: NSColor.white
    ]
    let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 27, weight: .semibold),
        .foregroundColor: color(0.92, 0.95, 0.90, 0.90)
    ]
    let titleSize = title.size(withAttributes: attrs)
    title.draw(at: NSPoint(x: (size.width - titleSize.width) / 2.0, y: size.height * 0.58), withAttributes: attrs)
    let subtitle = "National Park live views"
    let subtitleSize = subtitle.size(withAttributes: subtitleAttrs)
    subtitle.draw(at: NSPoint(x: (size.width - subtitleSize.width) / 2.0, y: size.height * 0.55), withAttributes: subtitleAttrs)
    image.unlockFocus()
    savePNG(image, to: out.appendingPathComponent("Default-667h@2x.png"))
}

try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
makeLaunch()
makeIcon(size: 40, path: "Icon-20@2x.png")
makeIcon(size: 60, path: "Icon-20@3x.png")
makeIcon(size: 58, path: "Icon-29@2x.png")
makeIcon(size: 87, path: "Icon-29@3x.png")
makeIcon(size: 80, path: "Icon-40@2x.png")
makeIcon(size: 120, path: "Icon-40@3x.png")
makeIcon(size: 120, path: "Icon-60@2x.png")
makeIcon(size: 180, path: "Icon-60@3x.png")
makeIcon(size: 1024, path: "Icon-1024.png")
