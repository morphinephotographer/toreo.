import CoreText
import SwiftUI

struct MenuPanel: View {
    @Bindable var store: Store
    var dismiss: () -> Void
    @State private var changingDownloads = false
    @State private var foundFiles: [URL] = []
    @FocusState private var magnetFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canPause: Bool {
        store.transfers.contains { !$0.complete && !$0.paused }
    }

    private var canResume: Bool {
        store.transfers.contains { !$0.complete && $0.paused }
    }

    private var visibleTransfers: [Transfer] {
        // Prefer active work, then attention and paused states, then completed items.
        let active = store.transfers.filter { !$0.paused && !$0.complete && !$0.hasLocalError }
        let other = store.transfers.filter { $0.hasLocalError || ($0.paused && !$0.complete) || (!$0.paused && $0.complete) }
        let completed = store.transfers.filter { $0.paused && $0.complete && !$0.hasLocalError }
        let transfers = active + other + completed
        return search.isEmpty ? transfers : transfers.filter { $0.name.localizedStandardContains(search) }
    }

    private var search: String { store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var resultCount: Int { visibleTransfers.count + foundFiles.count }

    var body: some View {
        Group {
            if let draft = store.draft {
                ImportPanel(store: store, draft: draft, goBack: goBack).id(draft.id)
            } else if store.settingsPresented {
                PreferencesPanel(store: store)
                    .transition(.opacity)
            } else if store.inspector {
                FileInspector(store: store, goBack: goBack)
            } else {
                transferList
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(width: 384)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { store.dismissTransientOptions() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let supported = urls.filter { $0.scheme?.lowercased() == "magnet" || ($0.isFileURL && $0.pathExtension.lowercased() == "torrent") }
            guard !supported.isEmpty else { return false }
            store.enqueue(supported)
            return true
        }
        .focusEffectDisabled()
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
            // The popover keeps its views between openings, so the field does not appear again.
            if store.magnetPrompt { magnetFocused = true }
        }
        .onExitCommand(perform: goBack)
        .task(id: SearchRequest(query: search, folder: store.preferences.downloadDir)) {
            foundFiles = []
            let request = SearchRequest(query: search, folder: store.preferences.downloadDir)
            guard !request.query.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let files = await DownloadSearch.files(matching: request.query, in: request.folder)
            guard !Task.isCancelled else { return }
            foundFiles = files
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.settingsPresented)
    }

    private var transferList: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let message = store.message ?? store.autoImportError {
                HStack {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer(minLength: 0)
                    if !store.ready { Button(tr("Повторить")) { store.message = nil; store.start() } }
                    Button(tr("Закрыть сообщение"), systemImage: "xmark") { store.message = nil; store.autoImportError = nil }
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(ClearGlassButtonStyle())
            }
            if resultCount == 0 {
                Text(store.ready ? (search.isEmpty ? tr("Нет передач") : tr("Нет совпадений")) : tr("Открываем передачи…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else if resultCount > 3 {
                ScrollView { rows }
                    .frame(height: 188)
            } else {
                rows
            }
            actions
        }
    }

    private struct SearchRequest: Equatable {
        let query: String
        let folder: String
    }

    private var rows: some View {
        LazyVStack(spacing: 4) {
            ForEach(visibleTransfers) { transfer in
                MenuTransferRow(transfer: transfer, store: store, dismiss: dismiss)
            }
            ForEach(foundFiles, id: \.self) { file in
                Button {
                    store.enqueue([file])
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc").frame(width: MenuGrid.control)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.lastPathComponent).font(.system(size: 14, weight: .semibold))
                            Text(file.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "plus").frame(width: MenuGrid.control)
                    }
                    .transferCard()
                    .contentShape(Rectangle())
                }
                .buttonStyle(ClearGlassButtonStyle(bordered: false))

            }
        }
    }

    private func goBack() {
        if store.draft != nil {
            guard !store.busy else { return }
            store.draft = nil
            store.message = nil
            store.nextImport()
        } else if store.settingsPresented {
            store.settingsPresented = false
            store.message = nil
        } else if store.inspector {
            store.inspector = false
        } else if store.magnetPrompt || store.addChoicesPresented {
            store.magnetPrompt = false
            store.addChoicesPresented = false
        } else if store.removalOptions != nil || store.expandedProblem != nil || store.armedRemoval != nil {
            store.removalOptions = nil
            store.expandedProblem = nil
            store.armedRemoval = nil
        } else {
            dismiss()
        }
    }

    private var magnetURL: URL? {
        let text = store.magnetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "magnet" else { return nil }
        return url
    }

    private var header: some View {
        PanelHeader(title: { ToreoWordmark() }) {
            let pause = canPause
            MenuCircle(pause ? tr("Приостановить все загрузки") : tr("Продолжить все загрузки"),
                       symbol: pause ? "pause.fill" : "play.fill") {
                changingDownloads = true
                Task {
                    await store.setDownloadsPaused(pause)
                    changingDownloads = false
                }
            }
            .focusEffectDisabled()
            .disabled(!store.ready || changingDownloads || (!pause && !canResume))
            MenuCircle(tr("Настройки"), symbol: "gearshape") {
                store.settingsPresented = true
            }
        }
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: MenuGrid.gutter) {
                if store.magnetPrompt {
                    TextField("magnet:?xt=…", text: Bindable(store).magnetText)
                        .textFieldStyle(.plain)
                        .focused($magnetFocused)
                        .padding(.horizontal, 12)
                        .frame(height: MenuGrid.control)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
                        .task {
                            // Wait one turn so the field is in the key window before taking focus.
                            await Task.yield()
                            magnetFocused = true
                        }
                        .onSubmit(submitMagnet)
                    MenuCircle(tr("Добавить magnet"), symbol: "arrow.right", action: submitMagnet)
                        .disabled(magnetURL == nil)
                    MenuCircle(tr("Закрыть"), symbol: "xmark", action: goBack)
                } else if store.addChoicesPresented {
                    InlineChoices {
                        Button(tr("Торрент-файл")) {
                            store.dismissTransientOptions()
                            if NSEvent.modifierFlags.contains(.option) {
                                store.chooseFileWithOptions()
                            } else {
                                store.chooseFile()
                            }
                        }
                        .keyboardShortcut("o")
                        .help(tr("С ⌥ — выбрать папку и файлы перед загрузкой"))
                        Button(tr("Magnet-ссылка")) {
                            store.dismissTransientOptions()
                            store.magnetText = ""
                            store.magnetPrompt = true
                        }
                        .keyboardShortcut("v", modifiers: [.command, .shift])
                    }
                    .padding(.leading, MenuGrid.control + 2 * MenuGrid.gutter)
                    MenuCircle(tr("Закрыть"), symbol: "xmark", action: store.dismissTransientOptions)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField(tr("Поиск"), text: $store.searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: MenuGrid.control)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
                    .contextMenu {
                        Button(tr("Открыть папку загрузки"), systemImage: "folder") {
                            let folder = URL(fileURLWithPath: store.preferences.downloadDir, isDirectory: true)
                            if NSWorkspace.shared.open(folder) { dismiss() }
                            else { store.message = tr("Не удалось открыть папку загрузки.") }
                        }
                    }
                    MenuCircle(tr("Добавить торрент"), symbol: "plus") {
                        store.dismissTransientOptions()
                        store.addChoicesPresented = true
                    }
                    MenuCircle(tr("Выйти из toreo."), symbol: "power") { NSApp.terminate(nil) }
                }
            }
            .buttonStyle(ClearGlassButtonStyle())
            .frame(height: MenuGrid.control)
            .padding(.trailing, MenuGrid.gutter)
            .animation(reduceMotion ? nil : MenuGrid.choiceAnimation, value: store.addChoicesPresented)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.magnetPrompt)
        }
    }

    private func submitMagnet() {
        guard let url = magnetURL else { return }
        store.magnetPrompt = false
        store.enqueue([url])
    }
}

