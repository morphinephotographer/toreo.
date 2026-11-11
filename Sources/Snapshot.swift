import AppKit
import SwiftUI

@MainActor
enum Snapshot {
    static func write(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = Store.shared
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

    static func click(in window: NSWindow, at location: NSPoint?) throws {
        func hostingView(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("NSHostingView") { return view }
            return view.subviews.lazy.compactMap { hostingView(in: $0) }.first
        }
        guard let root = window.contentView, let host = hostingView(in: root) else {
            throw RillError("Не найдена поверхность панели.")
        }
        var local = location ?? NSPoint(x: 6, y: host.bounds.midY)
        if location != nil, host.isFlipped { local.y = host.bounds.height - local.y }
        let point = host.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
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
