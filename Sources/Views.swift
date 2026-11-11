import SwiftUI

struct FileInspector: View {
    var store: Store
    var goBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(tr("Файлы")) {
                MenuCircle("Назад", symbol: "chevron.left", action: goBack)
            }

            if let transfer = store.selected {
                Text(transfer.name).font(.callout.weight(.semibold)).lineLimit(2)
                if transfer.metadataPercentComplete < 1 {
                    Text(tr("Список появится после получения метаданных."))
                        .font(.callout).foregroundStyle(.secondary)
                } else if let error = store.fileError {
                    Text(error).font(.callout).foregroundStyle(.orange).lineLimit(2)
                } else {
                    TransferFileList(count: store.fileStates.count) {
                        ForEach(store.fileStates) { state in
                            TransferFileRow(file: state.file, isSelected: state.wanted) {
                                store.setWanted(transfer, index: state.id, wanted: !state.wanted)
                            }
                        }
                    }
                }
            } else {
                Text(tr("Выберите передачу")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: store.selected.map { "\($0.hashString)|\($0.metadataPercentComplete >= 1)" }) {
            store.fileStates = []
            store.fileError = nil
            guard let transfer = store.selected, transfer.metadataPercentComplete >= 1 else { return }
            await store.loadFiles(transfer)
        }
    }
}

struct ImportPanel: View {
    var store: Store
    @State var draft: ImportDraft
    var goBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(tr("Добавить передачу")) {
                MenuCircle("Назад", symbol: "chevron.left", action: goBack)
                    .disabled(store.busy)
            }

            Text(draft.name).font(.callout.weight(.semibold)).lineLimit(2)
            TransferFolderRow(title: "Папка загрузки", path: draft.folder) {
                if let folder = store.chooseFolder(draft.folder) { draft.folder = folder }
            }
            if draft.files.isEmpty {
                Text(tr("Список файлов появится, когда magnet получит метаданные."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TransferFileList(count: draft.files.count) {
                    ForEach(draft.files.indices, id: \.self) { index in
                        let isSelected = !draft.excluded.contains(index)
                        TransferFileRow(file: draft.files[index], isSelected: isSelected) {
                            if isSelected { draft.excluded.insert(index) }
                            else { draft.excluded.remove(index) }
                        }
                    }
                }
            }

            if let message = store.message {
                Text(message).font(.callout).foregroundStyle(.orange).lineLimit(2)
            }
            HStack(spacing: MenuGrid.gutter) {
                Toggle(tr("Начать сразу"), isOn: $draft.start)
                    .toggleStyle(.switch)
                    .font(.callout)
                    .padding(.horizontal, MenuGrid.gutter)
                Spacer(minLength: 0)
                MenuCircle("Добавить", symbol: "plus") {
                    store.message = nil
                    store.add(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.busy || (!draft.files.isEmpty && draft.excluded.count == draft.files.count))
            }
            .padding(.trailing, MenuGrid.gutter)
        }
    }
}

private struct TransferFileList<Rows: View>: View {
    let count: Int
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        if count > 3 {
            ScrollView { fileRows }
                .frame(height: 188)
        } else {
            fileRows
        }
    }

    private var fileRows: some View {
        LazyVStack(spacing: 4, content: rows)
    }
}

private struct TransferFileRow: View {
    let file: TorrentFile
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: MenuGrid.gutter) {
            MenuCircle(file.name, symbol: isSelected ? "checkmark" : "minus",
                       color: isSelected ? .primary : .secondary, localized: false, action: toggle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            TransferRowText(title: file.name, detail: bytes(file.length))
        }
        .transferCard()
    }
}

private struct TransferFolderRow: View {
    let title: String
    let path: String
    let select: () -> Void

    var body: some View {
        HStack(spacing: MenuGrid.gutter) {
            MenuCircle("Выбрать папку", symbol: "folder", action: select)
            TransferRowText(title: tr(title), detail: path)
        }
        .transferCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(tr(title)))
    }
}

private struct TransferRowText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PreferencesPanel: View {
    @Bindable var store: Store

    private var buildVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version, let build { return "\(version) (\(build))" }
        return version ?? build ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(tr("Настройки")) {
                MenuCircle(tr("Назад"), symbol: "chevron.left") {
                    store.settingsPresented = false
                    store.message = nil
                }
            }

            VStack(spacing: 4) {
                folderRow(tr("Папка загрузки"), path: store.preferences.downloadDir, select: store.setDownloadFolder)
                folderRow(tr("Автоимпорт .torrent"), path: store.importFolder, select: store.setImportFolder)
                choiceRow("Языки", value: store.language.title, symbol: "globe", action: store.cycleLanguage)
                choiceRow("Иконка Dock", value: store.dockIcon.title, symbol: "dock.rectangle", action: store.cycleDockIcon)
            }

            if let message = store.message ?? store.autoImportError {
                Text(message).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(verbatim: "Created by MORPHINE")
                if !buildVersion.isEmpty {
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                    Text(verbatim: buildVersion)
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    private func choiceRow(_ title: String, value: String, symbol: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: MenuGrid.gutter) {
            MenuCircle(title, symbol: symbol, action: action)
                .accessibilityValue(value)
            // Same layout as the folder rows: what the setting is, then its value.
            TransferRowText(title: tr(title), detail: value)
        }
        .transferCard()
    }

    private func folderRow(_ title: String, path: String, select: @escaping (String) -> Void) -> some View {
        TransferFolderRow(title: title, path: path) {
            if let folder = store.chooseFolder(path) { select(folder) }
        }
    }
}
