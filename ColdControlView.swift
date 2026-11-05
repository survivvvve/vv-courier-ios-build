import SwiftUI
import UIKit
import AVFoundation

@MainActor final class ColdControlCoordinator: ObservableObject {
    @Published private(set) var required = false
    @Published var presented = false
    @Published var newlyRequired = false
    @Published private(set) var generation = 0

    func observeTermocontrol(_ raw: Any?) {
        if let value = ColdControlSignal.required(from: raw) { observeRequired(value) }
    }
    func observeRequired(_ value: Bool) {
        if value && !required { generation += 1; newlyRequired = true }
        required = value
        if !value { newlyRequired = false; presented = false }
    }
    func observeBusinessError(_ code: Int) {
        guard code == ColdControlSignal.businessError else { return }
        observeRequired(true)
    }
    func markCompleted() { observeRequired(false) }
    func reset() { required = false; presented = false; newlyRequired = false; generation = 0 }
}

struct ColdControlView: View {
    @EnvironmentObject private var model: AppModel
    let onComplete: () -> Void
    let onLater: () -> Void
    @State private var step = ColdControlStep.initial
    @State private var photo: UIImage?
    @State private var camera = false
    @State private var working = false
    @State private var accepted = false
    @State private var checkBeforeResend = false
    @State private var failure: String?
    @State private var message: String?

