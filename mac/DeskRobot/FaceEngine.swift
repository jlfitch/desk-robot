import Foundation
import SwiftUI

/// The desk robot's face, ported from firmware/src/face.cpp.
///
/// The face lives on a 128x64 grid, like the OLED it came from. Eyes are
/// rounded rectangles whose shape morphs between emotion presets; on top of
/// that: blinks, gaze shifts, a glint, a mouth that moves while talking,
/// per-emotion flourishes, and a sleep state with breathing and floating Z's.
enum Emotion: String, CaseIterable {
    case neutral, happy, sad, angry, surprised, sleepy, thinking
}

/// How the face is drawn. The animation underneath is the same for both.
enum FaceStyle: String, CaseIterable, Identifiable {
    case cozmoDots = "Cozmo Dots"   // tall eyes + a mouth, shown as the dots of a real OLED
    case classic = "Classic"        // the original robot's pill eyes
    var id: String { rawValue }
}

enum EyeColor: String, CaseIterable, Identifiable {
    case ice = "Ice white", cyan = "Cyan", amber = "Amber", phosphor = "Phosphor green", violet = "Violet"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .ice:      return Color(red: 0.86, green: 0.95, blue: 1.0)
        case .cyan:     return Color(red: 0.25, green: 0.88, blue: 1.0)
        case .amber:    return Color(red: 1.0, green: 0.70, blue: 0.25)
        case .phosphor: return Color(red: 0.36, green: 1.0, blue: 0.54)
        case .violet:   return Color(red: 0.72, green: 0.61, blue: 1.0)
        }
    }
}

final class FaceEngine {
    struct Params {
        var eyeW: Float, eyeH: Float, radius: Float, browSlant: Float, lowerLid: Float, upperLid: Float
    }
    struct Zed { var alive = false; var x: Float = 0; var y: Float = 0; var age: Float = 0 }

    static let screenW = 128
    static let screenH = 64
    static let eyeGap = 16

    static func params(for e: Emotion) -> Params {
        switch e {
        case .happy:     return Params(eyeW: 36, eyeH: 36, radius: 12, browSlant: 0, lowerLid: 16, upperLid: 0)
        case .sad:       return Params(eyeW: 32, eyeH: 26, radius: 10, browSlant: -9, lowerLid: 0, upperLid: 4)
        case .angry:     return Params(eyeW: 34, eyeH: 24, radius: 8, browSlant: 10, lowerLid: 0, upperLid: 0)
        case .surprised: return Params(eyeW: 38, eyeH: 44, radius: 19, browSlant: 0, lowerLid: 0, upperLid: 0)
        case .sleepy:    return Params(eyeW: 34, eyeH: 26, radius: 10, browSlant: 0, lowerLid: 0, upperLid: 14)
        case .thinking:  return Params(eyeW: 30, eyeH: 30, radius: 11, browSlant: 0, lowerLid: 0, upperLid: 5)
        case .neutral:   return Params(eyeW: 34, eyeH: 34, radius: 12, browSlant: 0, lowerLid: 0, upperLid: 0)
        }
    }

    private(set) var emotion: Emotion = .neutral
    private var cur = FaceEngine.params(for: .neutral)
    private var target = FaceEngine.params(for: .neutral)
    private var emotionSince: UInt64 = 0
    private var blinkAmount: Float = 0
    private var blinkClosing = false
    private var nextBlink: UInt64 = 0
    private var gazeX: Float = 0, gazeY: Float = 0
    private var gazeTargetX: Float = 0, gazeTargetY: Float = 0
    private var nextSaccade: UInt64 = 0
    private var pop: Float = 0
    private var squint: Float = 0
    private var nextSquint: UInt64 = 0
    private var tearY: Float = -1
    private var nextTear: UInt64 = 0
    private var thinkDots = 0
    private var nextDot: UInt64 = 0
    private var jitterX = 0
    private(set) var asleep = false
    private var breath: Float = 0
    private var zeds = [Zed](repeating: Zed(), count: 3)
    private var nextZed: UInt64 = 0
    private var nextTwitch: UInt64 = 0
    private var twitch: Float = 0
    private var talking = false
    private var mouthLevel: Float = 0
    private var mouth: Float = 0
    var idle = true
    /// True while the brain can hear speech: gaze settles, blinks pause.
    var hearing = false
    private var frame: UInt64 = 0
    private var mouthNoisePhase: Float = 0
    var style: FaceStyle = .cozmoDots

