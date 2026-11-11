import SwiftUI

struct FileInspector: View {
    var store: Store
    var body: some View {
        Group {
            if let transfer = store.selected {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Файлы")).font(.headline)
                    Text(transfer.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Divider()
                    if let error = store.fileError {
                        Text(error).foregroundStyle(.orange).font(.callout)
                    } else if transfer.metadataPercentComplete < 1 {
                        Text(tr("Список появится после получения метаданных.")).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(store.fileStates) { state in
                                    Toggle(isOn: Binding(
                                        get: { state.wanted },
                                        set: { store.setWanted(transfer, index: state.id, wanted: $0) }
                                    )) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(state.file.name).lineLimit(1)
                                            Text(bytes(state.file.length)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 180)
            } else {
                ContentUnavailableView(tr("Выберите передачу"), systemImage: "doc")
            }
        }
        .task(id: store.selected.map { "\($0.hashString)|\($0.metadataPercentComplete >= 1)" }) {
            store.fileStates = []
            store.fileError = nil
            await store.loadFiles(store.selected)
        }
    }
}

struct ImportPanel: View {
    var store: Store
    @State var draft: ImportDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Добавить передачу")).font(.title2.bold())
            Text(draft.name).lineLimit(2)
            HStack(spacing: 8) {
                Label(draft.folder, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(tr("Выбрать…")) { if let path = store.chooseFolder(draft.folder) { draft.folder = path } }
            }
            .foregroundStyle(.secondary)
            if draft.files.isEmpty {
                Text(tr("Список файлов появится, когда magnet получит метаданные."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(draft.files.indices, id: \.self) { index in
                            Toggle(isOn: Binding(
                                get: { !draft.excluded.contains(index) },
                                set: { wanted in
                                    if wanted { draft.excluded.remove(index) }
                                    else { draft.excluded.insert(index) }
                                }
                            )) {
                                HStack {
                                    Text(draft.files[index].name).lineLimit(1)
                                    Spacer()
                                    Text(bytes(draft.files[index].length)).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.padding(8)
                }
                .frame(height: min(200, CGFloat(draft.files.count) * 24 + 16))
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
            Toggle(tr("Начать сразу"), isOn: $draft.start).toggleStyle(.checkbox)
            if let message = store.message { Text(message).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(tr("Отмена"), role: .cancel) {
                    store.draft = nil
                    store.message = nil
                    store.nextImport()
                }
                .disabled(store.busy)
                Button(tr("Добавить")) { store.message = nil; store.add(draft) }
                    .buttonStyle(ClearGlassButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.busy || (!draft.files.isEmpty && draft.excluded.count == draft.files.count))
            }
        }
        .buttonStyle(ClearGlassButtonStyle())
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
                HStack(spacing: 8) {
                    MenuCircle(tr("Языки"), symbol: "globe") {
                        store.cycleLanguage()
                    }
                    Text(store.language.title)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transferCard()

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

    private func folderRow(_ title: String, path: String, select: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            MenuCircle(tr("Выбрать папку"), symbol: "folder") {
                if let folder = store.chooseFolder(path) { select(folder) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr(title)).font(.system(size: 14, weight: .semibold))
                Text(path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transferCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(tr(title)))
    }
}
