import SwiftUI

/// The face, drawn at 30 fps on a dark "screen" with a soft bezel.
struct FaceView: View {
    @ObservedObject var robot: Robot
    var scale: CGFloat
    var ink: Color { robot.eyeColor.color }
    let paper = Color(red: 0.03, green: 0.04, blue: 0.06)

    var body: some View {
        let w = CGFloat(FaceEngine.screenW) * scale
        let h = CGFloat(FaceEngine.screenH) * scale
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                robot.face.step(now: UInt64(tl.date.timeIntervalSince1970 * 1000))
                var inner = ctx
                inner.scaleBy(x: scale, y: scale)
                if robot.face.style == .cozmoDots {
                    let dots = robot.face.dotMatrixPath()
                    var glow = inner
                    glow.addFilter(.blur(radius: 1.2))
                    glow.fill(dots, with: .color(ink.opacity(0.55)))
                    inner.fill(dots, with: .color(ink))
                } else {
                    inner.withCGContext { $0.setShouldAntialias(false) }
                    robot.face.draw(in: &inner, ink: ink, paper: paper)
                }
                if !robot.connected { drawOffline(&ctx, size: size) }
                drawIndicator(&ctx, size: size)
                drawAgents(&ctx, size: size)
            }
            .frame(width: w, height: h)
        }
        .background(paper)
        .clipShape(RoundedRectangle(cornerRadius: 8 * scale / 2, style: .continuous))
        .padding(4 * scale / 2)
        .background(
            RoundedRectangle(cornerRadius: 11 * scale / 2, style: .continuous)
                .fill(Color(white: 0.12))
                .overlay(RoundedRectangle(cornerRadius: 11 * scale / 2, style: .continuous).stroke(Color.white.opacity(0.08)))
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }

    private func drawOffline(_ ctx: inout GraphicsContext, size: CGSize) {
        let text = robot.brain.isRunning ? "waking up…" : "brain is off"
        ctx.draw(Text(text).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(ink.opacity(0.55)),
                 at: CGPoint(x: size.width / 2, y: size.height - 9))
    }

    /// Bottom-right: one small square per sub-agent at work (pulsing) and an
    /// amber one per sub-agent waiting on the human.
    private func drawAgents(_ ctx: inout GraphicsContext, size: CGSize) {
        let n = robot.busyAgents, w = robot.waitingAgents
        guard n + w > 0 else { return }
        let s: CGFloat = 5, gap: CGFloat = 3
        let pulse = 0.55 + 0.45 * (1 + sin(Date().timeIntervalSince1970 * 2.4)) / 2
        var x = size.width - 6 - s
        let y = size.height - 6 - s
        for _ in 0..<min(w, 5) {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: s, height: s), cornerRadius: 1), with: .color(Color(red: 1, green: 0.72, blue: 0.25)))
            x -= s + gap
        }
        for _ in 0..<min(n, 5) {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: s, height: s), cornerRadius: 1), with: .color(ink.opacity(pulse)))
            x -= s + gap
        }
    }

    /// One small dot, bottom-left: green = can hear you, blue = talking, dim = mic off.
    private func drawIndicator(_ ctx: inout GraphicsContext, size: CGSize) {
        guard robot.connected else { return }
        let st = robot.status
        let color: Color
        if st?.speaking == true { color = Color(red: 0.4, green: 0.7, blue: 1) }
        else if st?.hearing == true { color = Color(red: 0.4, green: 1, blue: 0.55) }
        else if robot.listening { color = ink.opacity(st?.awake == true ? 0.5 : 0.22) }
        else { color = Color(red: 1, green: 0.45, blue: 0.4).opacity(0.8) }
        let r: CGFloat = 2.5
        ctx.fill(Path(ellipseIn: CGRect(x: 6, y: size.height - 6 - r * 2, width: r * 2, height: r * 2)), with: .color(color))
    }
}

/// Reports the bubble's height so the panel can grow upward to fit it.
struct BubbleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A speech bubble: what he heard, what he's saying, and the typed question box.
struct SpeechBubble: View {
    @ObservedObject var robot: Robot
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var width: CGFloat
    var onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !robot.lastHeard.isEmpty && robot.heardIsRecent && (robot.askShown || !robot.saying.isEmpty) {
                Text(robot.lastHeard)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !robot.saying.isEmpty {
                Text(robot.saying)
                    .font(.system(size: 12.5))
                    .lineLimit(10)
                    .fixedSize(horizontal: false, vertical: true)
            } else if robot.status?.thinking == true || (robot.askShown == false && robot.bubbleShown) {
                Text("…").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            if robot.askShown {
                HStack(spacing: 6) {
                    TextField("Type to \(RobotName.value)…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused(focused)
                        .onSubmit(onSend)
                    Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 16)) }
                        .buttonStyle(.plain)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(alignment: .bottom) {
            // the little tail pointing at the face
            Path { p in p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 14, y: 0)); p.addLine(to: .init(x: 7, y: 7)); p.closeSubpath() }
                .fill(.regularMaterial)
                .frame(width: 14, height: 7)
                .offset(x: 0, y: 7)
        }
        .background(GeometryReader { g in Color.clear.preference(key: BubbleHeightKey.self, value: g.size.height) })
    }
}

/// The face, with the speech bubble above it.
struct PanelContent: View {
    @ObservedObject var robot: Robot
    @State private var text = ""
    @State private var hoverButton = false
    @FocusState private var focused: Bool
    var scale: CGFloat
    /// Inset of the corner menu button from the face's top-left, in points.
    static func buttonInset(scale: CGFloat) -> CGFloat { 8 + 2 * scale + 4 }
    static let bubbleGap: CGFloat = 10

    var body: some View {
        VStack(spacing: Self.bubbleGap) {
            if robot.bubbleShown {
                SpeechBubble(robot: robot, text: $text, focused: $focused,
                             width: CGFloat(FaceEngine.screenW) * scale + 4 * scale, onSend: send)
                    .onAppear { if robot.askShown { focused = true } }
                    .onChange(of: robot.askShown) { _, shown in if shown { focused = true } }
            }
            FaceView(robot: robot, scale: scale)
                .overlay(alignment: .topLeading) {
                    // Visual only: the panel opens the menu when this corner is clicked.
                    Image(systemName: "line.3.horizontal.circle.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.white.opacity(hoverButton ? 0.95 : 0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .onHover { hoverButton = $0 }
                        .padding(.leading, 2 * scale + 4)
                        .padding(.top, 2 * scale + 4)
                        .help("Menu")
                }
        }
        .padding(8)
        .onPreferenceChange(BubbleHeightKey.self) { h in
            FacePanelController.shared?.bubbleHeight = robot.bubbleShown ? h : 0
        }
        .onChange(of: robot.bubbleShown) { _, shown in if !shown { FacePanelController.shared?.bubbleHeight = 0 } }
    }

    private func send() {
        let t = text
        text = ""
        robot.ask(t)
        robot.askShown = false
    }
}

enum RobotName {
    static var value: String { UserDefaults.standard.string(forKey: "robotName") ?? "Rocky" }
}
