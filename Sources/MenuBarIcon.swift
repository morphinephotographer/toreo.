import AppKit

@MainActor
final class MenuBarIcon: NSObject {
    private struct Completion {
        let hash: String
        let startedAt: TimeInterval
        let waveMotion: Double
    }

    private static let transitionDuration = 0.72
    private static let holdDuration = 1.5
    private static let returnDuration = 0.36
    private static let frameInterval = 1.0 / 30
    private static let idle = StatusGlyph()

    private weak var button: NSStatusBarButton?
    private let colorOverlay = StatusColorOverlay()
    private let completionSound: @MainActor () -> Void
    private var previousCompletion: [String: Bool] = [:]
    private var pending: [String] = []
    private var completion: Completion?
    private var downloadStartedAt: TimeInterval?
    private var lastFrame: StatusGlyph?
    private var animation: Task<Void, Never>?

    var completionPending: Bool { completion != nil }

    init(button: NSStatusBarButton, completionSound: @escaping @MainActor () -> Void) {
        self.button = button
        self.completionSound = completionSound
        super.init()

        // AppKit tints the base template for the actual menu bar backdrop.
        // The second image supplies only the green portions during completion.
        colorOverlay.translatesAutoresizingMaskIntoConstraints = false
        colorOverlay.imageScaling = .scaleNone
        button.addSubview(colorOverlay)
        NSLayoutConstraint.activate([
            colorOverlay.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            colorOverlay.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            colorOverlay.widthAnchor.constraint(equalToConstant: StatusGlyph.size.width),
            colorOverlay.heightAnchor.constraint(equalToConstant: StatusGlyph.size.height)
        ])
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(restartAnimation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    func update(transfers: [Transfer]) {
        let now = ProcessInfo.processInfo.systemUptime
        let wasDownloading = downloadStartedAt != nil
        let isDownloading = transfers.contains { $0.downloading && $0.error == 0 }
        let wasCompleting = completionPending
        let previousWave = waveMotion(at: now)
        let failed = Set(transfers.lazy.filter { $0.error != 0 }.map(\.hashString))

        pending.removeAll { failed.contains($0) }
        for transfer in transfers where transfer.complete && transfer.error == 0 {
            if previousCompletion[transfer.hashString] == false {
                pending.append(transfer.hashString)
            }
        }
        previousCompletion = Dictionary(transfers.map { ($0.hashString, $0.complete) },
                                        uniquingKeysWith: { _, latest in latest })

        if isDownloading != wasDownloading { downloadStartedAt = isDownloading ? now : nil }
        let failedCompletion = completion.map { failed.contains($0.hash) } == true
        if failedCompletion { completion = nil }
        if completion == nil { beginNextCompletion(at: now, waveMotion: previousWave) }
        updateAccessibility()

        if lastFrame == nil || isDownloading != wasDownloading || failedCompletion
            || wasCompleting != completionPending {
            restartAnimation()
        }
    }

    func acknowledgeCompletion() {
        let now = ProcessInfo.processInfo.systemUptime
        completion = nil
        beginNextCompletion(at: now, waveMotion: waveMotion(at: now))
        updateAccessibility()
        restartAnimation()
    }

    func stop() {
        animation?.cancel()
        animation = nil
        colorOverlay.removeFromSuperview()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func beginNextCompletion(at now: TimeInterval, waveMotion: Double) {
        guard !pending.isEmpty else { return }
        completion = Completion(hash: pending.removeFirst(), startedAt: now, waveMotion: waveMotion)
        completionSound()
    }

    private func updateAccessibility() {
        button?.setAccessibilityLabel(tr(completionPending ? "Загрузка завершена" : "Передачи toreo."))
    }

    @objc private func restartAnimation() {
        animation?.cancel()
        animation = nil
        guard let delay = drawFrame(at: ProcessInfo.processInfo.systemUptime) else { return }
        animation = Task { [weak self] in
            var nextDelay = delay
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(nextDelay), tolerance: .milliseconds(3))
                } catch { return }
                guard let next = self?.drawFrame(at: ProcessInfo.processInfo.systemUptime) else { return }
                nextDelay = next
            }
        }
    }

    private func waveMotion(at now: TimeInterval) -> Double {
        guard let downloadStartedAt else { return 0 }
        return sin((now - downloadStartedAt) * 2 * .pi / 1.7)
    }

