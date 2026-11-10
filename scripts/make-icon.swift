// Generates Dropster's brand assets from one set of geometry.
//
//   swift scripts/make-icon.swift
//
// Writes:
//   Packaging/AppIcon.icns                 app icon, every size macOS uses
//   Packaging/MenuBarIcon.png, @2x         monochrome template for the menu bar
//   assets/brand/dropster-icon.svg         full app icon (vector)
//   assets/brand/dropster-mark.svg         the mark alone, transparent background
//   assets/brand/dropster-menubar.svg      monochrome mark
//   assets/brand/dropster-icon-1024.png    preview
//
// The mark: the clover dial's four rounded petals (mint, sky, violet, amber) around an open
// centre, on a midnight body with the dial's bezel.

import AppKit
import CoreGraphics

// MARK: - Palette (matches CloverPalette in the app)

struct RGB { var r, g, b: CGFloat; var a: CGFloat = 1
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
    func with(alpha: CGFloat) -> RGB { RGB(r: r, g: g, b: b, a: alpha) }
}
func hsb(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> RGB {
    let c = NSColor(hue: h, saturation: s, brightness: v, alpha: 1).usingColorSpace(.sRGB)!
    return RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
}
// Petal order: 0 upper-left, 1 upper-right, 2 lower-right, 3 lower-left.
let hues = [hsb(0.43, 0.62, 0.84), hsb(0.57, 0.70, 0.96), hsb(0.74, 0.56, 0.93), hsb(0.09, 0.76, 0.98)]
let glows = [hsb(0.43, 0.30, 1.0), hsb(0.56, 0.32, 1.0), hsb(0.74, 0.26, 1.0), hsb(0.11, 0.36, 1.0)]
let inkTop = hsb(0.63, 0.40, 0.21), inkBottom = hsb(0.66, 0.45, 0.09)

// MARK: - Geometry (1024 × 1024 canvas, y down)

let S: CGFloat = 1024
let C = CGPoint(x: 512, y: 512)

/// macOS icon body: a superellipse (n = 5) 824 pt wide, centred.
func squircle(size: CGFloat = 824, center: CGPoint = C) -> CGPath {
    let a = size / 2, n: CGFloat = 5
    let p = CGMutablePath()
    for k in 0...360 {
        let t = CGFloat(k) / 360 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = a * (ct >= 0 ? 1 : -1) * pow(abs(ct), 2 / n), y = a * (st >= 0 ? 1 : -1) * pow(abs(st), 2 / n)
        let pt = CGPoint(x: center.x + x, y: center.y + y)
        if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

/// One petal: the annulus quadrant centred on `angle`, corners rounded evenly, constant gap.
/// Same construction as `Petal` in the app: inset quadrant grown back by a round-joined stroke.
func petal(_ i: Int, inner: CGFloat, outer: CGFloat, gap: CGFloat, corner: CGFloat, center: CGPoint = C) -> CGPath {
    let c = gap / 2 + corner, ro = outer - corner, ri = inner + corner
    let o1 = atan2(c, sqrt(ro * ro - c * c)), o2 = atan2(sqrt(ro * ro - c * c), c)
    let i1 = atan2(c, sqrt(ri * ri - c * c)), i2 = atan2(sqrt(ri * ri - c * c), c)
    let core = CGMutablePath()
    core.move(to: CGPoint(x: cos(o1) * ro, y: sin(o1) * ro))
    core.addArc(center: .zero, radius: ro, startAngle: o1, endAngle: o2, clockwise: false)
    core.addLine(to: CGPoint(x: cos(i2) * ri, y: sin(i2) * ri))
    core.addArc(center: .zero, radius: ri, startAngle: i2, endAngle: i1, clockwise: true)
    core.closeSubpath()
    let grown = core.union(core.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
    let angles: [CGFloat] = [-3 * .pi / 4, -.pi / 4, .pi / 4, 3 * .pi / 4]
    var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angles[i] - .pi / 4)
    return grown.copy(using: &t)!
}

/// A drop pointing up: round body of radius `r` centred at `c`, tip `tip` above the centre.
func drop(center c: CGPoint, r: CGFloat, tip: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 0.5523 // circle-quadrant handle
    p.move(to: CGPoint(x: c.x, y: c.y - tip))
    p.addCurve(to: CGPoint(x: c.x - r, y: c.y), control1: CGPoint(x: c.x - r * 0.18, y: c.y - tip * 0.62),
               control2: CGPoint(x: c.x - r, y: c.y - r * 0.92))
    p.addCurve(to: CGPoint(x: c.x, y: c.y + r), control1: CGPoint(x: c.x - r, y: c.y + r * k), control2: CGPoint(x: c.x - r * k, y: c.y + r))
    p.addCurve(to: CGPoint(x: c.x + r, y: c.y), control1: CGPoint(x: c.x + r * k, y: c.y + r), control2: CGPoint(x: c.x + r, y: c.y + r * k))
    p.addCurve(to: CGPoint(x: c.x, y: c.y - tip), control1: CGPoint(x: c.x + r, y: c.y - r * 0.92),
               control2: CGPoint(x: c.x + r * 0.18, y: c.y - tip * 0.62))
    p.closeSubpath()
    return p
}

// The mark's proportions (on the 1024 canvas).
let inner: CGFloat = 132, outer: CGFloat = 300, gap: CGFloat = 26, corner: CGFloat = 46
let petals = (0..<4).map { petal($0, inner: inner, outer: outer, gap: gap, corner: corner) }
let dropCenter = CGPoint(x: 512, y: 548)
let dropPath = drop(center: dropCenter, r: 78, tip: 210)
let bezelRadius: CGFloat = 340

// MARK: - Raster drawing

/// Shadow offsets and blurs are in device pixels (the CTM doesn't scale them), so they are
/// multiplied by the current canvas scale.
nonisolated(unsafe) var deviceScale: CGFloat = 1
func shadow(_ ctx: CGContext, dy: CGFloat, blur: CGFloat, _ color: RGB) {
    // The context is flipped (y down), so a downward shadow is a negative device offset.
    ctx.setShadow(offset: CGSize(width: 0, height: -dy * deviceScale), blur: blur * deviceScale, color: color.cg)
}

func withContext(_ size: Int, _ draw: (CGContext, CGFloat) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(size) / S
    deviceScale = k
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: k, y: -k) // y down, 1024 units
    ctx.setShouldAntialias(true)
    draw(ctx, k)
    return ctx.makeImage()!
}

func fill(_ ctx: CGContext, _ path: CGPath, linear colors: [RGB], from a: CGPoint, to b: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cg) as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func fill(_ ctx: CGContext, _ path: CGPath, radial colors: [RGB], center: CGPoint, r0: CGFloat, r1: CGFloat) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cg) as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: r0, endCenter: center, endRadius: r1, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

func drawPetals(_ ctx: CGContext, glow: Bool, onDark: Bool = true) {
    // Petals: pale glow at the core, full colour at the rim, a sheen across the top.
    for i in 0..<4 {
        if glow {
            ctx.saveGState()
            shadow(ctx, dy: 10, blur: 26, hues[i].with(alpha: onDark ? 0.45 : 0.25))
            ctx.addPath(petals[i]); ctx.setFillColor(hues[i].cg); ctx.fillPath()
            ctx.restoreGState()
        }
        fill(ctx, petals[i], radial: [glows[i], hues[i]], center: C, r0: inner, r1: outer)
        fill(ctx, petals[i], linear: [RGB(r: 1, g: 1, b: 1, a: 0.28), RGB(r: 1, g: 1, b: 1, a: 0)],
             from: CGPoint(x: 512, y: 212), to: CGPoint(x: 512, y: 520))
        ctx.saveGState(); ctx.addPath(petals[i]); ctx.setStrokeColor(RGB(r: 1, g: 1, b: 1, a: 0.22).cg); ctx.setLineWidth(2); ctx.strokePath(); ctx.restoreGState()
    }
}

func drawDrop(_ ctx: CGContext, shadowed: Bool) {
    // The drop, with a soft shadow, a cool-white body and a specular highlight.
    if shadowed {
        ctx.saveGState()
        shadow(ctx, dy: 14, blur: 30, RGB(r: 0, g: 0, b: 0.05, a: 0.45))
        ctx.addPath(dropPath); ctx.setFillColor(.white); ctx.fillPath()
        ctx.restoreGState()
    }
    fill(ctx, dropPath, linear: [RGB(r: 1, g: 1, b: 1), hsb(0.58, 0.10, 0.95)], from: CGPoint(x: 470, y: 360), to: CGPoint(x: 560, y: 630))
    let shine = CGPath(ellipseIn: CGRect(x: 468, y: 500, width: 30, height: 58), transform: nil)
    var rot = CGAffineTransform(translationX: 483, y: 529).rotated(by: 0.35).translatedBy(x: -483, y: -529)
    ctx.addPath(shine.copy(using: &rot)!); ctx.setFillColor(RGB(r: 1, g: 1, b: 1, a: 0.9).cg); ctx.fillPath()
}

func drawMark(_ ctx: CGContext, onDark: Bool) {
    drawPetals(ctx, glow: true, onDark: onDark)
}

/// Aurora and bezel, the backdrop details between the body fill and the mark.
func drawBackdrop(_ ctx: CGContext, clip: CGPath) {
    let offsets = [CGPoint(x: -150, y: -150), CGPoint(x: 150, y: -150), CGPoint(x: 150, y: 150), CGPoint(x: -150, y: 150)]
    for i in 0..<4 {
        let c = CGPoint(x: 512 + offsets[i].x, y: 512 + offsets[i].y)
        fill(ctx, clip, radial: [hues[i].with(alpha: 0.30), hues[i].with(alpha: 0)], center: c, r0: 0, r1: 330)
    }
    ctx.saveGState()
    ctx.setStrokeColor(RGB(r: 1, g: 1, b: 1, a: 0.14).cg); ctx.setLineWidth(2)
    ctx.addEllipse(in: CGRect(x: 512 - bezelRadius - 16, y: 512 - bezelRadius - 16, width: (bezelRadius + 16) * 2, height: (bezelRadius + 16) * 2))
    ctx.strokePath()
    ctx.setLineCap(.round)
    for k in 0..<64 {
        let a = CGFloat(k) / 64 * 2 * .pi
        let major = k % 16 == 0
        let r0 = bezelRadius - (major ? 10 : 2), r1 = bezelRadius + (major ? 6 : 3)
        ctx.setStrokeColor(RGB(r: 1, g: 1, b: 1, a: major ? 0.55 : 0.2).cg)
        ctx.setLineWidth(major ? 5 : 2.5)
        ctx.move(to: CGPoint(x: 512 + cos(a) * r0, y: 512 + sin(a) * r0))
        ctx.addLine(to: CGPoint(x: 512 + cos(a) * r1, y: 512 + sin(a) * r1))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    let body = squircle()
    // Body with the standard macOS icon drop shadow.
    ctx.saveGState()
    shadow(ctx, dy: 12, blur: 28, RGB(r: 0, g: 0, b: 0, a: 0.35))
    ctx.addPath(body); ctx.setFillColor(inkBottom.cg); ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, body, linear: [inkTop, inkBottom], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    drawBackdrop(ctx, clip: body)
    drawMark(ctx, onDark: true)
    // A thin top-lit rim on the body.
    ctx.saveGState(); ctx.addPath(body); ctx.clip()
    ctx.addPath(body); ctx.setLineWidth(4)
    ctx.setStrokeColor(RGB(r: 1, g: 1, b: 1, a: 0.10).cg); ctx.strokePath()
    ctx.restoreGState()
}

/// Menu bar template: solid petals with the drop knocked out (black on clear; macOS tints it).
func drawTemplate(_ ctx: CGContext) {
    // Bolder proportions read better at 18 pt.
    let big = (0..<4).map { petal($0, inner: 180, outer: 512, gap: 76, corner: 84, center: C) }
    ctx.setFillColor(.black)
    for p in big { ctx.addPath(p) }
    ctx.fillPath()
}

func writePNG(_ image: CGImage, _ url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - SVG

func svgPath(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { e in
        let p = e.pointee.points
        func f(_ q: CGPoint) -> String { String(format: "%.2f %.2f", q.x, q.y) }
        switch e.pointee.type {
        case .moveToPoint: d += "M" + f(p[0])
        case .addLineToPoint: d += "L" + f(p[0])
        case .addQuadCurveToPoint: d += "Q" + f(p[0]) + " " + f(p[1])
        case .addCurveToPoint: d += "C" + f(p[0]) + " " + f(p[1]) + " " + f(p[2])
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svgMark(onDark: Bool) -> (defs: String, body: String) {
    var defs = ""
    var body = ""
    for i in 0..<4 {
        defs += """
        <radialGradient id="p\(i)" gradientUnits="userSpaceOnUse" cx="512" cy="512" r="\(outer)">
          <stop offset="\(inner / outer)" stop-color="\(glows[i].hex)"/><stop offset="1" stop-color="\(hues[i].hex)"/></radialGradient>
        <filter id="g\(i)" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="10" stdDeviation="13" flood-color="\(hues[i].hex)" flood-opacity="\(onDark ? 0.45 : 0.25)"/></filter>

        """
        let d = svgPath(petals[i])
        body += """
        <path d="\(d)" fill="url(#p\(i))" filter="url(#g\(i))"/>
        <path d="\(d)" fill="url(#sheen)" stroke="#FFFFFF" stroke-opacity="0.22" stroke-width="2"/>

        """
    }
    defs += """
    <linearGradient id="sheen" gradientUnits="userSpaceOnUse" x1="512" y1="212" x2="512" y2="520">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.28"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>

    """
    return (defs, body)
}

func svgIcon() -> String {
    let m = svgMark(onDark: true)
    var aurora = ""
    var auroraDefs = ""
    let offsets = [(-150, -150), (150, -150), (150, 150), (-150, 150)]
    for i in 0..<4 {
        auroraDefs += """
        <radialGradient id="a\(i)" gradientUnits="userSpaceOnUse" cx="\(512 + offsets[i].0)" cy="\(512 + offsets[i].1)" r="330">
          <stop offset="0" stop-color="\(hues[i].hex)" stop-opacity="0.30"/><stop offset="1" stop-color="\(hues[i].hex)" stop-opacity="0"/></radialGradient>

        """
        aurora += "<path d=\"\(svgPath(squircle()))\" fill=\"url(#a\(i))\"/>\n"
    }
    var ticks = ""
    for k in 0..<64 {
        let a = Double(k) / 64 * 2 * .pi
        let major = k % 16 == 0
        let r0 = Double(bezelRadius) - (major ? 10 : 2), r1 = Double(bezelRadius) + (major ? 6 : 3)
        ticks += String(format: "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#FFFFFF\" stroke-opacity=\"%.2f\" stroke-width=\"%.1f\" stroke-linecap=\"round\"/>\n",
                        512 + cos(a) * r0, 512 + sin(a) * r0, 512 + cos(a) * r1, 512 + sin(a) * r1, major ? 0.55 : 0.2, major ? 5 : 2.5)
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
    <title>Dropster</title>
    <defs>
    <linearGradient id="ink" gradientUnits="userSpaceOnUse" x1="512" y1="100" x2="512" y2="924">
      <stop offset="0" stop-color="\(inkTop.hex)"/><stop offset="1" stop-color="\(inkBottom.hex)"/></linearGradient>
    <filter id="bodyShadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000000" flood-opacity="0.35"/></filter>
    \(auroraDefs)\(m.defs)</defs>
    <path d="\(svgPath(squircle()))" fill="url(#ink)" filter="url(#bodyShadow)"/>
    \(aurora)<circle cx="512" cy="512" r="\(bezelRadius + 16)" fill="none" stroke="#FFFFFF" stroke-opacity="0.14" stroke-width="2"/>
    \(ticks)\(m.body)</svg>

    """
}

func svgStandalone(_ inner: (defs: String, body: String), viewBox: String = "180 180 664 664") -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(viewBox)\">\n<title>Dropster</title>\n<defs>\n\(inner.defs)</defs>\n\(inner.body)</svg>\n"
}

func svgTemplate() -> String {
    let big = (0..<4).map { svgPath(petal($0, inner: 180, outer: 512, gap: 76, corner: 84)) }.joined()
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
    <title>Dropster</title>
    <path d="\(big)" fill="#000"/>
    </svg>

    """
}

// MARK: - Output

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brand = root.appendingPathComponent("assets/brand", isDirectory: true)
let packaging = root.appendingPathComponent("Packaging", isDirectory: true)
try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let img = withContext(px) { ctx, _ in drawIcon(ctx) }
        try writePNG(img, iconset.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", packaging.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)

try writePNG(withContext(1024) { ctx, _ in drawIcon(ctx) }, brand.appendingPathComponent("dropster-icon-1024.png"))

// Icon Composer document for macOS 26+: full-bleed layers that the system masks, lights and
// renders in glass. (A plain .icns with its own shape is shown shrunk on a grey platter there.)
let iconDoc = packaging.appendingPathComponent("AppIcon.icon", isDirectory: true)
try? FileManager.default.removeItem(at: iconDoc)
try FileManager.default.createDirectory(at: iconDoc.appendingPathComponent("Assets"), withIntermediateDirectories: true)
/// The mark drawn full-bleed: the 824-pt body becomes the whole 1024 canvas.
func fullBleed(_ draw: @escaping (CGContext) -> Void) -> CGImage {
    withContext(1024) { ctx, _ in
        let k: CGFloat = 1024 / 824
        ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: k, y: k); ctx.translateBy(x: -512, y: -512)
        draw(ctx)
    }
}
try writePNG(fullBleed { drawBackdrop($0, clip: CGPath(rect: CGRect(x: -200, y: -200, width: 1424, height: 1424), transform: nil)) },
             iconDoc.appendingPathComponent("Assets/backdrop.png"))
try writePNG(fullBleed { drawPetals($0, glow: false) }, iconDoc.appendingPathComponent("Assets/petals.png"))
func srgb(_ c: RGB) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b) }
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "\(srgb(inkTop))",
      "\(srgb(inkBottom))"
    ]
  },
  "groups" : [
    {
      "name" : "Petals",
      "layers" : [ { "name" : "petals", "image-name" : "petals.png", "glass" : true } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.15 }
    },
    {
      "name" : "Backdrop",
      "layers" : [ { "name" : "backdrop", "image-name" : "backdrop.png", "glass" : false } ],
      "shadow" : { "kind" : "none", "opacity" : 0 },
      "translucency" : { "enabled" : false, "value" : 0 }
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}
"""
try iconJSON.write(to: iconDoc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
try writePNG(withContext(18) { ctx, _ in drawTemplate(ctx) }, packaging.appendingPathComponent("MenuBarIcon.png"))
try writePNG(withContext(36) { ctx, _ in drawTemplate(ctx) }, packaging.appendingPathComponent("MenuBarIcon@2x.png"))
try svgIcon().write(to: brand.appendingPathComponent("dropster-icon.svg"), atomically: true, encoding: .utf8)
try svgStandalone(svgMark(onDark: false)).write(to: brand.appendingPathComponent("dropster-mark.svg"), atomically: true, encoding: .utf8)
try svgTemplate().write(to: brand.appendingPathComponent("dropster-menubar.svg"), atomically: true, encoding: .utf8)
print("Wrote Packaging/AppIcon.icns, Packaging/AppIcon.icon, Packaging/MenuBarIcon*.png and assets/brand/*")
