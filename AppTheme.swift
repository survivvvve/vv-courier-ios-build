import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case codex, catppuccin, dracula, blue, green, yellow, pink, orange, purple, monochrome
    static let storageKey = "appearance.palette"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .catppuccin: return "Catppuccin"
        case .dracula: return "Dracula"
        case .blue: return "Синий"
        case .green: return "Зелёный"
        case .yellow: return "Жёлтый"
        case .pink: return "Розовый"
        case .orange: return "Оранжевый"
        case .purple: return "Фиолетовый"
        case .monochrome: return "Монохромный"
        }
    }
    private struct ColorVariants {
        let light: AppThemeColors
        let dark: AppThemeColors
    }
    // Immutable variants keep ShapeStyle resolution cheap while the environment
    // still chooses the current palette and appearance on every resolution.
    private static let cachedColors: [AppTheme: ColorVariants] = Dictionary(uniqueKeysWithValues: allCases.map { theme in
        (theme, ColorVariants(light: theme.makeColors(dark: false), dark: theme.makeColors(dark: true)))
    })
    func colors(dark: Bool) -> AppThemeColors {
        guard let variants = Self.cachedColors[self] else { return makeColors(dark: dark) }
        return dark ? variants.dark : variants.light
    }
    private func makeColors(dark: Bool) -> AppThemeColors {
        switch self {
        case .codex:
            return AppThemeColors(background: dark ? 0x181818 : 0xF7F7F8, surface: dark ? 0x242424 : 0xFFFFFF, field: dark ? 0x303030 : 0xEEEEF0, text: dark ? 0xFFFFFF : 0x0D0D0D, muted: dark ? 0xB0B0B4 : 0x62626A, accent: dark ? 0x339CFF : 0x0285FF)
        case .catppuccin:
            return AppThemeColors(background: dark ? 0x1E1E2E : 0xEFF1F5, surface: dark ? 0x292938 : 0xFFFFFF, field: dark ? 0x36364C : 0xE6E9EF, text: dark ? 0xCDD6F4 : 0x4C4F69, muted: dark ? 0xA6ADC8 : 0x6C6F85, accent: dark ? 0xCBA6F7 : 0x8839EF)
        case .dracula:
            return AppThemeColors(background: dark ? 0x282A36 : 0xFFF5FA, surface: dark ? 0x343746 : 0xFFFFFF, field: dark ? 0x44475A : 0xF4E5ED, text: dark ? 0xF8F8F2 : 0x382F3E, muted: dark ? 0xB5B8CB : 0x756776, accent: dark ? 0xFF79C6 : 0xB82B79)
        default:
            let accent: UInt32
            switch self {
            case .blue: accent = dark ? 0x74ADFF : 0x1769CE
            case .green: accent = dark ? 0x68D39D : 0x167146
            case .yellow: accent = dark ? 0xF4D067 : 0x916900
            case .pink: accent = dark ? 0xF69EC9 : 0xB43E79
            case .orange: accent = dark ? 0xF9AD78 : 0xB7541A
            case .purple: accent = dark ? 0xBDABFA : 0x7951C8
            default: accent = dark ? 0xF0F0F0 : 0x202020
            }
            return AppThemeColors(background: dark ? 0x18191C : 0xF5F6F8, surface: dark ? 0x24262B : 0xFFFFFF, field: dark ? 0x30343C : 0xE9EBEF, text: dark ? 0xF3F4F6 : 0x20232A, muted: dark ? 0xADB4C0 : 0x606875, accent: accent, tintSurfaces: self != .monochrome)
        }
    }
}

private struct CourierThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.codex
}

extension EnvironmentValues {
    var courierTheme: AppTheme {
        get { self[CourierThemeKey.self] }
        set { self[CourierThemeKey.self] = newValue }
    }
}

struct AppThemeColors {
    let background: UIColor
    let surface: UIColor
    let field: UIColor
    let text: UIColor
    let muted: UIColor
    let accent: UIColor
    let onAccent: UIColor
    let accentSurface: UIColor
    let line: UIColor

    init(background: UInt32, surface: UInt32, field: UInt32, text: UInt32, muted: UInt32, accent: UInt32, tintSurfaces: Bool = false) {
        self.accent = UIColor(themeHex: accent)
        self.background = UIColor(themeHex: background).blended(with: self.accent, fraction: tintSurfaces ? 0.055 : 0)
        self.surface = UIColor(themeHex: surface).blended(with: self.accent, fraction: tintSurfaces ? 0.035 : 0)
        self.field = UIColor(themeHex: field).blended(with: self.accent, fraction: tintSurfaces ? 0.08 : 0)
        self.text = UIColor(themeHex: text)
        self.muted = UIColor(themeHex: muted)
        self.onAccent = self.accent.relativeLuminance > 0.179 ? UIColor(themeHex: 0x101014) : .white
        self.accentSurface = self.surface.blended(with: self.accent, fraction: 0.14)
        self.line = self.text.withAlphaComponent(0.14)
    }
}

extension UIColor {
    convenience init(themeHex: UInt32) { self.init(red: CGFloat((themeHex >> 16) & 255) / 255, green: CGFloat((themeHex >> 8) & 255) / 255, blue: CGFloat(themeHex & 255) / 255, alpha: 1) }
    func blended(with color: UIColor, fraction: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var nr: CGFloat = 0, ng: CGFloat = 0, nb: CGFloat = 0, na: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a); color.getRed(&nr, green: &ng, blue: &nb, alpha: &na)
        return UIColor(red: r + (nr - r) * fraction, green: g + (ng - g) * fraction, blue: b + (nb - b) * fraction, alpha: a)
    }
    var relativeLuminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

struct AppearanceSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppTheme.storageKey) private var palette = AppTheme.codex.rawValue
    private var selected: AppTheme { AppTheme(rawValue: palette) ?? .codex }
    var body: some View {
        CourierPage("Внешний вид") {
            CourierCard("Режим") {
                Picker("Оформление", selection: $appearance) {
                    Text("Системное").tag(AppAppearance.system.rawValue)
                    Text("Светлое").tag(AppAppearance.light.rawValue)
                    Text("Тёмное").tag(AppAppearance.dark.rawValue)
                }.pickerStyle(.segmented).accessibilityIdentifier("appearance.picker")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Палитра").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(AppTheme.allCases) { theme in
                        Button { palette = theme.rawValue } label: { themePreview(theme) }.buttonStyle(.plain).accessibilityLabel(theme.title).accessibilityValue(selected == theme ? "Выбрана" : "").accessibilityIdentifier("appearance.palette." + theme.rawValue)
                    }
                }
            }
        }
    }
    private func themePreview(_ theme: AppTheme) -> some View {
        let colors = theme.colors(dark: colorScheme == .dark)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(uiColor: colors.accent)).frame(width: 14, height: 14)
                Text(theme.title).font(.subheadline.weight(.medium)).foregroundStyle(Color(uiColor: colors.text)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if selected == theme { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(uiColor: colors.accent)) }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: colors.muted)).frame(width: 26, height: 4)
                Spacer()
                RoundedRectangle(cornerRadius: 5).fill(Color(uiColor: colors.accent)).frame(width: 32, height: 17)
            }.padding(10).background(Color(uiColor: colors.surface), in: RoundedRectangle(cornerRadius: 7))
        }.padding(12).background(Color(uiColor: colors.background), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(uiColor: selected == theme ? colors.accent : colors.line), lineWidth: selected == theme ? 2 : 1))
    }
}