    var body: some View {
        CourierPage("Фотоконтроль", subtitle: "Термосумка и хладоэлементы", showsIncomingTasks: false) {
            if model.demo { DemoBanner() }
            CourierCard {
                Label("ВВ назначил фотоконтроль", systemImage: "snowflake").font(.headline).accessibilityIdentifier("coldcontrol.screen")
                Text("Чтобы продолжить работу, сфотографируй хладоэлементы внутри своей термосумки.").font(.subheadline).foregroundStyle(Palette.muted)
            }
            if let failure { CourierErrorCard(message: failure) { Task { await refreshStatus() } } }
            if let message { CourierCard { Text(message).font(.subheadline).accessibilityIdentifier("coldcontrol.message") } }
            if checkBeforeResend { Text("Ответ об отправке не получен. Сначала обнови статус — фотография могла уже дойти до ВВ.").font(.caption).foregroundStyle(Palette.muted) }
            if working { ProgressView(accepted ? "Проверяем статус…" : "Отправляем в ВВ…").frame(maxWidth: .infinity) }
            if accepted {
                Button("Проверить статус") { Task { await refreshStatus() } }.buttonStyle(CourierButtonStyle(primary: true)).disabled(working).accessibilityIdentifier("coldcontrol.refresh")
                Text("Данные уже приняты ВВ. Повторно отправлять их не нужно.").font(.caption).foregroundStyle(Palette.muted)
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Позже") { onLater() }.disabled(working).accessibilityIdentifier("coldcontrol.later") } }
        .interactiveDismissDisabled(working)
        .task(id: model.identity) {
            step = .initial; photo = nil; camera = false; accepted = false; working = false
            failure = nil; message = nil
            checkBeforeResend = !model.demo && ColdControlPendingStore.needsStatus(courierID: model.session?.courierID ?? "")
            if checkBeforeResend { await refreshStatus() }
        }
        .sheet(isPresented: $camera) {
            ColdControlCamera(onPhoto: { image in photo = image; camera = false }, onCancel: { camera = false })
                .ignoresSafeArea()
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .initial:
            Button("Пройти фотоконтроль") { step = .withPyrometer }.buttonStyle(CourierButtonStyle(primary: true)).accessibilityIdentifier("coldcontrol.start")
            Text("Закрытие этого окна не снимает назначение ВВ. Оно останется доступно в уведомлении до прохождения.").font(.caption).foregroundStyle(Palette.muted)
        case .withPyrometer, .withoutPyrometer:
            CourierCard(step == .withPyrometer ? "С пирометром" : "Без пирометра") {
                Text(step == .withPyrometer ? "В кадре должны быть термосумка, хладоэлементы и пирометр. Температура на пирометре — от −20 до +5 °C." : "В кадре должны быть термосумка и хладоэлементы.").font(.subheadline)
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 330).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("Фото для проверки")
                    Button("Подтвердить и отправить") { Task { await submit(noColdPacks: false) } }.buttonStyle(CourierButtonStyle(primary: true)).disabled(working || checkBeforeResend).accessibilityIdentifier("coldcontrol.submit")
                }
                Button(photo == nil ? "Сфотографировать" : "Переснять") { openCamera() }.buttonStyle(CourierButtonStyle(primary: photo == nil)).disabled(working).accessibilityIdentifier("coldcontrol.camera")
                if model.demo {
                    Button("Добавить учебное фото") { photo = demoPhoto() }.font(.caption).accessibilityIdentifier("coldcontrol.demo-photo")
                }
                Button(step == .withPyrometer ? "Нет пирометра / хладоэлементов" : "Нет хладоэлементов") {
                    photo = nil; step = step == .withPyrometer ? .withoutPyrometer : .withoutColdPacks
                }.buttonStyle(CourierButtonStyle()).disabled(working).accessibilityIdentifier("coldcontrol.missing-equipment")
            }
            Button("Назад") { photo = nil; step = step == .withPyrometer ? .initial : .withPyrometer }.disabled(working)
        case .withoutColdPacks:
            CourierCard {
                Text("У тебя нет хладоэлементов?").font(.headline)
                Text("Если их действительно нет, ВВ уведомит магазин для устранения нарушения.").font(.subheadline).foregroundStyle(Palette.muted)
                Button("Да, у меня нет хладоэлементов") { Task { await submit(noColdPacks: true) } }.buttonStyle(CourierButtonStyle(primary: true)).disabled(working || checkBeforeResend).accessibilityIdentifier("coldcontrol.confirm-no-packs")
                Button("Назад") { step = .withoutPyrometer }.disabled(working)
            }
        }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { failure = "Камера недоступна на этом устройстве."; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = true
        case .notDetermined:
            let identity = model.identity
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in guard model.identity == identity else { return }; if granted { camera = true } else { failure = "Разреши доступ к камере в настройках iPhone." } }
            }
        default: failure = "Доступ к камере выключен. Разреши его в настройках iPhone."
        }
    }

    @MainActor private func submit(noColdPacks: Bool) async {
        guard !working, !accepted, !checkBeforeResend else { return }
        var data: Data?
        if !noColdPacks {
            guard let photo else { failure = "Сначала сделай фотографию."; return }
            data = jpeg(photo)
            guard data != nil else { failure = "Не удалось подготовить фотографию. Пересними её."; return }
        }
        working = true; failure = nil; message = nil
        let identity = model.identity, api = model.api, courierID = model.session?.courierID ?? ""
        defer { if model.identity == identity { working = false } }
        if model.demo {
            accepted = true
            message = "Демо: фотоконтроль завершён только локально. В ВВ ничего не отправлено."
            onComplete(); return
        }
        ColdControlPendingStore.mark(courierID: courierID, pending: true)
        do {
            let result = try await api.submitColdControl(photo: data, hasPyrometer: noColdPacks || step == .withPyrometer, hasColdPacks: !noColdPacks)
            guard model.identity == identity, !Task.isCancelled else { return }
            accepted = true; photo = nil
            if result.isComplete { ColdControlPendingStore.mark(courierID: courierID, pending: false); onComplete() }
            else { message = noColdPacks ? "ВВ принял сообщение об отсутствии хладоэлементов. Проверяем снятие ограничения." : "ВВ принял фотографию. Фотоконтроль ещё числится в статусе — обнови его чуть позже." }
        } catch {
            guard model.identity == identity, !Task.isCancelled else { return }
            checkBeforeResend = true
            failure = error.localizedDescription
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
        }
    }

    @MainActor private func refreshStatus() async {
        guard !working else { return }; working = true; failure = nil
        let identity = model.identity, api = model.api, courierID = model.session?.courierID ?? ""
        defer { if model.identity == identity { working = false } }
        if model.demo { message = "Демонстрационное назначение. Запрос в ВВ не выполняется."; return }
        do {
            let required = try await api.coldControlRequired()
            guard model.identity == identity, !Task.isCancelled else { return }
            if required != nil { ColdControlPendingStore.mark(courierID: courierID, pending: false) }
            if required == false { onComplete() }
            else if required == true {
                checkBeforeResend = false
                message = accepted ? "ВВ принял данные, но статус пока не обновился. Повторная отправка не требуется." : "Фотоконтроль по-прежнему назначен ВВ. Можно проверить фотографию перед новой отправкой."
            } else { message = "Не удалось определить статус фотоконтроля. Обнови его позже." }
        } catch {
            guard model.identity == identity, !Task.isCancelled else { return }
            failure = error.localizedDescription
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
        }
    }
    private func jpeg(_ image: UIImage) -> Data? {
        let ratio = min(1, 1024 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.2)
    }
    private func demoPhoto() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 640, height: 420)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 420))
            ("ДЕМО · ТЕРМОСУМКА\nУчебное фото, не отправляется в ВВ" as NSString).draw(at: CGPoint(x: 30, y: 150), withAttributes: [.font: UIFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: UIColor.white])
        }
    }
}

private enum ColdControlStep { case initial, withPyrometer, withoutPyrometer, withoutColdPacks }

private struct ColdControlCamera: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPhoto: onPhoto, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.cameraDevice = .rear
        picker.delegate = context.coordinator; picker.allowsEditing = false
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPhoto: (UIImage) -> Void
        let onCancel: () -> Void
        init(onPhoto: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) { self.onPhoto = onPhoto; self.onCancel = onCancel }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onPhoto(image) } else { onCancel() }
        }
    }
}
