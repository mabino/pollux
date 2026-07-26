import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the Pollux app icon: a bright warm star (Pollux is an orange giant in Gemini), a subtle
// starfield + constellation, and a luminous stream of matter emitted from the star. The artwork fills
// the full macOS Tahoe squircle edge-to-edge (a superellipse spanning the whole 1024 canvas).

let canvas: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

// Deterministic PRNG so the starfield is identical every build.
struct RNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
        return x
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
}
var rng = RNG(state: 0x506F6C6C7578_2601) // "Pollux" + tag

// Superellipse (squircle) filling the full canvas — the native Tahoe icon shape at full extent.
func squirclePath(inset: CGFloat = 0) -> CGPath {
    let cx = canvas / 2, cy = canvas / 2
    let a = canvas / 2 - inset, b = canvas / 2 - inset
    let n: CGFloat = 5.0
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, stops: [(CGFloat, CGColor)], additive: Bool = true) {
    ctx.saveGState()
    if additive { ctx.setBlendMode(.plusLighter) }
    ctx.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let x = u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x
    let y = u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y
    return CGPoint(x: x, y: y)
}

func bezierTangent(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let x = 3*u*u*(p1.x-p0.x) + 6*u*t*(p2.x-p1.x) + 3*t*t*(p3.x-p2.x)
    let y = 3*u*u*(p1.y-p0.y) + 6*u*t*(p2.y-p1.y) + 3*t*t*(p3.y-p2.y)
    return CGPoint(x: x, y: y)
}

// MARK: - Scene geometry

let star = CGPoint(x: 398, y: 640)           // Pollux
let streamTail = CGPoint(x: 812, y: 284)
let streamC1 = CGPoint(x: 540, y: 556)
let streamC2 = CGPoint(x: 726, y: 336)

func streamHalfWidth(_ t: CGFloat) -> CGFloat {
    let w0: CGFloat = 74, w1: CGFloat = 5
    return (w1 + (w0 - w1) * pow(1 - t, 1.25)) / 2
}

// MARK: - Render

let ctx = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas),
    bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Clip everything to the squircle so corners stay transparent.
ctx.addPath(squirclePath())
ctx.clip()

// 1. Deep-space background, brighter toward the star.
ctx.drawRadialGradient(
    gradient([
        (0.0, rgb(30, 27, 66)),
        (0.5, rgb(13, 13, 34)),
        (1.0, rgb(4, 5, 14)),
    ]),
    startCenter: star, startRadius: 0,
    endCenter: CGPoint(x: canvas/2, y: canvas/2), endRadius: canvas * 0.9,
    options: [.drawsAfterEndLocation]
)

// 2. Nebula accents (cool teal where the stream flows, violet opposite).
radialGlow(ctx, center: CGPoint(x: 760, y: 320), radius: 420, stops: [
    (0.0, rgb(24, 150, 165, 0.22)), (0.6, rgb(24, 150, 165, 0.07)), (1.0, rgb(24, 150, 165, 0)),
])
radialGlow(ctx, center: CGPoint(x: 736, y: 792), radius: 340, stops: [
    (0.0, rgb(104, 58, 176, 0.20)), (1.0, rgb(104, 58, 176, 0)),
])

// 3. Starfield.
for _ in 0..<150 {
    let p = CGPoint(x: rng.range(40, canvas - 40), y: rng.range(40, canvas - 40))
    let d = hypot(p.x - star.x, p.y - star.y)
    if d < 120 { continue } // keep clear space around the hero star
    let bright = rng.unit()
    let size = rng.range(0.6, 2.4) + (bright > 0.9 ? 1.4 : 0)
    let tint: CGColor
    let pick = rng.unit()
    if pick < 0.7 { tint = rgb(255, 255, 255, rng.range(0.35, 0.95)) }
    else if pick < 0.85 { tint = rgb(180, 210, 255, rng.range(0.35, 0.9)) }
    else { tint = rgb(255, 224, 180, rng.range(0.35, 0.9)) }
    if bright > 0.88 {
        radialGlow(ctx, center: p, radius: size * 5, stops: [(0.0, tint), (1.0, rgb(255, 255, 255, 0))])
    }
    ctx.setFillColor(tint)
    ctx.fillEllipse(in: CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2))
}

// 4. Constellation (stylized) anchored on Pollux.
let nodes: [CGPoint] = [
    star,
    CGPoint(x: 286, y: 772),
    CGPoint(x: 486, y: 802),
    CGPoint(x: 214, y: 556),
    CGPoint(x: 560, y: 706),
]
let edges = [(0, 1), (0, 3), (1, 2), (0, 4), (3, 1)]
ctx.saveGState()
ctx.setBlendMode(.plusLighter)
ctx.setStrokeColor(rgb(196, 214, 255, 0.32))
ctx.setLineWidth(2.4)
ctx.setLineCap(.round)
for (a, b) in edges {
    ctx.move(to: nodes[a]); ctx.addLine(to: nodes[b])
}
ctx.strokePath()
ctx.restoreGState()
for node in nodes.dropFirst() {
    radialGlow(ctx, center: node, radius: 22, stops: [(0.0, rgb(214, 228, 255, 1.0)), (1.0, rgb(214, 228, 255, 0))])
    ctx.setFillColor(rgb(238, 244, 255, 1.0))
    ctx.fillEllipse(in: CGRect(x: node.x - 3.6, y: node.y - 3.6, width: 7.2, height: 7.2))
}