private struct MenuTransferRow: View {
    let transfer: Transfer
    var store: Store
    var dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    private var showingTrash: Bool { store.armedRemoval == transfer.hashString || showingOptions }
    private var showingOptions: Bool { store.removalOptions == transfer.hashString }
    private var showingProblem: Bool { store.expandedProblem == transfer.hashString }

    private var problem: String? {
        // Tracker messages stay in the tooltip and the context menu: the transfer itself keeps working.
        if transfer.hasLocalError { return transfer.errorString.isEmpty ? tr("Ошибка передачи") : transfer.errorString }
        if store.unavailableFiles.contains(transfer.hashString) { return tr("Скачанный файл недоступен") }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            MenuCircle(tr("Показать в Finder"), symbol: "folder") {
                dismiss()
                store.reveal(transfer)
            }
            if problem != nil && showingProblem && !showingOptions {
                problemActions
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else if showingOptions {
                InlineChoices {
                    Button(tr("Удалить торрент")) {
                        store.dismissTransientOptions()
                        store.command(transfer, "torrent_remove")
                    }
                    Button(tr("Удалить с файлами"), role: .destructive) {
                        store.dismissTransientOptions()
                        store.trash(transfer)
                    }
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
                    .disabled(transfer.metadataPercentComplete < 1)
                }
            } else {
                Button {
                    if transfer.complete || problem != nil {
                        let revealChoices = !showingTrash
                        store.dismissTransientOptions()
                        if revealChoices {
                            store.armedRemoval = transfer.hashString
                            store.removalOptions = transfer.hashString
                        }
                        store.expandedProblem = nil
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(transfer.name)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 4)
                            if transfer.metadataPercentComplete >= 1 && !transfer.complete {
                                Text(percent(transfer.percentDone))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                        Text(metadata)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(trackerMessage ?? "")

                        GeometryReader { proxy in
                            Capsule().fill(.primary.opacity(0.14))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.primary.opacity(transfer.paused && !transfer.complete ? 0.50 : 0.85))
                                        .frame(width: proxy.size.width * min(1, max(0, transfer.percentDone)))
                                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: transfer.percentDone)
                                }
                        }
                        .frame(height: 4)
                        .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ClearGlassButtonStyle(bordered: false))
                // A card of a running transfer has no tap action, so VoiceOver should not call it a button.
                .accessibilityRemoveTraits(transfer.complete || problem != nil ? AccessibilityTraits() : .isButton)
                .transition(.opacity)
            }
            if showingOptions {
                MenuCircle(tr("Закрыть"), symbol: "xmark", action: store.dismissTransientOptions)
            } else if showingTrash {
                MenuCircle(tr("Удаление торрента"), symbol: "trash", color: .red) {
                    store.removalOptions = transfer.hashString
                }
            } else if problem != nil {
                MenuCircle(tr("Проблема с передачей"), symbol: "exclamationmark.triangle",
                           color: .orange) {
                    store.expandedProblem = showingProblem ? nil : transfer.hashString
                }
            } else if transfer.complete {
                MenuCircle(tr("Открыть скачанные файлы"), symbol: "checkmark", color: .green) {
                    store.openCompleted(transfer)
                }
            } else {
                MenuCircle(transfer.paused ? tr("Продолжить") : tr("Приостановить"),
                           symbol: transfer.paused ? "play.fill" : "pause.fill") {
                    store.toggle(transfer)
                }
                .focusEffectDisabled()
            }
        }
        .transferCard(hovered: hovered)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
        .animation(reduceMotion ? nil : MenuGrid.choiceAnimation, value: showingOptions)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showingProblem)
        .contextMenu {
            Button(tr("Показать файлы"), action: openDetails)
            if transfer.complete && !transfer.paused {
                Button(tr("Приостановить раздачу")) { store.toggle(transfer) }
            } else if transfer.complete {
                Button(tr("Продолжить раздачу")) { store.toggle(transfer) }
            }
            Button(tr("Проверить файлы")) { store.command(transfer, "torrent_verify") }
            if let trackerMessage {
                let title: String = tr("Повторить запрос к трекеру") + " — " + trackerMessage
                Button(title) {
                    store.command(transfer, "torrent_reannounce")
                }
            }
            Divider()
            Button(tr("Удалить торрент…"), role: .destructive) {
                store.armedRemoval = transfer.hashString
                store.removalOptions = transfer.hashString
            }
            Button(tr("Удалить с файлами"), role: .destructive) { store.trash(transfer) }
                .disabled(transfer.metadataPercentComplete < 1)
        }
    }

    private var trackerMessage: String? {
        guard transfer.hasTrackerIssue, !transfer.errorString.isEmpty else { return nil }
        return transfer.errorString
    }

    private var problemActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(problem ?? tr("Ошибка передачи"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(problemAction.title) {
                switch problemAction {
                case .chooseFolder: store.relocate(transfer)
                case .verify:
                    store.unavailableFiles.remove(transfer.hashString)
                    store.command(transfer, "torrent_verify")
                case .retry:
                    store.command(transfer, transfer.paused ? "torrent_start" : "torrent_reannounce")
                case .details: openDetails()
                }
            }
            .font(.caption)
            .buttonStyle(ClearGlassButtonStyle())
        }
    }

    private var problemAction: ProblemAction {
        ProblemAction.resolve(code: transfer.error, message: problem ?? "",
                              missingFile: store.unavailableFiles.contains(transfer.hashString))
    }

    private func openDetails() {
        store.selection = transfer.id
        store.inspector = true
    }

    private var metadata: String {
        if let problem { return problem }
        if transfer.status == 6 { return "\(tr("Раздача")) · \(rate(transfer.rateUpload))" }
        if transfer.complete { return "\(tr("Завершено")) · \(bytes(transfer.sizeWhenDone))" }
        if transfer.paused { return tr("Приостановлено") }
        if !transfer.downloading { return transfer.state }
        let completed = max(0, transfer.sizeWhenDone - transfer.leftUntilDone)
        return "\(bytes(completed)) \(tr("из")) \(bytes(transfer.sizeWhenDone)) · \(rate(transfer.rateDownload))"
    }
}

