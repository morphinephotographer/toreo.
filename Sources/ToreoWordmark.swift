import CoreText
import SwiftUI

struct ToreoWordmark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var bounce = 0

    var body: some View {
        if reduceMotion {
            Text("toreo.")
        } else {
            Button {
                bounce += 1
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("tore")
                    KeyframeAnimator(initialValue: CGFloat.zero, trigger: bounce) { progress in
                        let moving = progress > 0 && progress < 1
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("o")
                            Text(".")
                        }
                        .opacity(moving ? 0 : 1)
                        .overlay {
                            if moving {
                                WordmarkTrampoline(progress: progress, displayScale: displayScale)
                                    .padding(-MenuGrid.gutter)
                                    .allowsHitTesting(false)
                            }
                        }
                    } keyframes: { _ in
                        MoveKeyframe(0)
                        LinearKeyframe(1, duration: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("toreo.")
            .help(tr("Анимировать логотип"))
        }
    }
}

private struct WordmarkTrampoline: View {
    let progress: CGFloat
    let displayScale: CGFloat

    private static let letterInk = inkBounds(of: "o")
    private static let dotInk = inkBounds(of: ".")
    private static let motion = TrampolineMotion(ascent: letterInk.maxY, em: MenuGrid.titleSize)

    var body: some View {
        let letterInk = Self.letterInk
        let dotInk = Self.dotInk
        let motion = Self.motion
        let pose = motion.pose(at: progress)
        let font = Font.system(size: MenuGrid.titleSize, weight: .bold)
        let inset = MenuGrid.gutter
        Canvas { context, size in
            let letter = context.resolve(Text("o").font(font))
            let dot = context.resolve(Text(".").font(font))
            let available = CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset)
            let baseline = inset + letter.firstBaseline(in: available)
            let letterWidth = letter.measure(in: available).width
            let letterOrigin = CGPoint(x: inset, y: inset)

            Self.drawLetter(letter, in: context, origin: letterOrigin, size: size,
                            middle: baseline - letterInk.maxY / 2, ink: letterInk,
                            depth: pose.depth, displayScale: displayScale)

            let dotCenter = inset + letterWidth + dotInk.midX
            let distance = inset + letterInk.midX - dotCenter
            var dotContext = context
            dotContext.translateBy(x: dotCenter + distance * pose.towardO, y: baseline + pose.y)
            dotContext.scaleBy(x: pose.squash, y: 1 / pose.squash)
            dotContext.draw(dot, at: CGPoint(x: -dotInk.midX, y: -dot.firstBaseline(in: available)),
                            anchor: .topLeading)
        }
    }

    private static func inkBounds(of character: String) -> CGRect {
        let font = NSFont.systemFont(ofSize: MenuGrid.titleSize, weight: .bold)
        let text = NSAttributedString(string: character, attributes: [.font: font])
        return CTLineGetImageBounds(CTLineCreateWithAttributedString(text), nil)
    }

    private static func drawLetter(_ letter: GraphicsContext.ResolvedText, in context: GraphicsContext,
                                   origin: CGPoint, size: CGSize, middle: CGFloat, ink: CGRect,
                                   depth: CGFloat, displayScale: CGFloat) {
        guard depth != 0 else {
            context.draw(letter, at: origin, anchor: .topLeading)
            return
        }

        var lower = context
        lower.clip(to: Path(CGRect(x: 0, y: middle, width: size.width, height: size.height - middle)))
        lower.draw(letter, at: origin, anchor: .topLeading)

        let upperHeight = middle - origin.y
        let center = origin.x + ink.midX
        let reach = 0.45 * ink.width
        let firstColumn = Int(floor((origin.x + ink.minX - 1) * displayScale))
        let lastColumn = Int(ceil((origin.x + ink.maxX + 1) * displayScale))
        for column in firstColumn..<lastColumn {
            let x = CGFloat(column) / displayScale
            let u = (x + 0.5 / displayScale - center) / reach
            let weight = abs(u) < 1 ? cos(.pi / 2 * u) : 0
            let shift = depth * weight * weight
            // Compress into the counter, then stretch back up from the fixed midline.
            let height = upperHeight - min(shift, 0)
            var slice = context
            slice.clip(to: Path(CGRect(x: x, y: origin.y + shift, width: 1 / displayScale, height: height)),
                       style: FillStyle(antialiased: false))
            slice.translateBy(x: origin.x, y: origin.y + shift)
            slice.scaleBy(x: 1, y: height / upperHeight)
            slice.draw(letter, at: .zero, anchor: .topLeading)
        }
    }
}

