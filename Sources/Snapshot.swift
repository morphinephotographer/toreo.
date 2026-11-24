import AppKit
import SwiftUI

@MainActor
enum Snapshot {
    static func checkStatusIcon(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = Store()
        let savedSpeedMode = UserDefaults.standard.object(forKey: "MenuBarShowsSpeeds")
        store.menuBarShowsSpeeds = false
        defer { UserDefaults.standard.set(savedSpeedMode, forKey: "MenuBarShowsSpeeds") }
        var completionCount = 0
        let indicators = Indicators(store: store, completionSound: { completionCount += 1 })
        defer { indicators.reset() }
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        func transfer(_ id: Int, complete: Bool = false, error: Int = 0, verifying: Bool = false) -> Transfer {
            Transfer(id: id, name: "Status icon test", hashString: "status-\(id)", downloadDir: "/tmp",
                     errorString: "", status: verifying ? 2 : (complete ? 6 : 4), error: error, eta: 0, queuePosition: 0,
                     percentDone: complete ? 1 : 0.5, metadataPercentComplete: 1, uploadRatio: 0,
                     recheckProgress: 0, sizeWhenDone: 100, leftUntilDone: complete ? 0 : 50,
                     rateDownload: complete ? 0 : 1000, rateUpload: 0, uploadedEver: 0, isFinished: complete)
        }

        indicators.update(from: store)
        try await Task.sleep(for: .milliseconds(350))
        guard let button = indicators.statusButtonForSnapshot, let initialImage = button.image,
              initialImage.isTemplate, button.window?.isVisible == true else {
            throw RillError("The native status item is not visible or its image is not a template.")
        }
        try await captureStatusButton(button, name: "01-idle", to: directory)
        guard button.image === initialImage else { throw RillError("Idle icon rendered again.") }

        store.transfers = [transfer(1), transfer(2), transfer(3), transfer(4)]
        indicators.update(from: store)
        try await Task.sleep(for: .milliseconds(330))
        let firstWave = button.image
        try await captureStatusButton(button, name: "02-downloading", to: directory)
        try await Task.sleep(for: .milliseconds(350))
        guard (button.image === firstWave) == reducedMotion else {
            throw RillError("The wave did not follow the system Reduce Motion setting.")
        }
        try await captureStatusButton(button, name: "03-downloading", to: directory)

        store.transfers = [transfer(1, complete: true), transfer(2, complete: true),
                           transfer(3), transfer(4, complete: true, error: 3)]
        indicators.update(from: store)
        indicators.update(from: store)
        guard indicators.completionPending, completionCount == 1 else {
            throw RillError("The first completion did not start exactly once.")
        }
        if !reducedMotion {
            try await Task.sleep(for: .milliseconds(280))
            try await captureStatusButton(button, name: "04-flatten", to: directory)
            try await Task.sleep(for: .milliseconds(140))
            try await captureStatusButton(button, name: "05-draw-check", to: directory)
        }
        try await Task.sleep(for: .milliseconds(350))
        try await captureStatusButton(button, name: "06-completed", to: directory)
        for _ in 0..<40 where completionCount < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard completionCount == 2, indicators.completionPending else {
            throw RillError("The simultaneous completion was not queued.")
        }
        for _ in 0..<40 where indicators.completionPending {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard completionCount == 2, !indicators.completionPending else {
            throw RillError("Completion did not clear or an error triggered a success animation.")
        }
        let resumedWave = button.image
        try await captureStatusButton(button, name: "07-resumed", to: directory)
        try await Task.sleep(for: .milliseconds(120))
        guard (button.image === resumedWave) == reducedMotion else {
            throw RillError("The wave did not return to the correct state.")
        }

        // A tracker warning (error 1) does not stop the wave or hide the completion check.
        store.transfers = [transfer(5, error: 1)]
        indicators.update(from: store)
        try await Task.sleep(for: .milliseconds(120))
        let warningWave = button.image
        try await Task.sleep(for: .milliseconds(120))
        guard (button.image === warningWave) == reducedMotion else {
            throw RillError("A tracker warning stopped the wave.")
        }
        store.transfers = [transfer(5, complete: true, error: 1)]
        indicators.update(from: store)
        guard indicators.completionPending, completionCount == 3 else {
            throw RillError("A tracker warning hid the completion check.")
        }
        indicators.acknowledgeCompletion()

        // One acknowledgement clears every queued completion.
        store.transfers = [transfer(6), transfer(7)]
        indicators.update(from: store)
        store.transfers = [transfer(6, complete: true), transfer(7, complete: true)]
        indicators.update(from: store)
        guard indicators.completionPending, completionCount == 4 else {
            throw RillError("Two completions did not start the queue.")
        }
        indicators.acknowledgeCompletion()
        try await Task.sleep(for: .seconds(3))
        guard !indicators.completionPending, completionCount == 4 else {
            throw RillError("Acknowledgement did not clear the whole completion queue.")
        }
        print("PASS tracker warnings keep the wave and the check; one acknowledgement clears the queue")

        store.transfers = [transfer(6, verifying: true)]
        indicators.update(from: store)
        store.transfers = [transfer(6, complete: true)]
        indicators.update(from: store)
        guard !indicators.completionPending, completionCount == 4 else {
            throw RillError("Verifying a finished transfer triggered a new completion.")
        }
        print("PASS rechecking a finished transfer produces no new check or sound")

        store.transfers = []
        indicators.update(from: store)
        try await captureStatusButton(button, name: "08-idle-again", to: directory)
        store.menuBarShowsSpeeds = true
        indicators.update(from: store)
        guard button.image == nil, button.attributedTitle.string.contains("↓"),
              button.attributedTitle.string.contains("↑"), Store().menuBarShowsSpeeds else {
            throw RillError("Menu bar speed mode did not apply or persist.")
        }
        try await captureStatusButton(button, name: "09-speeds-idle", to: directory)
        store.transfers = [transfer(15)]
        indicators.update(from: store)
        guard button.image == nil, !button.attributedTitle.string.isEmpty else {
            throw RillError("Speed mode was replaced by the animated icon.")
        }
        try await captureStatusButton(button, name: "10-speeds-downloading", to: directory)
        store.menuBarShowsSpeeds = false
        indicators.update(from: store)
        guard button.image?.isTemplate == true, button.title.isEmpty else {
            throw RillError("The wave icon did not return after speed mode.")
        }
        store.transfers = []
        indicators.update(from: store)
        print("PASS menu bar speed mode, persistence and switching back to waves")
        store.magnetPrompt = true
        button.performClick(nil)
        // Let the app activate and anchor the panel before the next click.
        try await Task.sleep(for: .milliseconds(350))
        guard indicators.popoverIsShown else { throw RillError("The status item did not open the popover.") }
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(400))
        guard !indicators.popoverIsShown else { throw RillError("A second click did not close the popover.") }
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(350))
        guard indicators.popoverIsShown else { throw RillError("The status item did not reopen the popover.") }
        guard indicators.popoverHasTextFocus else { throw RillError("The magnet field did not regain focus.") }
        button.performClick(nil)
        print("PASS magnet field regains focus when the popover reopens")
        print("PASS native status item, completion queue, errors, resume, idle and menu action (Reduce Motion: \(reducedMotion))")
    }

    private static func captureStatusButton(_ button: NSStatusBarButton, name: String, to directory: URL) async throws {
        guard let window = button.window, let mainDisplay = NSScreen.screens.first else {
            throw RillError("The status item window is missing.")
        }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil)).integral
        let region = [rect.minX, mainDisplay.frame.maxY - rect.maxY, rect.width, rect.height]
            .map { String(Int($0)) }.joined(separator: ",")
        let path = directory.appending(path: "\(name).png").path
        try await Task.detached {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-R", region, path]
            try capture.run()
            capture.waitUntilExit()
            guard capture.terminationStatus == 0 else { throw RillError("Menu bar screenshot failed.") }
        }.value
    }

    static func write(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = Store.shared
        let savedSpeedMode = UserDefaults.standard.object(forKey: "MenuBarShowsSpeeds")
        store.menuBarShowsSpeeds = false
        defer { UserDefaults.standard.set(savedSpeedMode, forKey: "MenuBarShowsSpeeds") }
        let savedLanguage = UserDefaults.standard.object(forKey: "AppLanguage")
        defer { UserDefaults.standard.set(savedLanguage, forKey: "AppLanguage") }
        store.language = .ru
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(300))
        store.ready = true
        store.preferences.downloadDir = "/Users/Example/Downloads"
        store.importFolder = "/Users/Example/Downloads"
        let example = Transfer(
            id: 1, name: "Open media collection", hashString: "sample", downloadDir: "/tmp", errorString: "",
            status: 4, error: 0, eta: 185, queuePosition: 0, percentDone: 0.64, metadataPercentComplete: 1,
            uploadRatio: 0.82, recheckProgress: 0, sizeWhenDone: 1_000_000_000, leftUntilDone: 360_000_000,
            rateDownload: 2_400_000, rateUpload: 320_000, uploadedEver: 80_000_000, isFinished: false)
        let files = [
            TorrentFile(name: "collection/preview.mov", length: 230_000_000),
            TorrentFile(name: "collection/sources.zip", length: 770_000_000)
        ]
        let samples: [Transfer] = (0..<8).map { index in
            Transfer(id: index + 1, name: index == 0 ? example.name : "Тестовая передача \(index + 1)",
                     hashString: "sample-\(index)", downloadDir: "/tmp", errorString: "",
                     status: index.isMultiple(of: 3) ? 4 : 0, error: 0, eta: 185, queuePosition: index,
                     percentDone: 0.64, metadataPercentComplete: 1, uploadRatio: 0.82, recheckProgress: 0,
                     sizeWhenDone: 1_000_000_000, leftUntilDone: 360_000_000, rateDownload: 2_400_000,
                     rateUpload: 320_000, uploadedEver: 80_000_000, isFinished: false)
        }
        for (name, mode) in [("light", ColorScheme.light), ("dark", .dark)] {
            let appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            let completed = Transfer(
                id: 99, name: "Архив исходных материалов", hashString: "completed", downloadDir: "/tmp", errorString: "",
                status: 6, error: 0, eta: 0, queuePosition: 0, percentDone: 1, metadataPercentComplete: 1,
                uploadRatio: 0, recheckProgress: 0, sizeWhenDone: 1_000_000_000, leftUntilDone: 0,
                rateDownload: 0, rateUpload: 0, uploadedEver: 0, isFinished: true)
            let indicators = Indicators(store: store, completionSound: {})
            defer { indicators.reset() }
            store.transfers = []
            indicators.update(from: store)
            try await Task.sleep(for: .milliseconds(180))
            guard let window = indicators.showPopoverForSnapshot() else {
                throw RillError("Не удалось открыть панель из строки меню.")
            }
            try await captureState(window, name: "menu-empty-\(name)", to: directory)
            try indicators.checkPanelPlacement()
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try click(in: window, at: NSPoint(x: 44, y: 36), fromTop: true)
                try await Task.sleep(for: .milliseconds(140))
                try captureWindow(window, name: "logo-bounce-\(name)", to: directory)
                try await Task.sleep(for: .seconds(1))
                try captureWindow(window, name: "logo-rest-\(name)", to: directory)
                try click(in: window, at: NSPoint(x: 44, y: 36), fromTop: true)
                try await Task.sleep(for: .milliseconds(325))
                try captureWindow(window, name: "logo-bend-\(name)", to: directory)
                try await Task.sleep(for: .milliseconds(700))
                try indicators.checkPanelPlacement()
            }
            var heights: [CGFloat] = []
            for count in [0, 1, 2, 3, 8, 1, 0] {
                store.transfers = Array(samples.prefix(count))
                indicators.update(from: store)
                try await Task.sleep(for: .milliseconds(700))
                try indicators.checkPanelPlacement()
                heights.append(window.frame.height)
                try captureWindow(window, name: "resize-\(count)-\(name)", to: directory)
            }
            guard heights[0] < heights[1], heights[1] < heights[2], heights[2] < heights[3],
                  abs(heights[3] - heights[4]) < 2,
                  abs(heights[0] - heights[6]) < 2, abs(heights[1] - heights[5]) < 2 else {
                throw RillError("Высота панели не адаптируется: \(heights)")
            }
            print("PASS grows and shrinks for 0/1/2/3/8 torrents: \(heights)")
            let width = window.frame.width
            let windowNumber = window.windowNumber
            store.transfers = [example, samples[1], completed]
            indicators.update(from: store)
            try await captureState(window, name: "menu-states-\(name)", to: directory)
            let listHeight = window.frame.height
            try click(in: window, at: NSPoint(x: 200, y: 98))
            try await Task.sleep(for: .milliseconds(120))
            guard store.armedRemoval == completed.hashString else { throw RillError("Карточка не показала корзину.") }
            print("PASS completed card arms the trash action")
            store.armedRemoval = completed.hashString
            try await captureState(window, name: "armed-\(name)", to: directory)
            store.armedRemoval = nil
            store.removalOptions = completed.hashString
            try await captureState(window, name: "delete-options-\(name)", to: directory)
            store.removalOptions = nil
            store.addChoicesPresented = true
            try await captureState(window, name: "add-options-\(name)", to: directory)
            store.addChoicesPresented = false
            try await Task.sleep(for: .milliseconds(300))
            try click(in: window, at: NSPoint(x: 292, y: 36))
            try await Task.sleep(for: .milliseconds(120))
            guard store.addChoicesPresented else { throw RillError("Кнопка + не откликнулась.") }
            print("PASS plus button responds to a real click")
            store.removalOptions = completed.hashString
            try clickBlank(in: window)
            try await Task.sleep(for: .milliseconds(120))
            guard !store.addChoicesPresented, store.removalOptions == nil else {
                throw RillError("Нажатие на свободное место не закрыло действия.")
            }
            print("PASS blank-space click dismisses add and removal options")
            try await checkAddButtons(in: window, store: store)
            store.unavailableFiles.insert(completed.hashString)
            try await captureState(window, name: "warning-\(name)", to: directory)
            store.expandedProblem = completed.hashString
            try await captureState(window, name: "warning-expanded-\(name)", to: directory)
            store.expandedProblem = nil
            store.unavailableFiles.remove(completed.hashString)
            store.transfers = samples
            try await captureState(window, name: "menu-many-\(name)", to: directory)
            guard abs(window.frame.height - listHeight) < 2 else {
                throw RillError("Панель выросла при добавлении строк.")
            }
            store.settingsPresented = true
            try await captureState(window, name: "settings-\(name)", to: directory)
            guard window.isVisible, window.windowNumber == windowNumber, abs(window.frame.width - width) < 2,
                  window.frame.height > 0 else {
                throw RillError("Размер панели: \(window.frame), ожидалось \(width); видно \(window.isVisible), окно \(window.windowNumber)/\(windowNumber).")
            }
            try indicators.checkPanelPlacement()
            try await checkDockIcon(in: window, store: store, appearance: name, to: directory)
            for language in AppLanguage.allCases {
                store.language = language
                try await captureState(window, name: "settings-\(language.rawValue)-\(name)", to: directory)
                try await captureState(window, name: "languages-\(language.rawValue)-\(name)", to: directory)
                guard abs(window.frame.width - width) < 2 else {
                    throw RillError("Выбор языков изменил размер панели.")
                }
                store.settingsPresented = false
                store.transfers = [example, samples[1], completed]
                store.removalOptions = completed.hashString
                try await captureState(window, name: "delete-\(language.rawValue)-\(name)", to: directory)
                store.dismissTransientOptions()
                store.settingsPresented = true
            }
            store.language = .ru
            store.settingsPresented = false
            let fixtureFolder = directory.appending(path: "search-fixtures", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: fixtureFolder.appending(path: "Open media notes.torrent"))
            store.preferences.downloadDir = fixtureFolder.path
            store.searchText = "Open media"
            try await Task.sleep(for: .milliseconds(400))
            try await captureState(window, name: "search-\(name)", to: directory)
            store.searchText = ""
            store.preferences.downloadDir = "/Users/Example/Downloads"
            store.selection = example.id
            store.inspector = true
            try await Task.sleep(for: .milliseconds(200))
            store.fileError = nil
            store.fileStates = files.enumerated().map { index, file in
                FileState(id: index, file: file, wanted: index == 0)
            }
            try await captureState(window, name: "files-\(name)", to: directory)
            try click(in: window, at: NSPoint(x: 340, y: window.frame.height - 52))
            try await Task.sleep(for: .milliseconds(200))
            guard !store.inspector else { throw RillError("Кнопка «Назад» не закрыла список файлов.") }
            store.selection = nil
            store.draft = ImportDraft(name: example.name, bytes: nil, magnet: nil,
                                      files: files, folder: "/Users/Example/Downloads")
            try await captureState(window, name: "import-\(name)", to: directory)
            store.draft = nil
            store.magnetPrompt = true
            try await captureState(window, name: "magnet-\(name)", to: directory)
            store.magnetPrompt = false
            try await Task.sleep(for: .milliseconds(700))
            try indicators.checkPanelPlacement()
            indicators.showPanel()
            try indicators.checkPanelPlacement()
            print("PASS single popover, fixed width, bounded list (\(name))")
        }
    }

    private static func clickBlank(in window: NSWindow) throws {
        try click(in: window, at: nil)
    }

    static func click(in window: NSWindow, at location: NSPoint?, fromTop: Bool = false) throws {
        func hostingView(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("NSHostingView") { return view }
            return view.subviews.lazy.compactMap { hostingView(in: $0) }.first
        }
        guard let root = window.contentView, let host = hostingView(in: root) else {
            throw RillError("Не найдена поверхность панели.")
        }
        var local = location ?? NSPoint(x: 6, y: host.bounds.midY)
        if location != nil, host.isFlipped != fromTop { local.y = host.bounds.height - local.y }
        let point = host.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
    }

    private static func checkDockIcon(in window: NSWindow, store: Store, appearance: String, to directory: URL) async throws {
        let initial = store.dockIcon
        let saved = UserDefaults.standard.object(forKey: DockIcon.preferenceKey)
        defer {
            store.setDockIcon(initial)
            UserDefaults.standard.set(saved, forKey: DockIcon.preferenceKey)
        }
        store.setDockIcon(.hidden)
        try await Task.sleep(for: .milliseconds(200))
        let visibleIcons = DockIcon.allCases.filter { $0 != .hidden }
        for icon in visibleIcons + [.hidden] {
            try click(in: window, at: NSPoint(x: 44, y: 82))
            try await Task.sleep(for: .milliseconds(300))
            let expectedPolicy: NSApplication.ActivationPolicy = icon == .hidden ? .accessory : .regular
            guard store.dockIcon == icon, Store().dockIcon == icon,
                  NSApp.activationPolicy() == expectedPolicy else {
                throw RillError("Dock icon choice did not apply or persist: \(icon.rawValue).")
            }
            if icon == .blue {
                try captureWindow(window, name: "dock-icon-\(appearance)", to: directory)
            }
        }
        print("PASS Dock icon choice cycles, applies and persists (\(appearance))")
    }

    private static func checkAddButtons(in window: NSWindow, store: Store) async throws {
        try await Task.sleep(for: .milliseconds(300))
        // Click the glass around the labels, near the top of the file button
        // and near the bottom of the magnet button.
        try click(in: window, at: NSPoint(x: 292, y: 36))
        try await Task.sleep(for: .milliseconds(300))
        try click(in: window, at: NSPoint(x: 104, y: 48))
        try await Task.sleep(for: .milliseconds(400))
        guard let picker = NSApp.windows.first(where: { $0 is NSOpenPanel && $0.isVisible }) as? NSOpenPanel else {
            throw RillError("Кнопка торрент-файла не открыла системный выбор файла.")
        }
        picker.cancel(nil)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))

        try click(in: window, at: NSPoint(x: 292, y: 36))
        try await Task.sleep(for: .milliseconds(300))
        try click(in: window, at: NSPoint(x: 220, y: 24))
        try await Task.sleep(for: .milliseconds(300))
        guard store.magnetPrompt, !store.addChoicesPresented, store.magnetText.isEmpty else {
            throw RillError("Кнопка magnet не открыла поле для ввода ссылки.")
        }
        try click(in: window, at: NSPoint(x: 340, y: 36))
        try await Task.sleep(for: .milliseconds(300))
        guard !store.magnetPrompt else { throw RillError("Поле magnet не закрылось.") }
        print("PASS file and magnet buttons respond away from their labels")
    }

    private static func captureState(_ window: NSWindow, name: String, to directory: URL) async throws {
        try await Task.sleep(for: .milliseconds(600))
        try captureWindow(window, name: name, to: directory)
    }

    private static func captureWindow(_ window: NSWindow, name: String, to directory: URL) throws {
        let file = directory.appending(path: "\(name).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus != 0, let view = window.contentView {
            print("FALLBACK \(name): view snapshot")
            try self.capture(view, name: name, to: directory)
        }
    }

    private static func capture(_ view: NSView, name: String, to directory: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RillError("Не удалось подготовить \(name).")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RillError("Не удалось сохранить \(name).")
        }
        try png.write(to: directory.appending(path: "\(name).png"))
    }
}
