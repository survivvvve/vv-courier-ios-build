import SwiftUI
import PhotosUI
import UIKit

struct ReceiptPhotosCard: View {
    let parcel: Parcel
    @State private var presented = false
    private var payment: Int? { parcel.effectivePaymentWay }
    var body: some View {
        if parcel.status == "delivered" && payment == 3 {
            CourierCard("Фото чека") {
                Text("Сохрани читаемое фото чека терминала. Длинный чек можно снять несколькими кадрами.").font(.subheadline).foregroundStyle(Palette.muted)
                Button { presented = true } label: { Label("Открыть фото чека", systemImage: "camera") }.buttonStyle(CourierButtonStyle()).accessibilityIdentifier("receipt.open")
            }.sheet(isPresented: $presented) { NavigationStack { ReceiptPhotosView(parcelID: parcel.id, label: parcel.fullNumber, onFinished: { presented = false }) } }
        }
    }
}

struct ReceiptPhotosView: View {
    @EnvironmentObject private var model: AppModel
    let parcelID: String
    let label: String
    var afterCompletion = false
    let onFinished: () -> Void
    @State private var existing: [ReceiptPhoto] = []
    @State private var drafts: [ReceiptDraftPhoto] = []
    @State private var loading = true
    @State private var working = false
    @State private var failure: String?
    @State private var saved = false
    @State private var camera = false
    @State private var cameraIdentity = ""
    @State private var selectedImage: PhotosPickerItem?
    @State private var requestID = UUID()
    @State private var loadedIdentity = ""
    @State private var needsReconciliation = false
    private var courierID: String { model.session?.courierID ?? "" }
    private var canAdd: Bool { !working && !loading && existing.count + drafts.count < 10 }
    var body: some View {
        CourierPage(afterCompletion ? "Заказ доставлен · фото чека" : "Фото чека", subtitle: "Заказ \(label)") {
            if model.demo { DemoBanner() }
            Text("Проверь, чтобы сумма, дата и результат оплаты на чеке читались. Если чек длинный — сделай несколько фото.").font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("receipt.screen")
            if loading { ProgressView("Проверяем прикреплённые фото…").frame(maxWidth: .infinity) }
            if let failure { CourierErrorCard(message: failure) { Task { await reload() } } }
            if afterCompletion { Label("ВВ подтвердил статус «Доставлен»", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Palette.success) }
            if !existing.isEmpty {
                CourierCard("Сохранено в ВВ · \(existing.count)") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(existing) { photo in
                                AsyncImage(url: URL(string: photo.url)) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                                    .frame(width: 160, height: 210).background(Palette.field, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            }
            ForEach(drafts) { photo in
                CourierCard {
                    if let image = UIImage(data: photo.jpeg) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300).frame(maxWidth: .infinity) }
                    HStack {
                        Text(photo.uploadedID == nil ? "Черновик · ещё не отправлено" : "Загружено · ожидает прикрепления").font(.caption).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("Убрать", role: .destructive) { drafts.removeAll { $0.id == photo.id }; persist() }.disabled(working)
                    }
                }
            }
            if saved { Label("Фото сохранено в ВВ", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.success).accessibilityIdentifier("receipt.saved") }
            HStack(spacing: 10) {
                Button { cameraIdentity = model.identity; camera = true } label: { Label("Камера", systemImage: "camera") }.buttonStyle(CourierButtonStyle()).disabled(!canAdd || !UIImagePickerController.isSourceTypeAvailable(.camera)).accessibilityIdentifier("receipt.camera")
                PhotosPicker(selection: $selectedImage, matching: .images, photoLibrary: .shared()) { Label("Галерея", systemImage: "photo") }.buttonStyle(CourierButtonStyle()).disabled(!canAdd).accessibilityIdentifier("receipt.gallery")
            }
            if model.demo {
                Button("Добавить учебное фото") { add(Self.demoJPEG()) }.buttonStyle(CourierButtonStyle()).disabled(!canAdd).accessibilityIdentifier("receipt.demo-photo")
            }
            Button(working ? "Сохраняем…" : "Сохранить фото · \(drafts.count)") { Task { await save() } }.buttonStyle(CourierButtonStyle(primary: true)).disabled(working || loading || drafts.isEmpty || needsReconciliation).accessibilityIdentifier("receipt.save")
            if needsReconciliation { Text("Сначала обнови фото: предыдущая отправка могла уже сохраниться в ВВ.").font(.caption).foregroundStyle(Palette.muted) }
            Button(afterCompletion && existing.isEmpty ? "Позже · заказ уже завершён" : "Готово") { onFinished() }.buttonStyle(CourierButtonStyle()).disabled(working).accessibilityIdentifier("receipt.done")
            if drafts.isEmpty && existing.isEmpty { Text("Фото можно добавить позже из архива заказов.").font(.caption).foregroundStyle(Palette.muted) }
            if !drafts.isEmpty { Text("Черновик сохранён на этом iPhone до отправки. Отправка фото не закрывает заказ повторно.").font(.caption).foregroundStyle(Palette.muted) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(working)
        .task(id: model.identity) {
            if loadedIdentity != model.identity {
                loadedIdentity = model.identity; requestID = UUID(); working = false
                existing = []; drafts = []; saved = false; camera = false; cameraIdentity = ""; selectedImage = nil; needsReconciliation = false
            }
            if !model.demo { drafts = ReceiptDraftStore.load(courierID: courierID, parcelID: parcelID) }
            await reload()
        }
        .onChange(of: selectedImage) { _, item in
            let identity = model.identity
            Task {
                do {
                    guard let item, let data = try await item.loadTransferable(type: Data.self) else { return }
                    guard model.identity == identity else { return }; add(data); selectedImage = nil
                } catch { if model.identity == identity { failure = "Не удалось прочитать фото. Выбери его ещё раз." } }
            }
        }
        .sheet(isPresented: $camera) {
            ReceiptCamera { image in
                camera = false
                guard model.identity == cameraIdentity else { return }
                if let data = image?.jpegData(compressionQuality: 0.9) { add(data) }
            }.ignoresSafeArea()
        }
    }
    @MainActor private func reload() async {
        guard !working else { return }
        let id = UUID(), identity = model.identity, client = model.api
        requestID = id; loading = true; failure = nil
        if drafts.contains(where: { $0.uploadedID != nil }) { needsReconciliation = true }
        defer { if requestID == id { loading = false } }
        if model.demo { return }
        do {
            let parcel = try await client.parcel(parcelID)
            guard requestID == id, model.identity == identity, !Task.isCancelled else { return }
            existing = (parcel.raw["check_photo"] as? [[String: Any]] ?? []).compactMap(ReceiptPhoto.init)
            // An attachment request can succeed while its response is lost.
            // Reconcile IDs before offering another attachment request.
            let savedIDs = Set(existing.map(\.id))
            drafts.removeAll { $0.uploadedID.map(savedIDs.contains) == true }
            needsReconciliation = false
            persist()
        } catch { guard requestID == id, model.identity == identity, !Task.isCancelled else { return }; failure = error.localizedDescription; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } }
    }
    private func add(_ data: Data) {
        guard canAdd, let image = UIImage(data: data) else { return }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        guard size.width > 0, size.height > 0 else { failure = "Не удалось прочитать размер фото."; return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let jpeg = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
        guard let jpeg, jpeg.count <= 8 * 1024 * 1024 else { failure = "Фото слишком большое. Сделай новый снимок."; return }
        drafts.append(ReceiptDraftPhoto(jpeg: jpeg)); saved = false; persist()
    }
    private func persist() {
        guard !model.demo else { return }
        do {
            if drafts.isEmpty { ReceiptDraftStore.clear(courierID: courierID, parcelID: parcelID) }
            else { try ReceiptDraftStore.save(drafts, courierID: courierID, parcelID: parcelID) }
        } catch { failure = "Не удалось сохранить черновик на iPhone. Не закрывай окно до отправки фото." }
    }
    @MainActor private func save() async {
        guard !working, !loading, !drafts.isEmpty, !needsReconciliation else { return }
        let id = UUID(), identity = model.identity, client = model.api
        requestID = id; working = true; failure = nil; saved = false
        defer { if requestID == id { working = false } }
        if model.demo { drafts = []; saved = true; return }
        do {
            let pending = drafts.filter { $0.uploadedID == nil }
            for photo in pending {
                let uploaded = try await client.uploadReceiptPhoto(photo.jpeg)
                guard requestID == id, model.identity == identity, !Task.isCancelled else { return }
                guard let index = drafts.firstIndex(where: { $0.id == photo.id }) else { return }
                drafts[index].uploadedID = uploaded; persist()
            }
            let ids = drafts.compactMap(\.uploadedID)
            needsReconciliation = true
            let attached = try await client.attachReceiptPhotos(parcelID: parcelID, uploadedIDs: ids)
            guard requestID == id, model.identity == identity, !Task.isCancelled else { return }
            existing = attached
            drafts = []; ReceiptDraftStore.clear(courierID: courierID, parcelID: parcelID); saved = true; needsReconciliation = false
        } catch { guard requestID == id, model.identity == identity, !Task.isCancelled else { return }; failure = error.localizedDescription; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } }
    }
    private static func demoJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 420, height: 620))
        return renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 420, height: 620))
            let text = "УЧЕБНОЕ ФОТО\nНЕ ПЛАТЁЖНЫЙ ЧЕК\n\nДемо без отправки в ВВ"
            text.draw(in: CGRect(x: 30, y: 50, width: 360, height: 450), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 24, weight: .medium), .foregroundColor: UIColor.black])
        }.jpegData(compressionQuality: 0.8)!
    }
}

private struct ReceiptCamera: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage?) -> Void
        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onImage(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { onImage(info[.originalImage] as? UIImage) }
    }
}