    // Off-screen 128x64 bitmap for the dot-matrix styles: the face is drawn
    // here with no antialiasing, then every lit pixel becomes one dot.
    private let dmData = UnsafeMutablePointer<UInt8>.allocate(capacity: FaceEngine.screenW * FaceEngine.screenH)
    private lazy var dmCtx: CGContext = {
        let c = CGContext(data: dmData, width: Self.screenW, height: Self.screenH, bitsPerComponent: 8,
                          bytesPerRow: Self.screenW, space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        c.translateBy(x: 0, y: CGFloat(Self.screenH))
        c.scaleBy(x: 1, y: -1)   // y grows downward, like the face grid
        c.setShouldAntialias(false)
        return c
    }()

    init() {
        let now = Self.millis()
        blinkAmount = 1
        nextBlink = now + 3000
        nextSaccade = now + 1500
        nextSquint = now + 9000
    }

    static func millis() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    private static func approach(_ c: Float, _ t: Float, _ f: Float) -> Float { c + (t - c) * f }
    private static func rnd(_ lo: Int, _ hi: Int) -> Int { Int.random(in: lo..<hi) }  // like Arduino random(lo, hi)

    func setEmotion(_ e: Emotion) {
        if e != emotion {
            pop = 1
            emotionSince = Self.millis()
            tearY = -1
            nextTear = Self.millis() + 1500
            thinkDots = 0
        }
        emotion = e
        target = Self.params(for: e)
        if e == .thinking { gazeTargetX = 7; gazeTargetY = -5 } else { gazeTargetX = 0; gazeTargetY = 0 }
    }

    func blink() { blinkClosing = true }

    func setAsleep(_ on: Bool) {
        if on == asleep { return }
        asleep = on
        if on {
            for i in zeds.indices { zeds[i].alive = false }
            nextZed = Self.millis() + 800
            nextTwitch = Self.millis() + UInt64(Self.rnd(5000, 9000))
            gazeTargetX = 0; gazeTargetY = 0
        } else {
            pop = 1
            blinkAmount = 0
        }
    }

    /// Talking draws a mouth. No speaker level is available from the brain,
    /// so the level is synthesised from noise the way speech tends to move.
    func setTalking(_ on: Bool) {
        talking = on
        if !on { mouthLevel = 0; externalLevel = nil }
    }

    /// The speaker's real loudness (0..1) while the app plays the reply itself.
    var externalLevel: Float?

    // MARK: - Animation step (30 fps)

    func step(now: UInt64) {
        frame += 1
        let goal = asleep ? Params(eyeW: 30, eyeH: 3, radius: 1, browSlant: 0, lowerLid: 0, upperLid: 0) : target
        let f: Float = asleep ? 0.12 : 0.25
        cur.eyeW = Self.approach(cur.eyeW, goal.eyeW, f)
        cur.eyeH = Self.approach(cur.eyeH, goal.eyeH, f)
        cur.radius = Self.approach(cur.radius, goal.radius, f)
        cur.browSlant = Self.approach(cur.browSlant, goal.browSlant, f)
        cur.lowerLid = Self.approach(cur.lowerLid, goal.lowerLid, f)
        cur.upperLid = Self.approach(cur.upperLid, goal.upperLid, f)
        pop *= 0.82
        squint *= 0.85

        if asleep {
            breath += 0.035
            blinkAmount = 0
            blinkClosing = false
            twitch *= 0.8
            if now >= nextTwitch { twitch = 1; nextTwitch = now + UInt64(Self.rnd(6000, 12000)) }
            if now >= nextZed {
                if let i = zeds.firstIndex(where: { !$0.alive }) {
                    zeds[i] = Zed(alive: true, x: Float(Self.screenW / 2 + Self.eyeGap / 2) + cur.eyeW + 2, y: Float(Self.screenH / 2 - 6), age: 0)
                }
                nextZed = now + UInt64(Self.rnd(1100, 1700))
            }
            for i in zeds.indices where zeds[i].alive {
                zeds[i].age += 0.012; zeds[i].y -= 0.32; zeds[i].x += 0.22
                if zeds[i].age >= 1 || zeds[i].y < -12 { zeds[i].alive = false }
            }
            gazeX = Self.approach(gazeX, 0, 0.2); gazeY = Self.approach(gazeY, 0, 0.2)
            mouth = Self.approach(mouth, 0, 0.3)
            return
        }

        if blinkClosing {
            blinkAmount += 0.45
            if blinkAmount >= 1 { blinkAmount = 1; blinkClosing = false }
        } else if blinkAmount > 0 {
            blinkAmount = max(0, blinkAmount - 0.28)
        }

        if idle {
            if now >= nextBlink {
                blinkClosing = true
                nextBlink = now + UInt64(Self.rnd(2200, 6000))
                if Self.rnd(0, 100) < 20 { nextBlink = now + 400 }
            }
            if hearing {
                // Attentive: look straight at the human while they talk.
                gazeTargetX = 0; gazeTargetY = 0
                nextSaccade = now + 1500
            } else if now >= nextSaccade && emotion != .thinking {
                gazeTargetX = Float(Self.rnd(-8, 9)); gazeTargetY = Float(Self.rnd(-4, 5))
                if Self.rnd(0, 100) < 40 { gazeTargetX = 0; gazeTargetY = 0 }
                nextSaccade = now + UInt64(Self.rnd(1200, 4000))
            }
            if now >= nextSquint && emotion == .neutral {
                squint = 1
                nextSquint = now + UInt64(Self.rnd(8000, 16000))
            }
        }

        if emotion == .sad {
            if tearY < 0 && now >= nextTear { tearY = 0 }
            if tearY >= 0 {
                tearY += 0.7
                if tearY > Float(Self.screenH) { tearY = -1; nextTear = now + UInt64(Self.rnd(2500, 5000)) }
            }
        }
        if emotion == .thinking && now >= nextDot { thinkDots = (thinkDots + 1) % 4; nextDot = now + 420 }
        jitterX = (emotion == .angry && frame % 3 == 0) ? Self.rnd(-1, 2) : 0

        if talking, let lvl = externalLevel {
            mouthLevel = min(1, lvl * 2.2)
        } else if talking {
            // Syllable-like noise: two slow sines plus a random kick.
            mouthNoisePhase += 0.55
            let s = 0.5 + 0.35 * sin(mouthNoisePhase) + 0.25 * sin(mouthNoisePhase * 0.37 + 1.3)
            let kick: Float = Self.rnd(0, 100) < 15 ? 0.3 : 0
            mouthLevel = max(0, min(1, Float(s) * 0.22 + kick * 0.2))
        }
        let mouthGoal: Float = talking ? max(0.15, min(1, 0.15 + mouthLevel * 4)) : 0
        mouth = Self.approach(mouth, mouthGoal, talking ? 0.5 : 0.3)
        gazeX = Self.approach(gazeX, gazeTargetX, 0.35)
        gazeY = Self.approach(gazeY, gazeTargetY, 0.35)
    }

    // MARK: - Rendering on the 128x64 grid

    /// Draws the face into `ctx`, where one grid pixel is one unit. The
    /// caller scales. Light pixels are `ink`; the "off" pixels are `paper`.
    func draw(in ctx: inout GraphicsContext, ink: Color, paper: Color) {
        let bob: Float = asleep ? sin(breath) * 2 : -mouth * 2
        var cy = Self.screenH / 2 + Int(gazeY + bob)
        if talking { cy -= 2 }
        let half = Int(cur.eyeW / 2)
        let leftCx = Self.screenW / 2 - Self.eyeGap / 2 - half + Int(gazeX) + jitterX
        let rightCx = Self.screenW / 2 + Self.eyeGap / 2 + half + Int(gazeX) + jitterX
        var hScale: Float = 1 + pop * (emotion == .surprised ? 0.3 : 0.12)
        hScale *= 1 - squint * 0.4
        if asleep { hScale += twitch * 2.5 }

        drawEye(&ctx, cx: leftCx, cy: cy, isLeft: true, hScale: hScale, ink: ink, paper: paper)
        drawEye(&ctx, cx: rightCx, cy: cy, isLeft: false, hScale: hScale, ink: ink, paper: paper)

        let eyeTop = cy - Int(cur.eyeH * hScale / 2)
        let eyeBottom = cy + Int(cur.eyeH * hScale / 2)
        if asleep {
            drawZeds(&ctx, ink: ink)
        } else {
            drawFlourishes(&ctx, leftCx: leftCx, rightCx: rightCx, cy: cy, eyeTop: eyeTop, eyeBottom: eyeBottom, ink: ink)
            drawMouth(&ctx, cx: Self.screenW / 2 + Int(gazeX * 0.5), cy: cy, ink: ink, paper: paper)
        }
    }

    private func rbox(_ ctx: inout GraphicsContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ r: Int, _ c: Color) {
        let rect = CGRect(x: x, y: y, width: max(w, 0), height: max(h, 0))
        ctx.fill(Path(roundedRect: rect, cornerRadius: CGFloat(max(0, min(r, min(w, h) / 2)))), with: .color(c))
    }
    private func box(_ ctx: inout GraphicsContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: Color) {
        ctx.fill(Path(CGRect(x: x, y: y, width: max(w, 0), height: max(h, 0))), with: .color(c))
    }
    private func disc(_ ctx: inout GraphicsContext, _ cx: Int, _ cy: Int, _ r: Int, _ c: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r + 1, height: 2 * r + 1)), with: .color(c))
    }
    private func tri(_ ctx: inout GraphicsContext, _ p0: (Int, Int), _ p1: (Int, Int), _ p2: (Int, Int), _ c: Color) {
        var p = Path()
        p.move(to: CGPoint(x: p0.0, y: p0.1)); p.addLine(to: CGPoint(x: p1.0, y: p1.1)); p.addLine(to: CGPoint(x: p2.0, y: p2.1)); p.closeSubpath()
        ctx.fill(p, with: .color(c))
    }
    private func line(_ ctx: inout GraphicsContext, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Color) {
        var p = Path()
        p.move(to: CGPoint(x: Double(x0) + 0.5, y: Double(y0) + 0.5)); p.addLine(to: CGPoint(x: Double(x1) + 0.5, y: Double(y1) + 0.5))
        ctx.stroke(p, with: .color(c), lineWidth: 1.2)
    }

    private func drawEye(_ ctx: inout GraphicsContext, cx: Int, cy: Int, isLeft: Bool, hScale: Float, ink: Color, paper: Color) {
        var h = cur.eyeH * hScale * (1 - blinkAmount)
        if h < 2 { h = 2 }
        let w = cur.eyeW
        let x = cx - Int(w / 2)
        let y = cy - Int(h / 2)
        var r = min(Int(cur.radius), Int(min(w, h) / 2 - 1))
        if r < 0 { r = 0 }
        rbox(&ctx, x, y, Int(w), Int(h), r, ink)

        // Clip overlays to the eye so the carving never spills onto the face.
        var eye = ctx
        eye.clip(to: Path(roundedRect: CGRect(x: x, y: y, width: Int(w), height: Int(h)), cornerRadius: CGFloat(r)))

        let slant = cur.browSlant
        if abs(slant) > 0.5 {
            let depth = Int(abs(slant))
            let cutInner = slant > 0
            let cutRightCorner = isLeft ? cutInner : !cutInner
            let x0 = x - 1, x1 = x + Int(w) + 1
            if cutRightCorner { tri(&eye, (x0, y - 1), (x1, y - 1), (x1, y + depth), paper) }
            else { tri(&eye, (x0, y - 1), (x1, y - 1), (x0, y + depth), paper) }
        }
        if cur.lowerLid > 0.5 {
            let lidR = Int(w)
            let lidY = y + Int(h) + lidR - Int(cur.lowerLid)
            disc(&eye, cx, lidY, lidR, paper)
        }
        if cur.upperLid > 0.5 {
            box(&eye, x - 1, y - 1, Int(w) + 2, Int(cur.upperLid) + 1, paper)
        }
        if h > 12 && !asleep {
            let gx = x + Int(w * 0.22) + Int(gazeX * 0.3)
            let gy = y + Int(h * 0.18) + Int(cur.upperLid)
            let gs = w > 34 ? 4 : 3
            box(&eye, gx, gy, gs, gs, paper)
        }
    }

    private func drawMouth(_ ctx: inout GraphicsContext, cx: Int, cy: Int, ink: Color, paper: Color) {
        if mouth < 0.05 { return }
        let mh = 2 + Int(mouth * 9)
        let mw = 20 + Int(mouth * 8)
        var my = cy + Int(cur.eyeH / 2) + 4
        if my + mh > Self.screenH - 1 { my = Self.screenH - 1 - mh }
        rbox(&ctx, cx - mw / 2, my, mw, mh, min(mh / 2, 4), ink)
        if mh > 6 { rbox(&ctx, cx - mw / 2 + 3, my + 2, mw - 6, mh - 4, 2, paper) }
    }

    private func drawFlourishes(_ ctx: inout GraphicsContext, leftCx: Int, rightCx: Int, cy: Int, eyeTop: Int, eyeBottom: Int, ink: Color) {
        let half = Int(cur.eyeW / 2)
        let since = Self.millis() &- emotionSince
        switch emotion {
        case .surprised:
            if since < 900 {
                ctx.draw(Text("!").font(.system(size: 20, weight: .black, design: .monospaced)).foregroundColor(ink),
                         at: CGPoint(x: Self.screenW - 9, y: 12))
            }
        case .happy:
            if cur.lowerLid > 8 {
                for i in 0..<2 {
                    let lx = leftCx - half - 8 + i * 3, rx = rightCx + half + 3 + i * 3
                    line(&ctx, lx, eyeBottom + 1, lx + 3, eyeBottom - 3, ink)
                    line(&ctx, rx, eyeBottom + 1, rx + 3, eyeBottom - 3, ink)
                }
            }
        case .sad:
            if tearY >= 0 {
                let tx = rightCx + half - 3
                let ty = eyeBottom + Int(tearY)
                disc(&ctx, tx, ty, 2, ink)
                line(&ctx, tx, ty - 5, tx, ty - 2, ink)
            }
        case .thinking:
            for i in 0..<thinkDots { disc(&ctx, Self.screenW - 26 + i * 8, 9, 2, ink) }
        case .angry:
            if (frame / 6) % 2 == 0 {
                line(&ctx, leftCx - half - 4, eyeTop - 4, leftCx - half - 2, eyeTop - 9, ink)
                line(&ctx, rightCx + half + 4, eyeTop - 4, rightCx + half + 2, eyeTop - 9, ink)
            }
        default: break
        }
    }

    private func drawZeds(_ ctx: inout GraphicsContext, ink: Color) {
        for z in zeds where z.alive {
            if z.age > 0.8 && frame % 2 == 0 { continue }
            let size: CGFloat = z.age < 0.33 ? 8 : (z.age < 0.66 ? 12 : 16)
            let x = Int(z.x), y = Int(z.y)
            if x >= 0 && x < Self.screenW - 4 && y > 4 {
                ctx.draw(Text("Z").font(.system(size: size, weight: .bold, design: .monospaced)).foregroundColor(ink),
                         at: CGPoint(x: x + 3, y: y - 4))
            }
        }
    }

    // MARK: - Cozmo Dots

    /// The lit dots of the Cozmo face, one small circle per pixel, in grid units.
    func dotMatrixPath() -> Path {
        let c = dmCtx
        c.setFillColor(gray: 0, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: Self.screenW, height: Self.screenH))
        drawCozmo(c, withMouth: true)
        var p = Path()
        for y in 0..<Self.screenH {
            for x in 0..<Self.screenW where dmData[y * Self.screenW + x] > 127 {
                p.addEllipse(in: CGRect(x: Double(x) + 0.11, y: Double(y) + 0.11, width: 0.78, height: 0.78))
            }
        }
        return p
    }

    private func drawCozmo(_ c: CGContext, withMouth: Bool) {
        let bob: Float = asleep ? sin(breath) * 2 : -mouth * 2
        var cyI = Self.screenH / 2 + Int(gazeY + bob)
        if talking { cyI -= 2 }
        let half = Int(cur.eyeW / 2)
        let lcx = Self.screenW / 2 - Self.eyeGap / 2 - half + Int(gazeX) + jitterX
        let rcx = Self.screenW / 2 + Self.eyeGap / 2 + half + Int(gazeX) + jitterX
        var hScale: Float = 1 + pop * (emotion == .surprised ? 0.3 : 0.12)
        hScale *= 1 - squint * 0.4
        if asleep { hScale += twitch * 2.5 }

        let ew: CGFloat = 22
        var eh = CGFloat(34 * hScale * (1 - blinkAmount)) * (asleep ? 0.08 : 1)
        eh += emotion == .surprised ? 10 : 0
        eh -= emotion == .sleepy ? 12 : 0
        eh = max(2, eh)
        let cy = CGFloat(cyI) - (withMouth ? 5 : 0)

        for (cxI, isLeft) in [(lcx, true), (rcx, false)] {
            let cx = CGFloat(cxI)
            let x = cx - ew / 2, y = cy - eh / 2
            c.saveGState()
            c.translateBy(x: cx, y: cy)
            var tilt = CGFloat(cur.browSlant / 9) * (isLeft ? -0.18 : 0.18)
            if emotion == .thinking { tilt += isLeft ? -0.06 : 0.06 }
            c.rotate(by: tilt)
            c.translateBy(x: -cx, y: -cy)
            c.setFillColor(gray: 1, alpha: 1)
            let r = min(7, eh / 2)
            c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: ew, height: eh), cornerWidth: r, cornerHeight: r, transform: nil))
            c.fillPath()
            c.setFillColor(gray: 0, alpha: 1)
            if cur.lowerLid > 0.5 {
                let ly = y + eh + ew * 0.9 - CGFloat(cur.lowerLid) * 0.9
                c.fillEllipse(in: CGRect(x: cx - ew * 0.95, y: ly - ew * 0.9, width: ew * 1.9, height: ew * 1.8))
            }
            if cur.upperLid > 0.5 {
                c.fill(CGRect(x: x - 2, y: y - 2, width: ew + 4, height: CGFloat(cur.upperLid) * 0.8 + 2))
            }
            if emotion == .angry {
                c.move(to: CGPoint(x: isLeft ? x - 2 : x + ew + 2, y: y - 2))
                c.addLine(to: CGPoint(x: isLeft ? x + ew + 2 : x - 2, y: y - 2))
                c.addLine(to: CGPoint(x: isLeft ? x + ew + 2 : x - 2, y: y + 7))
                c.closePath(); c.fillPath()
            }
            c.restoreGState()
        }

        c.setFillColor(gray: 1, alpha: 1)
        c.setStrokeColor(gray: 1, alpha: 1)
        if asleep {
            for z in zeds where z.alive {
                if z.age > 0.8 && frame % 2 == 0 { continue }
                let sz: CGFloat = z.age < 0.33 ? 6 : (z.age < 0.66 ? 9 : 12)
                let zx = CGFloat(z.x), zy = CGFloat(z.y)
                c.setLineWidth(z.age < 0.33 ? 1.2 : 1.8)
                c.move(to: CGPoint(x: zx, y: zy - sz)); c.addLine(to: CGPoint(x: zx + sz * 0.7, y: zy - sz))
                c.addLine(to: CGPoint(x: zx, y: zy)); c.addLine(to: CGPoint(x: zx + sz * 0.7, y: zy))
                c.strokePath()
            }
            return
        }
        if emotion == .thinking {
            for i in 0..<thinkDots { c.fillEllipse(in: CGRect(x: CGFloat(Self.screenW - 26 + i * 8) - 2, y: 7, width: 4, height: 4)) }
        }
        guard withMouth else { return }

        let my = cy + eh / 2 + 9
        let mx = CGFloat(Self.screenW / 2) + CGFloat(gazeX * 0.5)
        c.setLineWidth(3); c.setLineCap(.round)
        if talking && mouth > 0.1 {
            let mh = CGFloat(2 + mouth * 9), mw = CGFloat(16 + mouth * 8)
            let rr = min(mh / 2, 4)
            c.addPath(CGPath(roundedRect: CGRect(x: mx - mw / 2, y: my - mh / 2, width: mw, height: mh), cornerWidth: rr, cornerHeight: rr, transform: nil))
            c.fillPath()
            if mh > 6 {
                c.setFillColor(gray: 0, alpha: 1)
                c.addPath(CGPath(roundedRect: CGRect(x: mx - mw / 2 + 3, y: my - mh / 2 + 2, width: mw - 6, height: mh - 4), cornerWidth: 2, cornerHeight: 2, transform: nil))
                c.fillPath()
            }
            return
        }
        switch emotion {
        case .happy:
            c.move(to: CGPoint(x: mx - 9, y: my - 3)); c.addQuadCurve(to: CGPoint(x: mx + 9, y: my - 3), control: CGPoint(x: mx, y: my + 6)); c.strokePath()
        case .sad:
            c.move(to: CGPoint(x: mx - 8, y: my + 2)); c.addQuadCurve(to: CGPoint(x: mx + 8, y: my + 2), control: CGPoint(x: mx, y: my - 5)); c.strokePath()
        case .surprised:
            c.fillEllipse(in: CGRect(x: mx - 3.5, y: my - 3.5, width: 7, height: 7))
            c.setFillColor(gray: 0, alpha: 1)
            c.fillEllipse(in: CGRect(x: mx - 1.5, y: my - 1.5, width: 3, height: 3))
        case .angry:
            c.move(to: CGPoint(x: mx - 8, y: my + 1)); c.addLine(to: CGPoint(x: mx + 8, y: my - 1)); c.strokePath()
        case .sleepy:
            c.move(to: CGPoint(x: mx - 5, y: my)); c.addLine(to: CGPoint(x: mx + 5, y: my)); c.strokePath()
        default:
            c.move(to: CGPoint(x: mx - 6, y: my)); c.addLine(to: CGPoint(x: mx + 6, y: my)); c.strokePath()
        }
    }
}