enum MenuGrid {
    static let gutter: CGFloat = 8
    static let control: CGFloat = 40
    static let titleSize: CGFloat = 24
    static let choiceWidth: CGFloat = 112
    static let choiceAnimation = Animation.easeInOut(duration: 0.2)
}

private struct InlineChoices<Choices: View>: View {
    @ViewBuilder var choices: () -> Choices

    var body: some View {
        HStack(spacing: MenuGrid.gutter, content: choices)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .buttonStyle(ClearGlassButtonStyle(inlineChoice: true))
            .frame(maxWidth: .infinity)
            .transition(.opacity)
    }
}

struct MenuCircle: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void

    /// Pass `localized: false` for user data such as file names.
    init(_ title: String, symbol: String, color: Color = .primary, localized: Bool = true,
         action: @escaping () -> Void) {
        self.title = localized ? tr(title) : title
        self.symbol = symbol
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
                .frame(width: MenuGrid.control, height: MenuGrid.control)
        }
        .buttonStyle(ClearGlassButtonStyle(compact: true))
        .focusEffectDisabled()

    }
}

struct ClearGlassButtonStyle: ButtonStyle {
    var compact = false
    var horizontalInset: CGFloat = 12
    var verticalInset: CGFloat = 6
    var bordered = true
    var inlineChoice = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
        if inlineChoice {
            label
                .padding(.horizontal, 6)
                .frame(width: MenuGrid.choiceWidth, height: MenuGrid.control)
                .contentShape(Capsule())
                .glassEffect(.clear.interactive(), in: .capsule)
        } else if bordered {
            label
                .padding(.horizontal, compact ? 0 : horizontalInset)
                .padding(.vertical, compact ? 0 : verticalInset)
                .contentShape(Capsule())
                .glassEffect(.clear.interactive(), in: .capsule)
        } else {
            label
        }
    }
}


