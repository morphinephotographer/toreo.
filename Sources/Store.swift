import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class Store {
    static let shared = Store()

    var transfers: [Transfer] = []
    var preferences = Preferences.initial
    var selection: Int?
    var draft: ImportDraft?
    var magnetPrompt = false
    var magnetText = ""
    var message: String?
    var ready = false
    var busy = false
    var settingsPresented = false
    var searchText = ""
    var inspector = false
    var fileStates: [FileState] = []
    var fileError: String?
    var removalOptions: String? { didSet { scheduleOptionDismissal() } }
    var expandedProblem: String?
    var addChoicesPresented = false { didSet { scheduleOptionDismissal() } }
    var armedRemoval: String? { didSet { scheduleOptionDismissal() } }
    var language = AppLanguage.current {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "AppLanguage")
            if NSApp.mainMenu != nil { ToreoDelegate.installMainMenu() }
            updateIndicators()
        }
    }
    private(set) var dockIcon = DockIcon.saved
    var importFolder = UserDefaults.standard.string(forKey: "AutoImportFolder") ?? Store.defaultImportFolder
    var unavailableFiles: Set<String> = []
    var autoImportError: String?

    static var defaultImportFolder: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads").path
    }

    @ObservationIgnored let engine = Engine()
    @ObservationIgnored var indicators: Indicators?
    @ObservationIgnored private var pending: [URL] = []
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var importPoller: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var previewing = false
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var folderUpdate: Task<Void, Never>?
    @ObservationIgnored private var optionDismissal: Task<Void, Never>?
    @ObservationIgnored private var deleting: Set<String> = []

    func cycleLanguage() {
        let languages = AppLanguage.allCases
        guard let index = languages.firstIndex(of: language) else { return }
        language = languages[(index + 1) % languages.count]
    }

    func cycleDockIcon() {
        let icons = DockIcon.allCases
        guard let index = icons.firstIndex(of: dockIcon) else { return }
        setDockIcon(icons[(index + 1) % icons.count])
    }

    func setDockIcon(_ icon: DockIcon) {
        guard icon.apply() else {
            message = tr("Не удалось изменить иконку Dock.")
            return
        }
        dockIcon = icon
        UserDefaults.standard.set(icon.rawValue, forKey: DockIcon.preferenceKey)
    }

    func dismissTransientOptions() {
        optionDismissal?.cancel()
        removalOptions = nil
        armedRemoval = nil
        addChoicesPresented = false
    }

    private func scheduleOptionDismissal() {
        optionDismissal?.cancel()
        guard removalOptions != nil || armedRemoval != nil || addChoicesPresented else { return }
        optionDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5), tolerance: .milliseconds(10)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dismissTransientOptions()
        }
    }

    var selected: Transfer? { transfers.first { $0.id == selection } }
    var down: Int64 { transfers.reduce(0) { $0 + $1.rateDownload } }
    var up: Int64 { transfers.reduce(0) { $0 + $1.rateUpload } }
    var active: [Transfer] { transfers.filter { !$0.paused || $0.error != 0 } }
    var downloadProgress: Double? {
        let items = transfers.filter(\.downloading)
        let size = items.reduce(0.0) { $0 + Double($1.sizeWhenDone) }
        guard size > 0 else { return nil }
        let remaining = items.reduce(0.0) { $0 + Double($1.leftUntilDone) }
        return min(1, max(0, 1 - remaining / size))
    }

    func start() {
        guard !starting, !ready, !closing else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                try await engine.start()
                if ProcessInfo.processInfo.environment["RILL_STORE"] == nil,
                   let path = UserDefaults.standard.string(forKey: "DownloadFolder") {
                    try await engine.setDownloadFolder(path)
                }
                preferences = try await engine.settings()
                transfers = try await engine.list()
                guard !closing else { return }
                ready = true
                updateIndicators()
                nextImport()
                startAutoImport()
                poller = Task { [weak store = self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(650))
                        guard let store, !Task.isCancelled else { return }
                        await store.refresh()
                    }
                }
            } catch {
                guard !closing else { return }
                message = error.localizedDescription
            }
        }
    }

    func close() async {
        await beginClose().value
    }

    func beginClose() -> Task<Void, Never> {
        closing = true
        ready = false
        poller?.cancel()
        importPoller?.cancel()
        let pendingFolderUpdate = folderUpdate
        return Task.detached { [engine] in
            await pendingFolderUpdate?.value
            await engine.close()
        }
    }

    private func refresh() async {
        do {
            let updated = try await engine.list()
            guard !closing else { return }
            if transfers != updated { transfers = updated }
            updateIndicators()
        } catch {
            // A failed sample keeps the last known status. Commands report their own errors.
        }
    }

    private func startAutoImport() {
        // Test sessions must never import from the user's Downloads folder.
        guard ProcessInfo.processInfo.environment["RILL_STORE"] == nil else { return }
        importPoller = Task { [weak self] in
            while let store = self, !Task.isCancelled {
                let source = store.importFolder
                let result = await store.engine.importTorrents(from: source, to: store.preferences.downloadDir)
                if !Task.isCancelled, !store.closing, store.importFolder == source {
                    // Keep a dismissed message hidden until a new problem appears.
                    if let error = result.error { store.autoImportError = error }
                    if result.imported { await store.refresh() }
                }
                try? await Task.sleep(for: .seconds(5), tolerance: .milliseconds(10))
            }
        }
    }

    func updateIndicators() { indicators?.update(from: self) }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = tr("Добавить раздачу")
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] result in
            guard let self else { return }
            self.indicators?.showPanel()
            if result == .OK { self.enqueue(panel.urls) }
        }
    }

    /// ⌥ + «Торрент-файл»: choose the folder and files before the download starts.
    func chooseFileWithOptions() {
        let panel = NSOpenPanel()
        panel.title = tr("Добавить раздачу")
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard let self else { return }
            self.indicators?.showPanel()
            guard result == .OK, let url = panel.url else { return }
            Task {
                do {
                    let draft = try await self.engine.inspect(url, folder: self.preferences.downloadDir)
                    self.message = nil
                    self.draft = draft
                } catch {
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func chooseFolder(_ initial: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = tr("Папка загрузки")
        panel.prompt = tr("Выбрать")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: initial, isDirectory: true)
        let result = panel.runModal()
        indicators?.showPanel()
        return result == .OK ? panel.url?.path : nil
    }

    func enqueue(_ urls: [URL]) {
        guard !closing, !urls.isEmpty else { return }
        if !previewing, pending.isEmpty { message = nil }
        pending.append(contentsOf: urls)
        nextImport()
    }

    func nextImport() {
        guard ready, !busy, !previewing, draft == nil, !pending.isEmpty else { return }
        previewing = true
        let url = pending.removeFirst()
        Task {
            defer {
                previewing = false
                if draft == nil { nextImport() }
            }
            do {
                let hash = try await engine.importTorrent(url, to: preferences.downloadDir)
                transfers = try await engine.list()
                selection = transfers.first { $0.hashString == hash }?.id
                updateIndicators()
            } catch { message = error.localizedDescription }
            indicators?.showPanel()
        }
    }

    func add(_ current: ImportDraft) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let hash = try await engine.add(current)
                transfers = try await engine.list()
                selection = transfers.first { $0.hashString == hash }?.id
                draft = nil
                updateIndicators()
            } catch { message = error.localizedDescription }
            busy = false
            nextImport()
        }
    }

    func command(_ torrent: Transfer, _ method: String) {
        Task {
            do {
                try await engine.change(torrent.hashString, command: method)
                await refresh()
            } catch { message = error.localizedDescription }
        }
    }

    func toggle(_ torrent: Transfer) {
        command(torrent, torrent.paused ? "torrent_start" : "torrent_stop")
    }

    func setDownloadsPaused(_ paused: Bool) async {
        do {
            let current = try await engine.list()
            let hashes = current.filter {
                !$0.complete && (paused ? !$0.paused : $0.paused)
            }.map(\.hashString)
            try await engine.change(hashes, command: paused ? "torrent_stop" : "torrent_start")
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func trash(_ torrent: Transfer) {
        guard deleting.insert(torrent.hashString).inserted else { return }
        Task {
            defer { deleting.remove(torrent.hashString) }
            do {
                try await engine.change(torrent.hashString, command: "torrent_stop")
                for _ in 0..<20 {
                    if try await engine.list().first(where: { $0.hashString == torrent.hashString })?.paused == true { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try await engine.trashFiles(torrent)
                await refresh()
            } catch {
                message = error.localizedDescription
                await refresh()
            }
        }
    }

    func loadFiles(_ torrent: Transfer?) async {
        guard let torrent else { fileStates = []; fileError = nil; return }
        do {
            let files = try await engine.files(torrent.hashString)
            if !Task.isCancelled, selected?.hashString == torrent.hashString {
                fileStates = files
                fileError = nil
            }
        } catch {
            if !Task.isCancelled { fileError = error.localizedDescription }
        }
    }

    func setWanted(_ torrent: Transfer, index: Int, wanted: Bool) {
        Task {
            do {
                try await engine.setWanted(torrent.hashString, index: index, wanted: wanted)
                await loadFiles(torrent)
                await refresh()
            } catch { message = error.localizedDescription }
        }
    }

    func reveal(_ torrent: Transfer) {
        Task {
            let base = URL(fileURLWithPath: torrent.downloadDir, isDirectory: true)
            let files = (try? await engine.files(torrent.hashString)) ?? []
            if let first = files.first(where: \.wanted) ?? files.first,
               let top = first.file.name.split(separator: "/").first,
               top != ".", top != ".." {
                let target = base.appending(path: String(top))
                if FileManager.default.fileExists(atPath: target.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                    return
                }
            }
            if !NSWorkspace.shared.open(base) { message = tr("Папка загрузки недоступна.") }
        }
    }

    func openCompleted(_ torrent: Transfer) {
        Task {
            do {
                let urls = try await engine.completedFiles(torrent)
                if urls.count == 1, let file = urls.first {
                    guard NSWorkspace.shared.open(file) else { throw RillError(tr("Не удалось открыть скачанный файл.")) }
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                unavailableFiles.remove(torrent.hashString)
            } catch {
                unavailableFiles.insert(torrent.hashString)
                message = error.localizedDescription
            }
        }
    }

    func setDownloadFolder(_ path: String) {
        let previous = folderUpdate
        folderUpdate = Task.detached { [engine, weak self] in
            await previous?.value
            let errorMessage: String?
            do {
                try await engine.setDownloadFolder(path)
                UserDefaults.standard.set(path, forKey: "DownloadFolder")
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            RunLoop.main.perform { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.closing else { return }
                    if errorMessage == nil { self.preferences.downloadDir = path }
                    self.message = errorMessage
                }
            }
        }
    }

    func setImportFolder(_ path: String) {
        UserDefaults.standard.set(path, forKey: "AutoImportFolder")
        importFolder = path
        autoImportError = nil
    }

    func relocate(_ torrent: Transfer) {
        guard let folder = chooseFolder(torrent.downloadDir) else { return }
        Task {
            do {
                try await engine.relocate(torrent, to: folder)
                unavailableFiles.remove(torrent.hashString)
                await refresh()
            } catch { message = error.localizedDescription }
        }
    }

}

func bytes(_ value: Int64) -> String {
    value.formatted(.byteCount(style: .file).locale(AppLanguage.current.locale))
}

func rate(_ value: Int64) -> String {
    let unit = value >= 1_000_000 ? tr("МБ") : tr("КБ")
    let divisor = value >= 1_000_000 ? 1_000_000.0 : 1_000.0
    let amount = (Double(value) / divisor).formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.current.locale))
    return "\(amount) \(unit)/\(tr("с"))"
}

func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.current.locale))
}
