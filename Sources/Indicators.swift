import AppKit
import SwiftUI

@MainActor
final class Indicators: NSObject, NSPopoverDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var statusIcon: MenuBarIcon?
    private var lastClose: TimeInterval = 0
    var completionPending: Bool { statusIcon?.completionPending == true }
    private let completionSound: @MainActor () -> Void

    init(store: Store, completionSound: @escaping @MainActor () -> Void = Indicators.playCompletionSound) {
        self.completionSound = completionSound
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSHostingController(rootView: LocalizedPanel(store: store, dismiss: { [weak self] in
            self?.popover.performClose(nil)
        }, contentSizeChanged: { [weak self] size in
            self?.resizeContent(to: size)
        }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        NotificationCenter.default.addObserver(self, selector: #selector(reanchorPopover),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(reanchorPopover),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func update(from store: Store) {
        if item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            status.button?.target = self
            status.button?.action = #selector(togglePopover)
            status.button?.imagePosition = .imageOnly
            item = status
            if let button = status.button {
                button.toolTip = nil
                statusIcon = MenuBarIcon(button: button, completionSound: completionSound)
            }
        }
        statusIcon?.update(transfers: store.transfers)
    }

    @objc private func togglePopover() {
        if completionPending { acknowledgeCompletion() }
        if popover.isShown {
            // Close before AppKit can re-anchor the panel while it animates out.
            popover.animates = false
            popover.close()
            popover.animates = true
        } else if ProcessInfo.processInfo.systemUptime - lastClose < 0.3 {
            // A transient popover closes on mouse down outside it, before this mouse-up action.
            // A click on the icon that just closed the panel must not open it again.
            return
        } else {
            showPanel()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = ProcessInfo.processInfo.systemUptime
    }

    func showPanel() {
        _ = NSRunningApplication.current.activate(options: [])
        guard let button = item?.button, button.window != nil else { return }
        if popover.isShown {
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            return
        }
        popover.appearance = NSApp.effectiveAppearance
        popover.animates = false
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        popover.animates = true
    }

    private func resizeContent(to size: CGSize) {
        let requested = NSSize(width: 384, height: ceil(size.height))
        guard requested.height > 0,
              abs(popover.contentSize.height - requested.height) > 0.5 ||
              abs(popover.contentSize.width - requested.width) > 0.5 else { return }
        popover.contentSize = requested
    }

    @objc private func reanchorPopover() {
        guard popover.isShown, let button = item?.button, button.window != nil else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private static let completionAudio = NSSound(named: NSSound.Name("Pop"))?.copy() as? NSSound

    private static func playCompletionSound() {
        guard let sound = completionAudio else { return }
        sound.volume = 0.25
        sound.play()
    }

    func acknowledgeCompletion() {
        statusIcon?.acknowledgeCompletion()
    }

    func showPopoverForSnapshot() -> NSWindow? {
        guard item?.button?.window != nil else { return nil }
        // Keep the test window open if the host changes focus while taking a snapshot.
        popover.behavior = .applicationDefined
        showPanel()
        return popover.contentViewController?.view.window
    }

    func checkPanelPlacement() throws {
        guard let button = item?.button, let statusWindow = button.window,
              let host = popover.contentViewController?.view, let window = host.window else {
            throw RillError("Панель не открыта.")
        }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let gap = anchor.minY - window.frame.maxY
        guard abs(gap) < 24, abs(host.bounds.width - 384) < 2,
              abs(host.bounds.height - popover.contentSize.height) < 2 else {
            throw RillError("Неверная геометрия панели: gap=\(gap), host=\(host.bounds), content=\(popover.contentSize)")
        }
        print("PASS panel anchor gap=\(gap), content=\(popover.contentSize)")
    }

    func reset() {
        popover.performClose(nil)
        statusIcon?.stop()
        statusIcon = nil
        if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    var statusIconIsVisible: Bool { item?.button?.image != nil }
    var statusIconIsTemplate: Bool { item?.button?.image?.isTemplate == true }
    var popoverHasTextFocus: Bool { popover.contentViewController?.view.window?.firstResponder is NSTextView }
    var statusButtonForSnapshot: NSStatusBarButton? { item?.button }
    var popoverIsShown: Bool { popover.isShown }
}



private struct LocalizedPanel: View {
    var store: Store
    var dismiss: () -> Void
    var contentSizeChanged: (CGSize) -> Void

    var body: some View {
        MenuPanel(store: store, dismiss: dismiss)
            .environment(\.locale, store.language.locale)
            .id(store.language)
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: contentSizeChanged)
    }
}