private struct TrampolineMotion {
    struct Pose {
        let depth: CGFloat
        let towardO: CGFloat
        let y: CGFloat
        let squash: CGFloat
    }

    private enum Ease {
        case linear, rise, fall, smooth

        func apply(_ progress: CGFloat) -> CGFloat {
            switch self {
            case .linear: progress
            case .rise: 1 - (1 - progress) * (1 - progress)
            case .fall: progress * progress
            case .smooth: progress * progress * (3 - 2 * progress)
            }
        }
    }

    private struct Key {
        let time: CGFloat
        let value: CGFloat
        let ease: Ease

        init(_ time: CGFloat, _ value: CGFloat, _ ease: Ease = .linear) {
            self.time = time
            self.value = value
            self.ease = ease
        }
    }

    // Teleo's trampoline tracks, sampled over the same one-second interval.
    private static let bend = [
        Key(0, 0), Key(0.27, 0, .rise), Key(0.39, 1, .fall), Key(0.47, -0.12, .rise),
        Key(0.57, 0.06, .smooth), Key(0.66, -0.02, .smooth), Key(0.74, 0), Key(1, 0)
    ]
    private static let horizontal = [
        Key(0, 0), Key(0.06, 0), Key(0.27, 1), Key(0.47, 1), Key(0.78, 0), Key(1, 0)
    ]
    private static let squash = [
        Key(0, 1), Key(0.06, 1.2, .smooth), Key(0.12, 0.92, .smooth), Key(0.27, 1, .smooth),
        Key(0.39, 1.15, .smooth), Key(0.47, 0.9, .smooth), Key(0.56, 1), Key(0.76, 1),
        Key(0.78, 1.25, .smooth), Key(0.84, 1), Key(0.92, 1), Key(0.94, 1.1, .smooth), Key(1, 1)
    ]
    private let top: CGFloat
    private let dent: CGFloat
    private let flight: [Key]

    init(ascent: CGFloat, em: CGFloat) {
        let top = -ascent
        let dent = 0.42 * ascent
        self.top = top
        self.dent = dent
        flight = [
            Key(0, 0), Key(0.06, 0, .rise), Key(0.17, top - 0.22 * em, .fall), Key(0.27, top),
            Key(0.47, top - 0.12 * dent, .rise), Key(0.62, top - 0.42 * em, .fall),
            Key(0.78, 0, .rise), Key(0.87, -0.12 * em, .fall), Key(0.94, 0), Key(1, 0)
        ]
    }

    func pose(at time: CGFloat) -> Pose {
        let depth = dent * Self.sample(Self.bend, at: time)
        let y = (0.27...0.47).contains(time) ? top + depth : Self.sample(flight, at: time)
        return Pose(depth: depth, towardO: Self.sample(Self.horizontal, at: time),
                    y: y, squash: Self.sample(Self.squash, at: time))
    }

    private static func sample(_ keys: [Key], at time: CGFloat) -> CGFloat {
        guard let index = keys.indices.dropFirst().first(where: { time < keys[$0].time }) else {
            return keys[keys.count - 1].value
        }
        let start = keys[index - 1]
        let end = keys[index]
        let fraction = (time - start.time) / (end.time - start.time)
        return start.value + (end.value - start.value) * start.ease.apply(fraction)
    }
}
