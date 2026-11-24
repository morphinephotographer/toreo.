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
    private static let idle = StatusGlyph(amplitude: 0)

    private weak var button: NSStatusBarButton?
    private let colorOverlay = StatusColorOverlay()
    private let completionSound: @MainActor () -> Void
    private var previousCompletion: [String: Bool] = [:]
    private var pending: [String] = []
    private var completion: Completion?
    private var downloadStartedAt: TimeInterval?
    private var lastFrame: StatusGlyph?
    private var animation: Task<Void, Never>?
    private var showsSpeeds = false

    func setShowsSpeeds(_ enabled: Bool, download: Int64, upload: Int64) {
        let changed = showsSpeeds != enabled
        showsSpeeds = enabled
        let speedLabel = "↓ " + rate(download) + "\n↑ " + rate(upload)
        if enabled {
            button?.imagePosition = .noImage
            button?.image = nil
            colorOverlay.image = nil
            button?.attributedTitle = NSAttributedString(
                string: speedLabel,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                             .foregroundColor: NSColor.labelColor]
            )
            button?.setAccessibilityValue(speedLabel.replacingOccurrences(of: "\n", with: ", "))
        } else if changed {
            button?.imagePosition = .imageOnly
            button?.title = ""
            button?.setAccessibilityValue(nil)
        }
        if changed {
            lastFrame = nil
            restartAnimation()
        }
    }

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
        // Tracker warnings and errors (codes 1 and 2) do not stop a transfer, only local errors do.
        let isDownloading = transfers.contains { $0.downloading && !$0.hasLocalError }
        let wasCompleting = completionPending
        let previousWave = waveMotion(at: now)
        let present = Set(transfers.map(\.hashString))
        let failed = Set(transfers.lazy.filter(\.hasLocalError).map(\.hashString))
        let dropped = { (hash: String) in failed.contains(hash) || !present.contains(hash) }

        pending.removeAll(where: dropped)
        for transfer in transfers where transfer.complete && !transfer.hasLocalError && !transfer.verifying {
            let hash = transfer.hashString
            if previousCompletion[hash] == false, !pending.contains(hash), completion?.hash != hash {
                pending.append(hash)
            }
        }
        // A recheck can briefly lower the progress of a finished transfer.
        // Keep the state from before the recheck so it does not look like a new completion.
        var completionState: [String: Bool] = [:]
        for transfer in transfers {
            let hash = transfer.hashString
            completionState[hash] = transfer.verifying
                ? (previousCompletion[hash] ?? transfer.complete) : transfer.complete
        }
        previousCompletion = completionState

        if isDownloading != wasDownloading { downloadStartedAt = isDownloading ? now : nil }
        let failedCompletion = completion.map { dropped($0.hash) } == true
        if failedCompletion { completion = nil }
        if completion == nil { beginNextCompletion(at: now, waveMotion: previousWave) }
        updateAccessibility()

        if lastFrame == nil || isDownloading != wasDownloading || failedCompletion
            || wasCompleting != completionPending {
            restartAnimation()
        }
    }

    /// Opening the panel shows every finished transfer, so one click acknowledges the whole queue.
    func acknowledgeCompletion() {
        pending.removeAll()
        completion = nil
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
            display(downloadStartedAt == nil ? Self.idle : StatusGlyph(motion: motion))
            return !showsSpeeds && !reduceMotion && downloadStartedAt != nil ? Self.frameInterval : nil
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
        display(StatusGlyph(motion: motion * wave, amplitude: downloadStartedAt == nil ? 0 : wave, waveOpacity: wave,
                            green: 1 - Self.ease(returning / 0.30), checkProgress: 1,
                            checkOpacity: 1 - Self.ease(returning / 0.16)))
        return Self.frameInterval
    }

    private func display(_ frame: StatusGlyph) {
        guard !showsSpeeds else { return }
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
    // The two ribbons occupy about 15 pt inside the status button.
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
            guard waveOpacity > 0 else { return }
            context.setAlpha(waveOpacity)
            context.setLineWidth(7)
            context.setLineCap(.butt)
            for baseline in [22.0, 42.0] {
                for index in 0...48 {
                    let t = Double(index) / 48
                    let wave = sin(t * 2 * .pi + motion * 1.4) * 4 * amplitude
                    let point = CGPoint(x: 5 + 54 * t, y: baseline + wave)
                    if index == 0 { context.move(to: point) } else { context.addLine(to: point) }
                }
                context.strokePath()
            }
        }
    }

    func colorImage() -> NSImage? {
        guard green > 0 || (checkProgress > 0 && checkOpacity > 0) else { return nil }
        return image(template: false) { context in
            context.setStrokeColor(Self.greenInk)
            context.setAlpha(green)
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

    private static func interpolate(from a: CGPoint, to b: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }
}
