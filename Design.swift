import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "Как на iPhone"; case .light: return "Светлая"; case .dark: return "Тёмная" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

/// Resolve semantic colors from the current environment, even when a cached
/// card/button does not need to rebuild its body after a palette selection.
struct PaletteColor: ShapeStyle {
    enum Role: Sendable { case background, surface, field, text, line, muted, accent, onAccent, accentSurface, warning, success, danger }
    let role: Role
    private var alpha = 1.0

    init(_ role: Role) { self.role = role }

    func resolve(in environment: EnvironmentValues) -> Color {
        let dark = environment.colorScheme == .dark
        let colors = environment.courierTheme.colors(dark: dark)
        let value: UIColor
        switch role {
        case .background: value = colors.background
        case .surface: value = colors.surface
        case .field: value = colors.field
        case .text: value = colors.text
        case .line: value = colors.line
        case .muted: value = colors.muted
        case .accent: value = colors.accent
        case .onAccent: value = colors.onAccent
        case .accentSurface: value = colors.accentSurface
        case .warning: value = UIColor(themeHex: dark ? 0xF1BE64 : 0x925600)
        case .success: value = UIColor(themeHex: dark ? 0x6DD6A2 : 0x177447)
        case .danger: value = .systemRed
        }
        return Color(uiColor: value).opacity(alpha)
    }

    func opacity(_ value: Double) -> PaletteColor {
        var result = self; result.alpha *= value; return result
    }

}

enum Palette {
    static let background = PaletteColor(.background)
    static let surface = PaletteColor(.surface)
    static let field = PaletteColor(.field)
    static let text = PaletteColor(.text)
    static let line = PaletteColor(.line)
    static let muted = PaletteColor(.muted)
    static let accent = PaletteColor(.accent)
    static let onAccent = PaletteColor(.onAccent)
    static let accentSurface = PaletteColor(.accentSurface)
    static let warning = PaletteColor(.warning)
    static let success = PaletteColor(.success)
    static let danger = PaletteColor(.danger)
}

// Kept as a source-compatible background for shared screens and report exports.
struct CourierBackground: View {
    var artwork = 1
    var body: some View { Rectangle().fill(Palette.background).ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false) }
}

struct CourierCard<Content: View>: View {
    var title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.subheadline.weight(.semibold)) }
            content
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 0.5))
    }
}

struct CourierPage<Content: View>: View {
    let title: String
    var subtitle: String?
    var artwork: Int
    var showsIncomingTasks: Bool
    let content: Content
    init(_ title: String, subtitle: String? = nil, artwork: Int = 1, showsIncomingTasks: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.artwork = artwork; self.showsIncomingTasks = showsIncomingTasks; self.content = content()
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading) }
                content
            }.padding(.horizontal, 16).padding(.vertical, 12).padding(.bottom, 12)
        }.scrollDismissesKeyboard(.interactively).background(Palette.background)
            .safeAreaInset(edge: .top, spacing: 0) { if showsIncomingTasks { ColdControlNotice() } }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("Готово") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
    }
}

struct CourierButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).padding(.vertical, 12).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(primary ? Palette.onAccent : Palette.text)
            .background(primary ? Palette.accent : Palette.field, in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CourierMetric: View {
    let title: String
    let value: String
    var symbol: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) { if let symbol { Image(systemName: symbol) }; Text(title) }.font(.caption).foregroundStyle(Palette.muted)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CourierEmpty: View {
    let title: String
    let message: String
    var symbol = "tray"
    var body: some View {
        CourierCard {
            HStack(spacing: 10) { Image(systemName: symbol).font(.title3).foregroundStyle(Palette.muted); Text(title).font(.subheadline.weight(.semibold)) }
            Text(message).font(.subheadline).foregroundStyle(Palette.muted)
        }
    }
}

struct CourierErrorCard: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        CourierCard {
            Label("Не удалось обновить", systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.warning)
            Text(message).font(.subheadline).foregroundStyle(Palette.muted)
            if let retry { Button("Повторить", action: retry).buttonStyle(CourierButtonStyle()) }
        }
    }
}

struct CourierMenuRow: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Palette.accent).frame(width: 24)
            Text(title).font(.subheadline).foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Palette.muted)
        }.frame(minHeight: 40).contentShape(Rectangle())
    }
}

// Configure once; callers only format values and cannot mutate this instance.
private let rubleFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.numberStyle = .currency
    formatter.currencySymbol = "₽"
    return formatter
}()

func money(_ value: Double) -> String {
    rubleFormatter.string(from: NSNumber(value: value)) ?? "—"
}
