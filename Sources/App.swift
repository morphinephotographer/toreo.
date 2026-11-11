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
    private var terminationReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = Store.shared
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
        if terminationReady { return .terminateNow }
        if !shuttingDown {
            shuttingDown = true
            let store = Store.shared
            store.indicators?.reset()
            store.indicators = nil
            Task {
                await store.close()
                terminationReady = true
                sender.terminate(nil)
            }
        }
        // Return to the event loop so the async shutdown can finish before exiting.
        return .terminateCancel
    }
}
