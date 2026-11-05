import SwiftUI

/// Place above the persistent courier web surface. With no callback the
/// existing root notification modifier routes the order through AppModel.
@MainActor struct ExpressNotificationBanner: View {
    var onOpen: ((ExpressNotificationTarget) -> Void)? = nil
    @ObservedObject private var center = ExpressNotificationCenter.shared

    init(onOpen: ((ExpressNotificationTarget) -> Void)? = nil) { self.onOpen = onOpen }

    var body: some View {
        if let event = center.foregroundEvents.last {
            HStack(spacing: 12) {
                Button { center.openForegroundNotice(event, onOpen: onOpen) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: event.kind == .ready ? "bolt.circle.fill" : "shippingbox.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.kind.title).font(.subheadline.weight(.bold))
                            Text("Заказ " + event.parcel.label + (event.parcel.shopID.map { " · магазин \($0)" } ?? "")).font(.caption)
                            Text(center.foregroundEvents.count > 1 ? "Открыть · ещё событий: \(center.foregroundEvents.count - 1)" : "Нажми, чтобы открыть заказ").font(.caption2)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("notifications.banner.open")
                Button { center.dismissForegroundNotice(event.id) } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 36, height: 40)
                }.buttonStyle(.plain).accessibilityLabel("Скрыть уведомление").accessibilityIdentifier("notifications.banner.dismiss")
            }
            .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 10)
            .foregroundStyle(Palette.onAccent).background(Palette.accent)
            .accessibilityElement(children: .contain).accessibilityIdentifier("notifications.banner")
            .task(id: event.id) {
                #if DEBUG
                if center.isUIPreviewNotice(event) { return }
                #endif
                let remaining = max(0, min(15, 15 - Date().timeIntervalSince(event.observedAt)))
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
                center.dismissForegroundNotice(event.id)
            }
        }
    }
}