// 5. Stream of matter emitted from the star.
func buildRibbon(scale: CGFloat) -> CGPath {
    let steps = 80
    var top: [CGPoint] = [], bottom: [CGPoint] = []
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = bezier(star, streamC1, streamC2, streamTail, t)
        let d = bezierTangent(star, streamC1, streamC2, streamTail, t)
        let len = max(hypot(d.x, d.y), 0.0001)
        let nx = -d.y / len, ny = d.x / len
        let w = streamHalfWidth(t) * scale
        top.append(CGPoint(x: p.x + nx * w, y: p.y + ny * w))
        bottom.append(CGPoint(x: p.x - nx * w, y: p.y - ny * w))
    }
    let path = CGMutablePath()
    path.move(to: top[0])
    for pt in top.dropFirst() { path.addLine(to: pt) }
    for pt in bottom.reversed() { path.addLine(to: pt) }
    path.closeSubpath()
    return path
}

let streamStops: [(CGFloat, CGColor)] = [
    (0.00, rgb(255, 240, 205, 0.95)),
    (0.22, rgb(255, 194, 104, 0.90)),
    (0.52, rgb(96, 222, 255, 0.75)),
    (0.80, rgb(154, 116, 255, 0.45)),
    (1.00, rgb(154, 116, 255, 0.0)),
]

// Soft bloom underlay, then the crisp ribbon.
for (scale, alpha) in [(2.6, 0.5), (1.0, 1.0)] as [(CGFloat, CGFloat)] {
    ctx.saveGState()
    ctx.addPath(buildRibbon(scale: scale))
    ctx.clip()
    ctx.setBlendMode(.plusLighter)
    ctx.setAlpha(alpha)
    ctx.drawLinearGradient(gradient(streamStops), start: star, end: streamTail, options: [])
    ctx.restoreGState()
}

// Glowing particles carried along the stream.
for i in 0..<52 {
    let base = CGFloat(i) / 51
    let t = min(1, 0.03 + base * 0.99)
    let p = bezier(star, streamC1, streamC2, streamTail, t)
    let d = bezierTangent(star, streamC1, streamC2, streamTail, t)
    let len = max(hypot(d.x, d.y), 0.0001)
    let nx = -d.y / len, ny = d.x / len
    let jitter = rng.range(-1, 1) * streamHalfWidth(t) * 0.7
    let center = CGPoint(x: p.x + nx * jitter, y: p.y + ny * jitter)
    let size = (10 - 8 * t) * rng.range(0.6, 1.1)
    let a = (1 - t) * rng.range(0.5, 1.0)
    let color: CGColor
    if t < 0.3 { color = rgb(255, 226, 170, a) }
    else if t < 0.62 { color = rgb(120, 226, 255, a) }
    else { color = rgb(170, 140, 255, a) }
    radialGlow(ctx, center: center, radius: size * 2.4, stops: [(0.0, color), (1.0, rgb(255, 255, 255, 0))])
    ctx.setFillColor(rgb(255, 255, 255, a * 0.8))
    ctx.fillEllipse(in: CGRect(x: center.x - size * 0.3, y: center.y - size * 0.3, width: size * 0.6, height: size * 0.6))
}

// 6. The hero star: Pollux — a warm orange giant.
radialGlow(ctx, center: star, radius: 250, stops: [
    (0.00, rgb(255, 244, 214, 0.95)),
    (0.16, rgb(255, 206, 120, 0.72)),
    (0.42, rgb(255, 150, 62, 0.28)),
    (1.00, rgb(255, 150, 62, 0.0)),
])
radialGlow(ctx, center: star, radius: 96, stops: [
    (0.0, rgb(255, 255, 255, 0.95)), (0.5, rgb(255, 238, 200, 0.5)), (1.0, rgb(255, 238, 200, 0)),
])

func drawSpike(angle: CGFloat, half: CGFloat, thickness: CGFloat, peak: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: star.x, y: star.y)
    ctx.rotate(by: angle)
    ctx.addRect(CGRect(x: -half, y: -thickness / 2, width: half * 2, height: thickness))
    ctx.clip()
    ctx.setBlendMode(.plusLighter)
    ctx.drawLinearGradient(
        gradient([
            (0.0, rgb(255, 246, 222, 0)),
            (0.5, rgb(255, 246, 222, peak)),
            (1.0, rgb(255, 246, 222, 0)),
        ]),
        start: CGPoint(x: -half, y: 0), end: CGPoint(x: half, y: 0), options: []
    )
    ctx.restoreGState()
}
drawSpike(angle: 0, half: 320, thickness: 6, peak: 0.9)
drawSpike(angle: .pi / 2, half: 320, thickness: 6, peak: 0.9)
drawSpike(angle: .pi / 4, half: 180, thickness: 4, peak: 0.55)
drawSpike(angle: -.pi / 4, half: 180, thickness: 4, peak: 0.55)

// Star core.
ctx.setFillColor(rgb(255, 249, 236, 1))
ctx.fillEllipse(in: CGRect(x: star.x - 22, y: star.y - 22, width: 44, height: 44))
radialGlow(ctx, center: star, radius: 22, stops: [(0.0, rgb(255, 255, 255, 1)), (1.0, rgb(255, 255, 255, 0))])

// 7. Gentle top sheen + crisp inner rim for a native, dimensional feel.
radialGlow(ctx, center: CGPoint(x: canvas / 2, y: canvas - 40), radius: 720, stops: [
    (0.0, rgb(255, 255, 255, 0.06)), (1.0, rgb(255, 255, 255, 0)),
])
ctx.saveGState()
ctx.addPath(squirclePath(inset: 1.5))
ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// MARK: - Write PNG

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
guard let image = ctx.makeImage() else { fatalError("Failed to render icon image") }
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Failed to create image destination at \(outPath)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Failed to write PNG at \(outPath)") }
print("Wrote \(outPath)")
