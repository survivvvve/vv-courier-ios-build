import SwiftUI
import UIKit

struct CourierBrandMark: View {
    var body: some View {
        Image("VVBrandMark").resizable().scaledToFit().frame(width: 44, height: 24)
            .accessibilityHidden(true)
    }
}

private struct CourierBrandHeader: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar { ToolbarItem(placement: .topBarLeading) { CourierBrandMark() } }
    }
}

extension View {
    func courierBrandHeader() -> some View { modifier(CourierBrandHeader()) }
}

@MainActor enum CustomerVkusVillApp {
    // The official website links here. Its AASA lists /psD7/* for
    // LF777ZZ54Y.com.vkusvill; the fallback resolves to App Store id1399903464.
    static let universalLink = URL(string: "https://app.vkusvill.ru/psD7/ay1eugyh")!
    static let appStore = URL(string: "https://apps.apple.com/ru/app/id1399903464")!
    static func open() {
        UIApplication.shared.open(universalLink, options: [.universalLinksOnly: true]) { opened in
            if !opened { UIApplication.shared.open(appStore) }
        }
    }
}