enum ProblemAction {
    case retry, verify, chooseFolder, details

    var title: String {
        switch self {
        case .retry: tr("Повторить")
        case .verify: tr("Проверить файл")
        case .chooseFolder: tr("Выбрать папку")
        case .details: tr("Подробнее")
        }
    }

    /// Transmission is built without NLS, so its messages are always English.
    /// Toreo's own localized texts are passed as flags and never parsed.
    static func resolve(code: Int, message: String, missingFile: Bool) -> Self {
        if missingFile { return .verify }
        let text = message.lowercased()
        if ["set location", "no data found", "permission", "read-only", "no space", "not a directory"]
            .contains(where: text.contains) {
            return .chooseFolder
        }
        if ["not found", "no such file", "missing"].contains(where: text.contains) {
            return .verify
        }
        if code == 1 || code == 2 { return .retry }
        return .details
    }
}

struct PanelHeader<Title: View, Controls: View>: View {
    let title: Title
    @ViewBuilder var controls: () -> Controls

    init(@ViewBuilder title: () -> Title, @ViewBuilder controls: @escaping () -> Controls) {
        self.title = title()
        self.controls = controls
    }

    var body: some View {
        HStack(spacing: 8) {
            title.font(.system(size: MenuGrid.titleSize, weight: .bold))
            Spacer(minLength: 8)
            controls()
        }
        .frame(height: MenuGrid.control)
        .padding(.trailing, MenuGrid.gutter)
    }
}

