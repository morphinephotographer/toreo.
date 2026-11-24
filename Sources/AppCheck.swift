import AppKit

@MainActor
enum AppCheck {
    static func run(torrent: URL) async throws {
        guard ProcessInfo.processInfo.environment["RILL_STORE"] != nil else {
            throw RillError("Для проверки нужен отдельный RILL_STORE.")
        }
        let options = Store()
        options.addChoicesPresented = true
        options.removalOptions = "test"
        try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(10))
        guard options.addChoicesPresented, options.removalOptions != nil else {
            throw RillError("Панель закрылась раньше пяти секунд.")
        }
        for _ in 0..<70 where options.addChoicesPresented || options.removalOptions != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !options.addChoicesPresented, options.removalOptions == nil else {
            throw RillError("Панели действий не закрылись через пять секунд.")
        }
        options.addChoicesPresented = true
        options.removalOptions = "test"
        options.dismissTransientOptions()
        guard !options.addChoicesPresented, options.removalOptions == nil else {
            throw RillError("Не удалось закрыть действия.")
        }
        guard tr("Настройки", language: .en) == "settings.",
              tr("Настройки", language: .ru) == "Настройки",
              tr("Настройки", language: .uk) == "Налаштування" else {
            throw RillError("Ошибка локализации.")
        }
        print("PASS five-second option timeout, dismissal and three UI languages")
        let store = Store.shared
        for _ in 0..<40 where !store.ready && store.message == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard store.ready else { throw RillError(store.message ?? "Сессия не открылась.") }
        if ProcessInfo.processInfo.environment["RILL_RESTORE_CHECK"] == "1" {
            guard store.transfers.count == 1, store.transfers.first?.paused == true else {
                throw RillError("Выключение не сохранило передачу и её паузу.")
            }
            print("PASS power button saved the session and pause state")
        }
        guard try await store.engine.transferLimitsAreDisabled() else {
            throw RillError("В движке остались ограничения скорости или очереди.")
        }
        print("PASS global speed, queue, scheduled and seeding limits are disabled")
        if ProcessInfo.processInfo.environment["RILL_RESTORE_CHECK"] != "1" {
            let folder = torrent.deletingLastPathComponent()
            let invalid = folder.appending(path: "invalid.torrent")
            try Data("invalid".utf8).write(to: invalid)
            store.preferences.downloadDir = folder.path
            store.enqueue([invalid, torrent])
            for _ in 0..<50 where store.transfers.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let imported = store.transfers.first, !imported.paused,
                  store.draft == nil, store.message != nil else {
                throw RillError("Пакетный импорт потерял ошибку или не запустил исправный торрент.")
            }
            try await store.engine.change(imported.hashString, command: "torrent_remove")
            print("PASS batch import starts the valid torrent and keeps the invalid-file error")
        }
        let draft = try await store.engine.inspect(torrent, folder: torrent.deletingLastPathComponent().path)
        var paused = draft
        paused.start = false
        let hash = try await store.engine.add(paused)
        let actual = try await store.engine.list()
        let actualFiles = try await store.engine.files(hash)
        guard actual.count == 1, actual.first?.paused == true, actualFiles.count == 1 else {
            throw RillError("Проверка импорта или списка файлов не прошла.")
        }
        print("PASS app starts, imports a paused torrent and reads its files")
        if let transfer = actual.first, let file = actualFiles.first, !file.file.name.contains("/") {
            let parent = torrent.deletingLastPathComponent()
            let link = parent.appending(path: file.file.name)
            let sentinel = parent.appending(path: "untouched-\(UUID().uuidString)")
            try Data("untouched".utf8).write(to: sentinel)
            defer { try? FileManager.default.removeItem(at: sentinel) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
            defer { try? FileManager.default.removeItem(at: link) }
            var rejected = false
            do { try await store.engine.trashFiles(transfer) }
            catch { rejected = true }
            guard rejected, FileManager.default.fileExists(atPath: sentinel.path) else {
                throw RillError("Проверка безопасного удаления не прошла.")
            }
            print("PASS trash refuses a symbolic link")
        }
        await store.setDownloadsPaused(false)
        guard try await waitForPauseState(false, engine: store.engine) else {
            throw RillError("Не удалось продолжить загрузки из панели.")
        }
        await store.setDownloadsPaused(true)
        guard try await waitForPauseState(true, engine: store.engine) else {
            throw RillError("Не удалось приостановить загрузки из панели.")
        }
        print("PASS batch resume and pause change the engine state")
        let source = torrent.deletingLastPathComponent()
        let payload = source.appending(path: "fixture.bin")
        try Data("abc".utf8).write(to: payload)
        try await store.engine.change(hash, command: "torrent_verify")
        for _ in 0..<40 {
            if try await store.engine.list().first?.complete == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let completed = try await store.engine.list().first, completed.complete,
              try await store.engine.completedFiles(completed) == [payload.resolvingSymlinksInPath()] else {
            throw RillError("Не найден файл завершённой передачи.")
        }
        print("PASS completed transfer resolves the real downloaded file")
        let nested = source.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appending(path: "SEARCH-FIXTURE.TORRENT")
        try Data("test".utf8).write(to: nestedFile)
        try Data("excluded".utf8).write(to: nested.appending(path: "SEARCH-FIXTURE.txt"))
        let matches = await DownloadSearch.files(matching: "search-fixture", in: source.path)
        guard matches == [nestedFile], await DownloadSearch.files(matching: "", in: source.path).isEmpty else {
            throw RillError("Поиск по папке загрузок работает неверно.")
        }
        guard ProblemAction.resolve(code: 2, message: "Tracker timeout", missingFile: false) == .retry,
              ProblemAction.resolve(code: 3, message: "Permission denied", missingFile: false) == .chooseFolder,
              ProblemAction.resolve(code: 0, message: "", missingFile: true) == .verify,
              AppLanguage.allCases.allSatisfy({
                  ProblemAction.resolve(code: 0, message: tr("Скачанный файл недоступен", language: $0),
                                        missingFile: true) == .verify
              }),
              ProblemAction.resolve(code: 3, message: "No data found! Ensure your drives are connected or use \"Set Location\".",
                                    missingFile: false) == .chooseFolder else {
            throw RillError("Действие при ошибке выбрано неверно.")
        }
        print("PASS recursive file search and contextual recovery actions")
        try await store.engine.setDownloadFolder(nested.path)
        guard try await store.engine.settings().downloadDir == nested.path else {
            throw RillError("Папка загрузок не сохранилась.")
        }
        try await store.engine.setDownloadFolder(source.path)

        try await store.engine.change(hash, command: "torrent_remove")
        guard FileManager.default.fileExists(atPath: payload.path) else {
            throw RillError("Удаление записи затронуло скачанный файл.")
        }

        // A folder seen for the first time only records the files already in it.
        let old = source.appending(path: "old", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        var existing = Data("d4:infod6:lengthi3e4:name12:baseline.bin12:piece lengthi16384e6:pieces20:".utf8)
        existing.append(Data(repeating: 7, count: 20))
        existing.append(Data("ee".utf8))
        try existing.write(to: old.appending(path: "existing.torrent"))
        let baseline = await store.engine.importTorrents(from: old.path, to: source.path)
        guard !baseline.imported, baseline.error == nil, try await store.engine.list().isEmpty else {
            throw RillError(baseline.error ?? "Первый просмотр папки импортировал уже лежавшие файлы.")
        }

        let watch = source.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        _ = await store.engine.importTorrents(from: watch.path, to: source.path)
        try Data("broken".utf8).write(to: watch.appending(path: "broken.torrent"))
        let broken = await store.engine.importTorrents(from: watch.path, to: source.path)
        let brokenAgain = await store.engine.importTorrents(from: watch.path, to: source.path)
        guard broken.error != nil, brokenAgain.error == nil else {
            throw RillError("Ошибка повреждённого файла не показана или повторяется.")
        }
        try FileManager.default.removeItem(at: watch.appending(path: "broken.torrent"))
        try FileManager.default.copyItem(at: torrent, to: watch.appending(path: "incoming.torrent"))
        let scan = await store.engine.importTorrents(from: watch.path, to: source.path)
        guard scan.imported, try await store.engine.list().count == 1 else {
            throw RillError(scan.error ?? "Автоимпорт не добавил новый торрент.")
        }
        try await store.engine.change(hash, command: "torrent_remove")
        await store.close()
        let reopened = Engine()
        try await reopened.start()
        let rescan = await reopened.importTorrents(from: watch.path, to: source.path)
        guard !rescan.imported, rescan.error == nil, try await reopened.list().isEmpty else {
            throw RillError("Автоимпорт повторно добавил удалённый торрент.")
        }
        await reopened.close()
        print("PASS auto-import skips files already in a new folder, reports a broken file once, imports new files and remembers them after restart")

        let sample = Transfer(
            id: 1, name: "Indicator check", hashString: "sample", downloadDir: "/tmp", errorString: "",
            status: 4, error: 0, eta: 60, queuePosition: 0, percentDone: 0.64, metadataPercentComplete: 1,
            uploadRatio: 0, recheckProgress: 0, sizeWhenDone: 100, leftUntilDone: 36,
            rateDownload: 20_000, rateUpload: 0, uploadedEver: 0, isFinished: false)
        let display = Store()
        var soundCount = 0
        let indicators = Indicators(store: display, completionSound: { soundCount += 1 })
        display.transfers = [sample]
        indicators.update(from: display)
        guard indicators.statusIconIsVisible,
              let progress = display.downloadProgress, abs(progress - 0.64) < 0.001 else {
            throw RillError("Индикатор строки меню не показал прогресс.")
        }
        let completedData = try JSONSerialization.data(withJSONObject: [
            "id": sample.id, "name": sample.name, "hashString": sample.hashString,
            "downloadDir": sample.downloadDir, "errorString": "", "status": 6, "error": 0,
            "eta": 0, "queuePosition": 0, "percentDone": 1.0, "metadataPercentComplete": 1.0,
            "uploadRatio": 0.0, "recheckProgress": 0.0, "sizeWhenDone": 100, "leftUntilDone": 0,
            "rateDownload": 0, "rateUpload": 0, "uploadedEver": 0, "isFinished": true
        ])
        display.transfers = [try JSONDecoder().decode(Transfer.self, from: completedData)]
        indicators.update(from: display)
        indicators.update(from: display)
        guard indicators.completionPending, soundCount == 1, indicators.statusIconIsTemplate else {
            throw RillError("Уведомление о завершении не сработало или повторилось.")
        }
        indicators.acknowledgeCompletion()
        guard !indicators.completionPending else { throw RillError("Уведомление не сбросилось.") }
        print("PASS completion icon, one sound and acknowledgement")
        display.transfers = []
        indicators.update(from: display)
        guard display.downloadProgress == nil else { throw RillError("Прогресс не сбросился.") }
        guard indicators.statusIconIsTemplate else { throw RillError("Значок не адаптируется к строке меню.") }
        indicators.reset()
        print("PASS menu bar uses an adaptive template icon")
    }

    static func checkQuit(torrent: URL) async throws {
        guard ProcessInfo.processInfo.environment["RILL_STORE"] != nil else {
            throw RillError("Для проверки нужен отдельный RILL_STORE.")
        }
        let store = Store.shared
        for _ in 0..<80 where !store.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard store.ready else { throw RillError("Сессия не запустилась.") }
        var draft = try await store.engine.inspect(torrent, folder: torrent.deletingLastPathComponent().path)
        draft.start = false
        _ = try await store.engine.add(draft)
        store.transfers = try await store.engine.list()
        guard let window = store.indicators?.showPopoverForSnapshot() else {
            throw RillError("Не найдена панель для проверки выключения.")
        }
        try await Task.sleep(for: .milliseconds(700))
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: NSApp, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                guard !window.isVisible, store.indicators == nil else {
                    fputs("Панель и значок должны исчезнуть при выходе.\n", stderr)
                    exit(1)
                }
                print("PASS quit closes the panel and removes the status item")
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try Snapshot.click(in: window, at: NSPoint(x: 340, y: 36))
        try await Task.sleep(for: .seconds(25))
        throw RillError("Кнопка выключения не завершила приложение.")
    }

    private static func waitForPauseState(_ paused: Bool, engine: Engine) async throws -> Bool {
        for _ in 0..<30 {
            if try await engine.list().first?.paused == paused { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