    private func drawFrame(at now: TimeInterval) -> TimeInterval? {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transition = reduceMotion ? 0 : Self.transitionDuration
        let holdEnd = transition + Self.holdDuration
        let end = holdEnd + (reduceMotion ? 0 : Self.returnDuration)
        let motion = reduceMotion ? 0 : waveMotion(at: now)

        if let completion, now - completion.startedAt >= end {
            self.completion = nil
            beginNextCompletion(at: now, waveMotion: motion)
            updateAccessibility()
        }
        guard let completion else {
            display(motion == 0 ? Self.idle : StatusGlyph(motion: motion))
            return !reduceMotion && downloadStartedAt != nil ? Self.frameInterval : nil
        }

        let elapsed = now - completion.startedAt
        if elapsed < transition {
            let flatten = Self.ease(elapsed / 0.26)
            display(StatusGlyph(
                motion: completion.waveMotion * (1 - flatten),
                amplitude: 1 - flatten,
                waveOpacity: 1 - Self.ease((elapsed - 0.26) / 0.15),
                green: Self.ease((elapsed - 0.41) / 0.31),
                checkProgress: Self.ease((elapsed - 0.48) / 0.24)
            ))
            return Self.frameInterval
        }
        if elapsed < holdEnd {
            display(StatusGlyph(amplitude: 0, waveOpacity: 0, green: 1, checkProgress: 1))
            return holdEnd - elapsed
        }

        let returning = elapsed - holdEnd
        let wave = Self.ease((returning - 0.12) / 0.24)
        display(StatusGlyph(motion: motion * wave, amplitude: wave, waveOpacity: wave,
                            green: 1 - Self.ease(returning / 0.30), checkProgress: 1,
                            checkOpacity: 1 - Self.ease(returning / 0.16)))
        return Self.frameInterval
    }

    private func display(_ frame: StatusGlyph) {
        guard lastFrame != frame else { return }
        if lastFrame?.sameMonochrome(as: frame) != true { button?.image = frame.monochromeImage() }
        if lastFrame?.sameColor(as: frame) != true { colorOverlay.image = frame.colorImage() }
        lastFrame = frame
    }

    private static func ease(_ fraction: Double) -> Double {
        let t = min(1, max(0, fraction))
        return t * t * (3 - 2 * t)
    }
}

private final class StatusColorOverlay: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

private struct StatusGlyph: Equatable {
    // The outline occupies 57.2 of the 64 drawing units, about 15 pt at this size.
    static let size = NSSize(width: 17, height: 17)
    private static let greenInk = CGColor(red: 56.0 / 255, green: 216.0 / 255, blue: 121.0 / 255, alpha: 1)

    var motion = 0.0
    var amplitude = 1.0
    var waveOpacity = 1.0
    var green = 0.0
    var checkProgress = 0.0
    var checkOpacity = 1.0

    func sameMonochrome(as other: Self) -> Bool {
        (green == 1) == (other.green == 1) && motion == other.motion
            && amplitude == other.amplitude && waveOpacity == other.waveOpacity
    }

    func sameColor(as other: Self) -> Bool {
        green == other.green && checkProgress == other.checkProgress && checkOpacity == other.checkOpacity
    }

    func monochromeImage() -> NSImage {
        image(template: true) { context in
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            if green < 1 { Self.strokeCircle(in: context) }
            guard waveOpacity > 0 else { return }
            context.setAlpha(waveOpacity)
            for index in 0...24 {
                let t = Double(index) / 24
                // Taper only the animated displacement so the endpoints stay on the circle.
                let baseWave = sin(t * 2 * .pi) * 5.5
                let movingWave = sin(.pi * t) * (sin(t * 2 * .pi + motion * 0.85) * 5.5 - baseWave
                                                 + motion * 4)
                let point = CGPoint(x: 5 + 54 * t, y: 32 + (baseWave + movingWave) * amplitude)
                if index == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.strokePath()
        }
    }

    func colorImage() -> NSImage? {
        guard green > 0 || (checkProgress > 0 && checkOpacity > 0) else { return nil }
        return image(template: false) { context in
            context.setStrokeColor(Self.greenInk)
            context.setAlpha(green)
            Self.strokeCircle(in: context)
            guard checkProgress > 0, checkOpacity > 0 else { return }

            context.setAlpha(checkOpacity)
            let start = CGPoint(x: 21, y: 32)
            let corner = CGPoint(x: 29, y: 24)
            let end = CGPoint(x: 44, y: 40)
            let firstLength = hypot(corner.x - start.x, corner.y - start.y)
            let secondLength = hypot(end.x - corner.x, end.y - corner.y)
            let distance = (firstLength + secondLength) * checkProgress
            context.move(to: start)
            if distance <= firstLength {
                context.addLine(to: Self.interpolate(from: start, to: corner, fraction: distance / firstLength))
            } else {
                context.addLine(to: corner)
                context.addLine(to: Self.interpolate(from: corner, to: end,
                                                    fraction: (distance - firstLength) / secondLength))
            }
            context.strokePath()
        }
    }

    private func image(template: Bool, draw: @escaping (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: Self.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / 64, y: rect.height / 64)
            context.setLineWidth(3.2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            draw(context)
            context.restoreGState()
            return true
        }
        image.isTemplate = template
        return image
    }

    private static func strokeCircle(in context: CGContext) {
        context.strokeEllipse(in: CGRect(x: 5, y: 5, width: 54, height: 54))
    }

    private static func interpolate(from a: CGPoint, to b: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }
}
