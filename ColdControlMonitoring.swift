import SwiftUI
import Combine
import UIKit

/// One monitor for the signed-in identity. Visible pages share its assignment;
/// each page can open the task above its own sheet, including order details.
@MainActor struct ColdControlMonitoring: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var control = ColdControlCoordinator()
    @State private var observedIdentity = ""
    @State private var lastSignalAt = Date.distantPast
    private var monitorKey: String { model.identity + ":\(scenePhase == .active):\(model.sessionExpired)" }

    func body(content: Content) -> some View {
        content.environmentObject(control)
            .task(id: monitorKey) { await monitor() }
            .onReceive(NotificationCenter.default.publisher(for: CourierAPI.coldControlNotification).receive(on: RunLoop.main)) { event in
                guard !model.demo, let session = model.session,
                      event.userInfo?["courierID"] as? String == session.courierID,
                      event.userInfo?["sessionFingerprint"] as? String == model.api.sessionFingerprint,
                      let required = event.userInfo?["required"] as? Bool,
                      let startedAt = event.userInfo?["startedAt"] as? Date else { return }
                observe(required, at: startedAt)
            }
    }

    private func observe(_ required: Bool, at date: Date) {
        guard date >= lastSignalAt else { return }
        lastSignalAt = date
        let incoming = required && !control.required
        control.observeRequired(required)
        if !required, let id = model.session?.courierID { ColdControlPendingStore.mark(courierID: id, pending: false) }
        if incoming && !model.demo && scenePhase == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            UIAccessibility.post(notification: .announcement, argument: "ВВ назначил фотоконтроль хладоэлементов")
        }
    }

    @MainActor private func monitor() async {
        let identity = model.identity
        if observedIdentity != identity { observedIdentity = identity; lastSignalAt = .distantPast; control.reset() }
        if model.demo {
            if ProcessInfo.processInfo.arguments.contains("--demo-cold-control") && control.generation == 0 { control.observeRequired(true) }
            return
        }
        guard scenePhase == .active, model.session != nil, !model.sessionExpired else { return }
        while !Task.isCancelled {
            let startedAt = Date()
            do {
                let required = try await model.api.coldControlRequired()
                guard !Task.isCancelled, model.identity == identity else { return }
                if let required { observe(required, at: startedAt) }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, model.identity == identity else { return }
                if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true; return }
                // Keep an assigned task visible through network errors. Never
                // infer success or request an SMS from an unreadable status.
            }
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
        }
    }
}

@MainActor struct ColdControlNotice: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var control: ColdControlCoordinator
    @State private var presented = false
    var body: some View {
        Group {
            if control.required && !model.sessionExpired && (model.session != nil || model.demo) {
                HStack(spacing: 10) {
                    Image(systemName: "snowflake").font(.title3).foregroundStyle(Palette.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Назначен фотоконтроль").font(.subheadline.weight(.semibold))
                        Text("Хладоэлементы и термосумка").font(.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                    Button("Пройти") { presented = true }.font(.subheadline.weight(.semibold)).padding(.vertical, 10).accessibilityIdentifier("coldcontrol.open")
                }.padding(.horizontal, 16).padding(.vertical, 9).background(Palette.surface)
                    .overlay(alignment: .bottom) { Divider() }.accessibilityElement(children: .contain).accessibilityIdentifier("coldcontrol.notice")
            }
        }
        .sheet(isPresented: $presented) {
            NavigationStack {
                ColdControlView(onComplete: { control.markCompleted(); presented = false }, onLater: { presented = false })
            }
        }
        .onChange(of: control.required) { _, required in if !required { presented = false } }
        .onChange(of: model.identity) { _, _ in presented = false }
    }
}
