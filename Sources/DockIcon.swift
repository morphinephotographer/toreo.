import AppKit

enum DockIcon: String, CaseIterable {
    case hidden, twoWaves, twoWavesDark, monochromeLight, monochromeDark, status, waves, dark, clearLight, clearDark, blue, green

    static let preferenceKey = "DockIcon"

    static var saved: Self {
        guard let value = UserDefaults.standard.string(forKey: preferenceKey) else { return .hidden }
        return value == "circle" ? .waves : Self(rawValue: value) ?? .hidden
    }

    var title: String {
        switch self {
        case .hidden: tr("Скрыто из Dock")
        case .twoWaves: tr("Синий и мята")
        case .twoWavesDark: tr("Синий и мята · тёмная")
        case .monochromeLight: tr("Чёрно-белая · светлая")
        case .monochromeDark: tr("Чёрно-белая · тёмная")
        case .status: tr("Круг с волной")
        case .waves: tr("Светлая")
        case .dark: tr("Тёмная")
        case .clearLight: tr("Прозрачная светлая")
        case .clearDark: tr("Прозрачная тёмная")
        case .blue: tr("Голубая")
        case .green: tr("Зелёная")
        }
    }

    @MainActor
    func apply() -> Bool {
        var image: NSImage?
        if self != .hidden {
            guard let url = Bundle.main.url(forResource: "Dock-\(rawValue)", withExtension: "png"),
                  let alternate = NSImage(contentsOf: url) else { return false }
            image = alternate
        }
        let policy: NSApplication.ActivationPolicy = self == .hidden ? .accessory : .regular
        guard NSApp.activationPolicy() == policy || NSApp.setActivationPolicy(policy) else { return false }
        NSApp.applicationIconImage = image
        return true
    }
}
