import SwiftUI
import UIKit

extension EnvironmentValues {
    /// false: clay faces are drawn still (a sheet hidden under the chat).
    @Entry var avatarMotion: Bool = true
}

/// A bot's face: the Mac's character picture when it sends one, otherwise a clay figure drawn here.
struct BotAvatar: View {
    var icon: String?
    var name: String
    var size: CGFloat = 40
    var avatar: String? = nil
    /// `working` · `waiting` · `off` · nil (idle). Changes the face and how it moves.
    var status: String? = nil
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().clipShape(Circle())
            } else {
                // Only a big face moves; the many small faces in lists stay still (status still shows in the eyes). A working bot hopping at 30 fps kept the screen busy.
                ClayCharacter(seed: name, mood: ClayCharacter.Mood(status: status, seed: name, ordinal: model.characterOrdinal(name)),
                              ordinal: model.characterOrdinal(name), animated: size >= 72)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: avatar) { image = await model.avatarImage(avatar) }
    }
}

/// A little clay figure: a smooth matte body and two eyes whose shape shows how the bot is doing. Everything except the mood comes from the name, so a bot always looks the same.
struct ClayCharacter: View {
    enum Mood: CaseIterable {
        case happy, proud, cheeky, calm, focused, worried, sleepy, surprised

        /// Status picks the face; idle bots get one of the cheerful faces by name.
        init(status: String?, seed: String, ordinal: Int? = nil) {
            switch status {
            case "working": self = .focused
            case "waiting": self = .worried
            case "off": self = .sleepy
            default:
                let cheerful: [Mood] = [.happy, .proud, .cheeky, .calm, .surprised]
                self = cheerful[(ordinal.map { $0 * 2 } ?? ClayCharacter.hash(seed + "mood")) % cheerful.count]
            }
        }
    }

    var seed: String
    var mood: Mood
    /// Position in the bot list; when known, colours and toppers step through the set so no two neighbours match.
    var ordinal: Int? = nil
    /// false = a still face (no 30-a-second redraw).
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// FNV-1a with a final mix, so similar names ("개발 봇", "검사 봇") still land far apart.
    static func hash(_ text: String) -> Int {
        var x: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { x = (x ^ UInt64(byte)) &* 0x100000001b3 }
        x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
        return Int(x % UInt64(Int32.max))
    }

    private var h: Int { Self.hash(seed + "#shape") }
    private func trait(_ salt: String) -> Int { Self.hash(seed + "#" + salt) }
    /// Soft, chalky clay colours (no neon).
    private var palette: (body: Color, light: Color, dark: Color) {
        // Clear pastel toy colours; no browns or muddy yellows (those read as potatoes).
        let hues: [Double] = [0.97, 0.01, 0.14, 0.27, 0.42, 0.48, 0.55, 0.60, 0.70, 0.78, 0.86]
        let hue = hues[(ordinal.map { $0 * 4 } ?? trait("hue")) % hues.count]
        let sat = hue == 0.14 ? 0.55 : 0.48
        return (Color(hue: hue, saturation: sat, brightness: 0.97),
                Color(hue: hue, saturation: 0.18, brightness: 1.0),
                Color(hue: hue, saturation: 0.62, brightness: 0.72))
    }

    /// false while the face is out of sight (the room list under the chat).
    @Environment(\.avatarMotion) private var motion

