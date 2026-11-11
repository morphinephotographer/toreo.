import AppKit

@main
@MainActor
enum ToreoApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = ToreoDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class ToreoDelegate: NSObject, NSApplicationDelegate {
    private var shuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = Store.shared
        Self.installMainMenu()
        if let target = ProcessInfo.processInfo.environment["RILL_STATUS_SNAPSHOT_DIR"] {
            Task {
                do { try await Snapshot.checkStatusIcon(to: URL(fileURLWithPath: target)); exit(0) }
                catch { fputs("\(error)\n", stderr); exit(1) }
            }
            return
        }
        if let target = ProcessInfo.processInfo.environment["RILL_SNAPSHOT_DIR"] {
            Task { @MainActor in
                do { try await Snapshot.write(to: URL(fileURLWithPath: target, isDirectory: true)); exit(0) }
                catch { fputs("\(error)\n", stderr); exit(1) }
            }
            return
        }
        _ = store.dockIcon.apply()
        store.indicators = Indicators(store: store)
        store.updateIndicators()
        store.start()
        if let file = ProcessInfo.processInfo.environment["RILL_QUIT_CHECK"] {
            Task {
                do { try await AppCheck.checkQuit(torrent: URL(fileURLWithPath: file)) }
                catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.environment["RILL_APP_CHECK"] == nil {
            Task {
                // Activate after Launch Services has finished registering this launch.
                try? await Task.sleep(for: .milliseconds(200))
                store.indicators?.showPanel()
            }
        }
        if let file = ProcessInfo.processInfo.environment["RILL_APP_CHECK"] {
            Task {
                do { try await AppCheck.run(torrent: URL(fileURLWithPath: file)); exit(0) }
                catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Store.shared.enqueue(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Store.shared.indicators?.showPanel()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // .terminateLater keeps a logout, restart or shutdown going while the session is saved.
        // .terminateCancel would cancel the whole logout.
        guard !shuttingDown else { return .terminateLater }
        shuttingDown = true
        let store = Store.shared
        store.indicators?.reset()
        store.indicators = nil
        let closing = store.beginClose()
        Task.detached {
            await closing.value
            // AppKit waits in a modal run loop after .terminateLater.
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }

    /// Without a main menu AppKit has no key equivalents for text editing,
    /// so ⌘V, ⌘C, ⌘A and ⌘Z would not work in the magnet and search fields.
    static func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Выйти из toreo."),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Правка"))
        edit.addItem(withTitle: tr("Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: tr("Повторить действие"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