extension PanelHeader where Title == Text {
    init(_ title: String, @ViewBuilder controls: @escaping () -> Controls) {
        self.init(title: { Text(tr(title)) }, controls: controls)
    }
}

private struct ToreoWordmark: View {
    private struct DotPose {
        var towardO: CGFloat = 0
        var lift: CGFloat = 0
        var squash: CGFloat = 1
    }

    private static let dotTravel: CGSize = {
        let font = NSFont.systemFont(ofSize: MenuGrid.titleSize, weight: .bold)
        let letter = NSAttributedString(string: "o", attributes: [.font: font])
        let period = NSAttributedString(string: ".", attributes: [.font: font])
        let oInk = CTLineGetImageBounds(CTLineCreateWithAttributedString(letter), nil)
        let dotInk = CTLineGetImageBounds(CTLineCreateWithAttributedString(period), nil)
        return CGSize(width: oInk.midX - letter.size().width - dotInk.midX, height: oInk.maxY)
    }()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        let travel = Self.dotTravel
        if reduceMotion {
            Text("toreo.")
        } else {
            Button {
                bounce += 1
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("toreo")
                    Text(".")
                        .keyframeAnimator(initialValue: DotPose(), trigger: bounce) { dot, pose in
                            dot.scaleEffect(x: pose.squash, y: 1 / pose.squash, anchor: .bottom)
                                .offset(x: pose.towardO * travel.width, y: -pose.lift) // grid: ok animation only
                        } keyframes: { _ in
                            // Teleo's one-second trajectory: hop onto the o, return, and bounce once.
                            KeyframeTrack(\.towardO) {
                                MoveKeyframe(0)
                                LinearKeyframe(0, duration: 0.06)
                                LinearKeyframe(1, duration: 0.21)
                                LinearKeyframe(1, duration: 0.20)
                                LinearKeyframe(0, duration: 0.31)
                                LinearKeyframe(0, duration: 0.22)
                            }
                            KeyframeTrack(\.lift) {
                                MoveKeyframe(0)
                                LinearKeyframe(0, duration: 0.06)
                                CubicKeyframe(travel.height + 0.22 * MenuGrid.titleSize, duration: 0.11, endVelocity: 0)
                                CubicKeyframe(travel.height, duration: 0.10, startVelocity: 0, endVelocity: 0)
                                LinearKeyframe(travel.height, duration: 0.20)
                                CubicKeyframe(travel.height + 0.42 * MenuGrid.titleSize, duration: 0.15, endVelocity: 0)
                                CubicKeyframe(0, duration: 0.16, startVelocity: 0, endVelocity: 0)
                                CubicKeyframe(0.12 * MenuGrid.titleSize, duration: 0.09, endVelocity: 0)
                                CubicKeyframe(0, duration: 0.07, startVelocity: 0, endVelocity: 0)
                                LinearKeyframe(0, duration: 0.06)
                            }
                            KeyframeTrack(\.squash) {
                                MoveKeyframe(1)
                                CubicKeyframe(1.2, duration: 0.06)
                                CubicKeyframe(0.92, duration: 0.06)
                                CubicKeyframe(1, duration: 0.15)
                                CubicKeyframe(1.15, duration: 0.12)
                                CubicKeyframe(0.9, duration: 0.08)
                                CubicKeyframe(1, duration: 0.09)
                                LinearKeyframe(1, duration: 0.20)
                                CubicKeyframe(1.25, duration: 0.02)
                                CubicKeyframe(1, duration: 0.06)
                                LinearKeyframe(1, duration: 0.08)
                                CubicKeyframe(1.1, duration: 0.02)
                                CubicKeyframe(1, duration: 0.06)
                            }
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

extension View {
    func transferCard(hovered: Bool = false) -> some View {
        self.padding(.horizontal, MenuGrid.gutter)
            .frame(height: 60)
            .background(.primary.opacity(hovered ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 26))
    }
}