    var body: some View {
        if reduceMotion || !animated || !motion {
            // t = 1: eyes open (t = 0 lands on a blink).
            figure(t: 1)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                figure(t: context.date.timeIntervalSinceReferenceDate + Double(h % 997) / 37)
            }
        }
    }

    private func figure(t: Double) -> some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let colors = palette
            // Motion: working hops, everyone else breathes slowly; sleepy sways.
            let hop = mood == .focused ? abs(sin(t * 4.2)) : 0
            let breathe = mood == .focused ? 0 : (mood == .sleepy ? sin(t * 0.9) * 0.03 : sin(t * 1.6) * 0.015)
            let sway = mood == .sleepy ? sin(t * 0.9) * 4 : 0
            let squash = mood == .focused ? (1 - hop) * 0.06 : 0

            ZStack {
                // Ground shadow so it sits on the page like a real object.
                Ellipse().fill(Color.black.opacity(scheme == .dark ? 0.35 : 0.12))
                    .frame(width: s * (0.62 - hop * 0.12), height: s * 0.08)
                    .blur(radius: s * 0.02)
                    .offset(y: s * 0.43)

                ZStack {
                    ClayBlob(seed: h)
                        .fill(colors.body)
                        .overlay(
                            // Matte shading: light from the top left, deeper clay underneath.
                            ClayBlob(seed: h).fill(RadialGradient(colors: [colors.light.opacity(0.9), .clear],
                                                                  center: UnitPoint(x: 0.32, y: 0.25), startRadius: 0, endRadius: s * 0.5))
                        )
                        .overlay(
                            ClayBlob(seed: h).fill(LinearGradient(colors: [.clear, colors.dark.opacity(0.55)], startPoint: .center, endPoint: .bottom))
                        )
                        .overlay(ClayBlob(seed: h).stroke(colors.dark.opacity(0.35), lineWidth: s * 0.02).blur(radius: s * 0.012))
                        .overlay(
                            // Soft clay sheen: one wide highlight, no speckles.
                            Ellipse().fill(.white.opacity(0.55)).frame(width: s * 0.22, height: s * 0.1)
                                .rotationEffect(.degrees(-28)).blur(radius: s * 0.02).offset(x: -s * 0.18, y: -s * 0.2)
                        )
                        .frame(width: s * 0.8, height: s * 0.72)
                        // The body's gradients and blurs flattened into one layer (with room for the soft edge).
                        .padding(s * 0.05).drawingGroup().padding(-s * 0.05)
                        .offset(y: s * 0.04)
                    eyes(s: s, t: t)
                        .offset(y: s * 0.02)
                }
                .scaleEffect(x: 1 + squash + breathe, y: 1 - squash + breathe, anchor: .bottom)
                .rotationEffect(.degrees(sway), anchor: .bottom)
                .offset(y: -hop * s * 0.1)

                if mood == .sleepy { sleepZs(s: s, t: t) }
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: sleeping

    /// Three small z's drift up from the head one after another and fade out.
    private func sleepZs(s: CGFloat, t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let phase = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: s * (0.16 + 0.08 * phase), weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .opacity(phase < 0.15 ? phase / 0.15 : 1 - (phase - 0.15) / 0.85)
                    .offset(x: s * (0.22 + 0.14 * phase) + CGFloat(sin(phase * 6)) * s * 0.02,
                            y: -s * (0.2 + 0.32 * phase))
            }
        }
    }

    // MARK: eyes only — the whole face

    /// Just two eyes; the mood lives in their shape. No mouth, pupils, cheeks or props.
    @ViewBuilder private func eyes(s: CGFloat, t: Double) -> some View {
        let ink = Color(white: 0.15)
        let blinking = t.truncatingRemainder(dividingBy: 3.7) < 0.13
        let look: CGFloat = mood == .focused ? CGFloat(sin(t * 1.3)) * s * 0.025 : 0
        HStack(spacing: s * 0.17) {
            simpleEye(s: s, ink: ink, blinking: blinking, left: true)
            simpleEye(s: s, ink: ink, blinking: blinking, left: false)
        }
        .offset(x: look, y: mood == .worried ? s * 0.02 : 0)
    }

    @ViewBuilder private func simpleEye(s: CGFloat, ink: Color, blinking: Bool, left: Bool) -> some View {
        let line = StrokeStyle(lineWidth: s * 0.035, lineCap: .round, lineJoin: .round)
        switch mood {
        case .happy, .proud:
            ArcLine(up: true).stroke(ink, style: line).frame(width: s * 0.1, height: s * 0.045)
        case .sleepy, .calm:
            Capsule().fill(ink).frame(width: s * 0.1, height: s * 0.03)
        case .focused:
            // > <
            Chevron(pointsRight: left).stroke(ink, style: line).frame(width: s * 0.07, height: s * 0.08)
        case .worried:
            Ellipse().fill(ink).frame(width: s * 0.07, height: s * 0.09)
                .rotationEffect(.degrees(left ? -12 : 12))
                .scaleEffect(x: 1, y: blinking ? 0.12 : 1)
        default:
            Ellipse().fill(ink).frame(width: s * (mood == .surprised ? 0.09 : 0.075), height: s * (mood == .surprised ? 0.11 : 0.095))
                .scaleEffect(x: 1, y: blinking ? 0.12 : 1)
        }
    }

}

// MARK: shapes

/// A lumpy, bottom-heavy body: radius wobbles a little with angle, like hand-pressed clay.
struct ClayBlob: Shape {
    var seed: Int
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        let p1 = Double(seed % 628) / 100, p2 = Double((seed / 628) % 628) / 100
        var path = Path()
        let steps = 72
        for i in 0...steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            // Barely-there wobble (hand-made, not lumpy) and a wider base like a gumdrop toy.
            var r = 1 + 0.01 * sin(3 * a + p1) + 0.006 * sin(5 * a + p2)
            if sin(a) > 0 { r += 0.05 * sin(a) * abs(cos(a)) }
            let x = c.x + CGFloat(cos(a) * r) * rx * 0.96
            let y = c.y + CGFloat(sin(a) * r) * ry * 0.96
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }
}

struct ArcLine: Shape {
    /// true = ∩ (smiling eyes), false = ∪ (smile)
    var up: Bool
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: up ? r.maxY : r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: up ? r.maxY : r.minY), control: CGPoint(x: r.midX, y: up ? r.minY - r.height : r.maxY + r.height))
        }
    }
}

struct Chevron: Shape {
    var pointsRight: Bool
    func path(in r: CGRect) -> Path {
        Path { p in
            if pointsRight {
                p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            } else {
                p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            }
        }
    }
}
