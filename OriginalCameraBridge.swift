import UIKit
import WebKit
import AVFoundation
import Photos
import PhotosUI
import UniformTypeIdentifiers

/// Camera APIs used by the original courier website. The owner must invalidate
/// this bridge before replacing its document, and must put WKWebView in a UIView
/// container so the scan preview can sit underneath the website's controls.
///
/// `startScan`/`scan` return one result. The community plugin's `startScanning`
/// is a native callback: each result has keepAlive=true, until stop or failure.
/// addListener saves its callback without sending an artificial initial event.
@MainActor
final class OriginalCameraBridge: NSObject, UIImagePickerControllerDelegate,
                                  UINavigationControllerDelegate, PHPickerViewControllerDelegate,
                                  UIAdaptivePresentationControllerDelegate {
    var reply: ((String, Bool, [String: Any]?, String?, Bool) -> Void)?

    private weak var presenter: UIViewController?
    private weak var webView: WKWebView?
    private var generation: UInt = 0
    private var invalidated = false
    private var photo: PhotoRequest?
    private var photoController: UIViewController?
    private var photoLoad: Progress?
    private var scan: ScanRequest?
    private var listeners: [String: String] = [:] // callback ID -> event name
    private var webBackground: WebBackground?
    private let photoQueue = DispatchQueue(label: "vvcourier.original.photo", qos: .userInitiated)
    private let hardwareQueue = DispatchQueue(label: "vvcourier.original.camera-query")

    init(presenter: UIViewController, webView: WKWebView) {
        self.presenter = presenter
        self.webView = webView
        super.init()
    }

    /// Returns false only for a plugin that belongs to another bridge.
    func handle(plugin: String, method: String, options: [String: Any], callbackID: String) -> Bool {
        guard plugin == "Camera" || plugin == "BarcodeScanner" else { return false }
        guard !invalidated else { return true }
        if plugin == "Camera" {
            switch method {
            case "checkPermissions": resolve(callbackID, cameraPermissions())
            case "requestPermissions": requestPhotoPermissions(options, callbackID: callbackID)
            case "getPhoto": getPhoto(options, callbackID: callbackID)
            default: reject(callbackID, "Метод Camera.\(method) не поддерживается нативным мостом.")
            }
        } else {
            switch method {
            case "checkPermission":
                if options["force"] as? Bool == true {
                    requestBarcodePermission(callbackID: callbackID, legacy: true)
                } else {
                    resolve(callbackID, barcodePermission())
                }
            case "checkPermissions": resolve(callbackID, ["camera": cameraPermissionName()])
            case "requestPermissions", "requestPermission":
                requestBarcodePermission(callbackID: callbackID, legacy: method == "requestPermission")
            case "prepare":
                guard hasUsageDescription("NSCameraUsageDescription") else {
                    reject(callbackID, "В приложении отсутствует описание доступа к камере."); return true
                }
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    reject(callbackID, "На этом устройстве нет доступной камеры."); return true
                }
                resolve(callbackID)
            case "scan", "startScan": startScan(options, callbackID: callbackID, continuous: false)
            case "startScanning": startScan(options, callbackID: callbackID, continuous: true)
            case "stopScan", "stopScanning":
                let epoch = generation
                stopScan(completion: .cancelled) { [weak self] in
                    guard let self, self.isCurrent(epoch) else { return }
                    self.restoreBackground()
                    self.resolve(callbackID)
                }
            case "pauseScanning":
                guard scan != nil else { reject(callbackID, "Сканер не запущен."); return true }
                scan?.paused = true
                scan?.controller?.capture.pause()
                resolve(callbackID)
            case "resumeScanning":
                guard scan != nil else { reject(callbackID, "Сканер не запущен."); return true }
                scan?.paused = false
                scan?.controller?.capture.resume()
                resolve(callbackID)
            case "addListener": addListener(options, callbackID: callbackID)
            case "removeListener":
                if let id = options["callbackId"] as? String ?? options["callbackID"] as? String,
                   options["eventName"] as? String == nil || listeners[id] == options["eventName"] as? String {
                    listeners.removeValue(forKey: id)
                }
                resolve(callbackID)
            case "removeAllListeners":
                listeners.removeAll()
                resolve(callbackID)
            case "isTorchAvailable": isTorchAvailable(callbackID: callbackID)
            case "enableTorch": setTorch(true, callbackID: callbackID)
            case "disableTorch": setTorch(false, callbackID: callbackID)
            case "toggleTorch": setTorch(nil, callbackID: callbackID)
            case "getTorchState": getTorchState(callbackID: callbackID)
            case "hideBackground": makeBackgroundTransparent(); resolve(callbackID)
            case "showBackground": restoreBackground(); resolve(callbackID)
            default: reject(callbackID, "Метод BarcodeScanner.\(method) не поддерживается нативным мостом.")
            }
        }
        return true
    }

    /// No callbacks from the old document, permissions prompt, photo provider,
    /// encoder or capture queue may cross this boundary.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        generation &+= 1
        reply = nil
        listeners.removeAll()
        stopScan(completion: .silent)
        photo = nil
        photoLoad?.cancel()
        photoLoad = nil
        let ownedController = photoController
        photoController = nil
        (ownedController as? UIImagePickerController)?.delegate = nil
        (ownedController as? PHPickerViewController)?.delegate = nil
        ownedController?.presentationController?.delegate = nil
        ownedController?.dismiss(animated: false)
        restoreBackground()
    }

    private func isCurrent(_ epoch: UInt) -> Bool { !invalidated && epoch == generation }

    private func resolve(_ id: String, _ data: [String: Any] = [:], keepAlive: Bool = false) {
        guard !invalidated else { return }
        reply?(id, true, data, nil, keepAlive)
    }

    private func reject(_ id: String, _ message: String) {
        guard !invalidated else { return }
        reply?(id, false, nil, message, false)
    }

    private func hasUsageDescription(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func cameraPermissionName() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "granted"
        case .notDetermined: return "prompt"
        case .denied, .restricted: return "denied"
        @unknown default: return "denied"
        }
    }

    private func cameraPermissions() -> [String: Any] {
        let photos: String
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: photos = "granted"
        case .limited: photos = "limited"
        case .notDetermined: photos = "prompt"
        case .denied, .restricted: photos = "denied"
        @unknown default: photos = "denied"
        }
        return ["camera": cameraPermissionName(), "photos": photos]
    }

    private func barcodePermission() -> [String: Any] {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return ["granted": status == .authorized,
                "denied": status == .denied,
                "restricted": status == .restricted,
                "neverAsked": status == .notDetermined,
                "asked": status != .notDetermined,
                "unknown": ![.authorized, .denied, .restricted, .notDetermined].contains(status)]
    }

    private func authorizeCamera(epoch: UInt, completion: @escaping (Bool, String?) -> Void) {
        guard isCurrent(epoch) else { return }
        guard hasUsageDescription("NSCameraUsageDescription") else {
            completion(false, "В приложении отсутствует описание доступа к камере."); return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status != .notDetermined {
            completion(status == .authorized, nil)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(epoch) else { return }
                completion(AVCaptureDevice.authorizationStatus(for: .video) == .authorized, nil)
            }
        }
    }

    private func requestBarcodePermission(callbackID: String, legacy: Bool) {
        let epoch = generation
        authorizeCamera(epoch: epoch) { [weak self] _, error in
            guard let self, self.isCurrent(epoch) else { return }
            if let error { self.reject(callbackID, error) }
            else { self.resolve(callbackID, legacy ? self.barcodePermission() : ["camera": self.cameraPermissionName()]) }
        }
    }

    private func requestPhotoPermissions(_ options: [String: Any], callbackID: String) {
        let requested: [String]
        if let value = options["permissions"] {
            guard let values = value as? [String], values.allSatisfy({ $0 == "camera" || $0 == "photos" }) else {
                reject(callbackID, "Camera.requestPermissions ожидает разрешения camera и photos."); return
            }
            requested = values
        } else { requested = ["camera", "photos"] }
        if requested.contains("photos"), !hasUsageDescription("NSPhotoLibraryUsageDescription") {
            reject(callbackID, "В приложении отсутствует описание доступа к медиатеке."); return
        }
        let epoch = generation
        let finish: () -> Void = { [weak self] in
            guard let self, self.isCurrent(epoch) else { return }
            if requested.contains("photos"), PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.isCurrent(epoch) else { return }
                        self.resolve(callbackID, self.cameraPermissions())
                    }
                }
            } else { self.resolve(callbackID, self.cameraPermissions()) }
        }
        if requested.contains("camera") {
            authorizeCamera(epoch: epoch) { [weak self] _, error in
                guard let self, self.isCurrent(epoch) else { return }
                if let error { self.reject(callbackID, error) }
                else { finish() }
            }
        } else { finish() }
    }

    private struct PhotoRequest {
        let id: String
        let epoch: UInt
        let token = UUID()
        let options: OriginalPhotoOptions
    }

    private func getPhoto(_ options: [String: Any], callbackID: String) {
        guard photo == nil else { reject(callbackID, "Выбор фотографии уже открыт."); return }
        let settings: OriginalPhotoOptions
        do { settings = try OriginalPhotoOptions(options) }
        catch { reject(callbackID, error.localizedDescription); return }
        guard availablePresenter() != nil else {
            reject(callbackID, "Сейчас нельзя открыть камеру или медиатеку."); return
        }
        let request = PhotoRequest(id: callbackID, epoch: generation, options: settings)
        photo = request
        stopScan(completion: .cancelled) { [weak self] in
            guard let self, self.isCurrentPhoto(request) else { return }
            self.beginPhoto(request, labels: options)
        }
    }

    private func beginPhoto(_ request: PhotoRequest, labels: [String: Any]) {
        guard isCurrentPhoto(request), let owner = availablePresenter() else {
            finishPhoto(request, error: "Сейчас нельзя открыть камеру или медиатеку."); return
        }
        switch request.options.source {
        case "CAMERA": presentCamera(request)
        case "PHOTOS": presentPhotos(request)
        default:
            let sheet = UIAlertController(title: labels["promptLabelHeader"] as? String ?? "Фотография",
                                          message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: labels["promptLabelPicture"] as? String ?? "Сделать фото", style: .default) { [weak self, weak sheet] _ in
                sheet?.dismiss(animated: true) {
                    guard let self, self.isCurrentPhoto(request) else { return }
                    self.photoController = nil
                    self.presentCamera(request)
                }
            })
            sheet.addAction(UIAlertAction(title: labels["promptLabelPhoto"] as? String ?? "Выбрать из фото", style: .default) { [weak self, weak sheet] _ in
                sheet?.dismiss(animated: true) {
                    guard let self, self.isCurrentPhoto(request) else { return }
                    self.photoController = nil
                    self.presentPhotos(request)
                }
            })
            sheet.addAction(UIAlertAction(title: labels["promptLabelCancel"] as? String ?? "Отмена", style: .cancel) { [weak self] _ in
                self?.finishPhoto(request, error: "User cancelled photos app")
            })
            sheet.popoverPresentationController?.sourceView = owner.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
            presentPhotoController(sheet, from: owner, request: request)
        }
    }

    private func availablePresenter() -> UIViewController? {
        guard let presenter, presenter.viewIfLoaded?.window != nil else { return nil }
        var owner = presenter
        while let presented = owner.presentedViewController {
            guard !presented.isBeingDismissed else { return nil }
            owner = presented
        }
        guard !owner.isBeingDismissed, !owner.isBeingPresented else { return nil }
        return owner
    }

    private func isCurrentPhoto(_ request: PhotoRequest) -> Bool {
        isCurrent(request.epoch) && photo?.token == request.token
    }

    private func presentCamera(_ request: PhotoRequest) {
        authorizeCamera(epoch: request.epoch) { [weak self] allowed, error in
            guard let self, self.isCurrentPhoto(request) else { return }
            guard allowed else {
                self.finishPhoto(request, error: error ?? "Доступ к камере выключен. Разреши его в настройках iPhone для VV Courier.")
                return
            }
            guard UIImagePickerController.isSourceTypeAvailable(.camera), let owner = self.availablePresenter() else {
                self.finishPhoto(request, error: "На этом устройстве камера недоступна."); return
            }
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.mediaTypes = [UTType.image.identifier]
            picker.cameraCaptureMode = .photo
            let direction: UIImagePickerController.CameraDevice = request.options.frontCamera ? .front : .rear
            guard UIImagePickerController.isCameraDeviceAvailable(direction) else {
                self.finishPhoto(request, error: "Выбранная камера недоступна."); return
            }
            picker.cameraDevice = direction
            picker.allowsEditing = request.options.allowEditing
            picker.delegate = self
            picker.modalPresentationStyle = .fullScreen
            self.presentPhotoController(picker, from: owner, request: request)
        }
    }

    private func presentPhotos(_ request: PhotoRequest) {
        guard isCurrentPhoto(request), let owner = availablePresenter() else {
            finishPhoto(request, error: "Сейчас нельзя открыть медиатеку."); return
        }
        // PHPicker grants access only to the selected image, without pretending
        // that the app has permission to read the user's entire photo library.
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presentPhotoController(picker, from: owner, request: request)
    }

    private func presentPhotoController(_ controller: UIViewController, from owner: UIViewController, request: PhotoRequest) {
        guard isCurrentPhoto(request) else { return }
        photoController = controller
        controller.presentationController?.delegate = self
        owner.present(controller, animated: true) { [weak self, weak controller] in
            guard let self, self.isCurrentPhoto(request) else { return }
            controller?.presentationController?.delegate = self
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        guard photoController === picker, let request = photo else { return }
        finishPhoto(request, error: "User cancelled camera app")
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        guard photoController === picker, let request = photo, isCurrentPhoto(request) else { return }
        guard let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage else {
            finishPhoto(request, error: "Камера не вернула изображение."); return
        }
        photoController = nil
        picker.dismiss(animated: true) { [weak self] in self?.encodePhoto(image, request: request) }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard photoController === picker, let request = photo, isCurrentPhoto(request) else { return }
        guard let provider = results.first?.itemProvider else {
            finishPhoto(request, error: "User cancelled photos app"); return
        }
        guard provider.canLoadObject(ofClass: UIImage.self) else {
            finishPhoto(request, error: "Выбранный файл не удалось прочитать как фотографию."); return
        }
        photoController = nil
        picker.dismiss(animated: true) { [weak self] in
            guard let self, self.isCurrentPhoto(request) else { return }
            self.photoLoad = provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                DispatchQueue.main.async {
                    guard let self, self.isCurrentPhoto(request) else { return }
                    self.photoLoad = nil
                    guard let image = object as? UIImage else {
                        self.finishPhoto(request, error: error?.localizedDescription ?? "Не удалось загрузить фотографию.")
                        return
                    }
                    self.encodePhoto(image, request: request)
                }
            }
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard photoController === presentationController.presentedViewController, let request = photo else { return }
        photoController = nil
        finishPhoto(request, error: "User cancelled photos app")
    }

    private func encodePhoto(_ image: UIImage, request: PhotoRequest) {
        guard isCurrentPhoto(request) else { return }
        photoQueue.async { [weak self] in
            let result = autoreleasepool { Result { try request.options.encode(image) } }
            DispatchQueue.main.async {
                guard let self, self.isCurrentPhoto(request) else { return }
                self.photo = nil
                switch result {
                case .success(let data): self.resolve(request.id, data)
                case .failure(let error): self.reject(request.id, error.localizedDescription)
                }
            }
        }
    }

    private func finishPhoto(_ request: PhotoRequest, error: String) {
        guard isCurrentPhoto(request) else { return }
        photo = nil
        photoLoad?.cancel()
        photoLoad = nil
        let controller = photoController
        photoController = nil
        controller?.presentationController?.delegate = nil
        controller?.dismiss(animated: true)
        reject(request.id, error)
    }

    private struct ScanRequest {
        let id: String
        let epoch: UInt
        let token = UUID()
        let continuous: Bool
        var paused = false
        var controller: OriginalBarcodeCaptureController?
    }

    private enum ScanCompletion { case silent, cancelled, result([String: Any]), failure(String) }

    private func startScan(_ options: [String: Any], callbackID: String, continuous: Bool) {
        guard scan == nil else { reject(callbackID, "Сканер уже запущен."); return }
        guard photo == nil else { reject(callbackID, "Сначала закрой выбор фотографии."); return }
        let settings: OriginalBarcodeOptions
        do { settings = try OriginalBarcodeOptions(options) }
        catch { reject(callbackID, error.localizedDescription); return }
        let request = ScanRequest(id: callbackID, epoch: generation, continuous: continuous)
        scan = request
        authorizeCamera(epoch: request.epoch) { [weak self] allowed, error in
            guard let self, self.isCurrentScan(request) else { return }
            guard allowed else {
                self.stopScan(completion: .failure(error ?? "Доступ к камере выключен. Разреши его в настройках iPhone для VV Courier."))
                return
            }
            guard let owner = self.presenter, let webView = self.webView,
                  owner.viewIfLoaded?.window != nil, owner.view !== webView,
                  webView.isDescendant(of: owner.view) else {
                self.stopScan(completion: .failure("Не удалось показать камеру под веб-интерфейсом.")); return
            }
            let controller = OriginalBarcodeCaptureController(options: settings)
            controller.capture.onReady = { [weak self] error in
                guard let self, self.isCurrentScan(request) else { return }
                if let error { self.stopScan(completion: .failure(error)) }
            }
            controller.capture.onFailure = { [weak self] error in
                guard let self, self.isCurrentScan(request) else { return }
                self.stopScan(completion: .failure(error))
            }
            controller.capture.onCodes = { [weak self] codes in
                guard let self, self.isCurrentScan(request), self.scan?.paused == false,
                      UIApplication.shared.applicationState == .active,
                      let first = codes.first else { return }
                let result: [String: Any] = ["hasContent": true, "content": first["rawValue"] ?? "",
                                           "format": first["format"] ?? "", "barcode": first, "barcodes": codes]
                self.emitBarcodes(codes)
                if request.continuous { self.resolve(request.id, result, keepAlive: true) }
                else { self.stopScan(completion: .result(result)) }
            }
            self.scan?.controller = controller
            owner.addChild(controller)
            controller.view.frame = owner.view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if webView.superview === owner.view { owner.view.insertSubview(controller.view, belowSubview: webView) }
            else { owner.view.insertSubview(controller.view, at: 0) }
            controller.didMove(toParent: owner)
            self.makeBackgroundTransparent()
            if self.scan?.paused == true { controller.capture.pause() }
            controller.capture.start()
        }
    }

    private func isCurrentScan(_ request: ScanRequest) -> Bool {
        isCurrent(request.epoch) && scan?.token == request.token
    }

    private func stopScan(completion: ScanCompletion, afterStop: (@MainActor () -> Void)? = nil) {
        guard let request = scan else {
            if let afterStop { OriginalBarcodeCapture.afterPendingOperations(afterStop) }
            return
        }
        scan = nil
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.isCurrent(request.epoch) else { return }
            switch completion {
            case .silent: break
            case .cancelled: self.resolve(request.id, ["hasContent": false, "content": "", "barcodes": []])
            case .result(let result): self.resolve(request.id, result)
            case .failure(let error): self.reject(request.id, error)
            }
            afterStop?()
        }
        if let controller = request.controller {
            controller.capture.stop(completion: finish)
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        } else {
            OriginalBarcodeCapture.afterPendingOperations(finish)
        }
        restoreBackground()
    }

    private func addListener(_ options: [String: Any], callbackID: String) {
        guard let name = options["eventName"] as? String,
              name == "barcodeScanned" || name == "barcodesScanned" else {
            reject(callbackID, "Событие BarcodeScanner не поддерживается."); return
        }
        listeners[callbackID] = name
    }

    private func emitBarcodes(_ codes: [[String: Any]]) {
        guard let first = codes.first else { return }
        let data: [String: Any] = ["barcode": first, "barcodes": codes]
        for id in Array(listeners.keys) where listeners[id] != nil {
            resolve(id, data, keepAlive: true)
        }
    }

    private func isTorchAvailable(callbackID: String) {
        let epoch = generation
        if let capture = scan?.controller?.capture {
            capture.isTorchAvailable { [weak self] available in
                guard let self, self.isCurrent(epoch) else { return }
                self.resolve(callbackID, ["available": available, "isAvailable": available])
            }
        } else {
            hardwareQueue.async { [weak self] in
                let available = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)?.hasTorch == true
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(epoch) else { return }
                    self.resolve(callbackID, ["available": available, "isAvailable": available])
                }
            }
        }
    }

    private func setTorch(_ enabled: Bool?, callbackID: String) {
        guard let request = scan, let capture = request.controller?.capture else {
            if enabled == false { resolve(callbackID) }
            else { reject(callbackID, "Фонарик доступен после запуска сканера.") }
            return
        }
        capture.setTorch(enabled) { [weak self] error in
            guard let self, self.isCurrent(request.epoch) else { return }
            guard self.isCurrentScan(request) else { self.reject(callbackID, "Сканер остановлен."); return }
            if let error { self.reject(callbackID, error) }
            else { self.resolve(callbackID) }
        }
    }

    private func getTorchState(callbackID: String) {
        let epoch = generation
        guard let request = scan, let capture = request.controller?.capture else {
            resolve(callbackID, ["isEnabled": false]); return
        }
        capture.getTorchState { [weak self] enabled in
            guard let self, self.isCurrent(epoch) else { return }
            self.resolve(callbackID, ["isEnabled": self.isCurrentScan(request) && enabled])
        }
    }

    private struct WebBackground {
        let opaque: Bool
        let color: UIColor?
        let scrollColor: UIColor?
        let underPageColor: UIColor?
    }

    private func makeBackgroundTransparent() {
        guard let webView else { return }
        if webBackground == nil {
            webBackground = WebBackground(opaque: webView.isOpaque, color: webView.backgroundColor,
                                          scrollColor: webView.scrollView.backgroundColor,
                                          underPageColor: webView.underPageBackgroundColor)
        }
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
    }

    private func restoreBackground() {
        guard let original = webBackground else { return }
        webBackground = nil
        guard let webView else { return }
        webView.isOpaque = original.opaque
        webView.backgroundColor = original.color
        webView.scrollView.backgroundColor = original.scrollColor
        webView.underPageBackgroundColor = original.underPageColor ?? .clear
    }
}

private struct OriginalNativeCameraError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct OriginalPhotoOptions {
    let source: String
    let resultType: String
    let quality: CGFloat
    let width: CGFloat?
    let height: CGFloat?
    let frontCamera: Bool
    let allowEditing: Bool

    init(_ options: [String: Any]) throws {
        source = (options["source"] as? String ?? "PROMPT").uppercased()
        guard ["CAMERA", "PHOTOS", "PROMPT"].contains(source) else {
            throw OriginalNativeCameraError(message: "Неизвестный источник фотографии.")
        }
        resultType = options["resultType"] as? String ?? "uri"
        guard ["uri", "base64", "dataUrl"].contains(resultType) else {
            throw OriginalNativeCameraError(message: "Неизвестный формат результата фотографии.")
        }
        guard options["saveToGallery"] as? Bool != true else {
            throw OriginalNativeCameraError(message: "Сохранение снятого фото в медиатеку этим мостом не поддерживается.")
        }
        let rawQuality = (options["quality"] as? NSNumber)?.doubleValue ?? 90
        guard rawQuality.isFinite else { throw OriginalNativeCameraError(message: "Некорректное качество фотографии.") }
        quality = CGFloat(max(0, min(100, rawQuality)) / 100)
        func dimension(_ name: String) throws -> CGFloat? {
            guard let value = options[name] else { return nil }
            guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else {
                throw OriginalNativeCameraError(message: "Некорректный размер фотографии.")
            }
            return CGFloat(number.doubleValue)
        }
        width = try dimension("width")
        height = try dimension("height")
        frontCamera = (options["direction"] as? String ?? "REAR").uppercased() == "FRONT"
        allowEditing = options["allowEditing"] as? Bool ?? false
    }

    func encode(_ image: UIImage) throws -> [String: Any] {
        var size = CGSize(width: CGFloat(image.cgImage?.width ?? 0), height: CGFloat(image.cgImage?.height ?? 0))
        if size.width <= 0 || size.height <= 0 {
            size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored: size = CGSize(width: size.height, height: size.width)
        default: break
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw OriginalNativeCameraError(message: "Фотография имеет некорректный размер.")
        }
        let ratio = min(1, min(width.map { $0 / size.width } ?? 1, height.map { $0 / size.height } ?? 1))
        size = CGSize(width: max(1, floor(size.width * ratio)), height: max(1, floor(size.height * ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = normalized.jpegData(compressionQuality: quality), !jpeg.isEmpty else {
            throw OriginalNativeCameraError(message: "Не удалось подготовить JPEG-фотографию.")
        }
        let base64 = jpeg.base64EncodedString()
        let dataURL = "data:image/jpeg;base64," + base64
        var result: [String: Any] = ["format": "jpeg", "saved": false]
        switch resultType {
        case "base64": result["base64String"] = base64
        case "dataUrl": result["dataUrl"] = dataURL
        default: result["webPath"] = dataURL
        }
        return result
    }
}

private struct OriginalBarcodeOptions {
    let position: AVCaptureDevice.Position
    let formats: Set<String>?

    init(_ options: [String: Any]) throws {
        let direction = (options["cameraDirection"] as? String ?? options["lensFacing"] as? String ?? "back").lowercased()
        position = direction == "front" ? .front : .back
        let values = options["targetedFormats"] ?? options["formats"]
        if let values {
            guard let requested = values as? [String] else {
                throw OriginalNativeCameraError(message: "Форматы штрихкодов должны быть списком строк.")
            }
            var selected = Set<String>()
            for format in requested {
                let key = format.uppercased().filter { $0.isLetter || $0.isNumber }
                let canonical: String
                switch key {
                case "ALL", "ALLFORMATS": continue
                case "QR", "QRCODE": canonical = "QR_CODE"
                case "AZTEC": canonical = "AZTEC"
                case "CODABAR": canonical = "CODABAR"
                case "CODE39", "CODE39MOD43": canonical = "CODE_39"
                case "CODE93": canonical = "CODE_93"
                case "CODE128": canonical = "CODE_128"
                case "DATAMATRIX": canonical = "DATA_MATRIX"
                case "EAN8": canonical = "EAN_8"
                case "EAN13": canonical = "EAN_13"
                case "ITF", "ITF14", "INTERLEAVED2OF5": canonical = "ITF"
                case "PDF417": canonical = "PDF_417"
                case "UPCA": canonical = "UPC_A"
                case "UPCE": canonical = "UPC_E"
                default: throw OriginalNativeCameraError(message: "Формат штрихкода \(format) не поддерживается.")
                }
                selected.insert(canonical)
            }
            formats = selected.isEmpty ? nil : selected
        } else { formats = nil }
    }

    static let supported: [(AVMetadataObject.ObjectType, String)] = [
        (.qr, "QR_CODE"), (.aztec, "AZTEC"), (.dataMatrix, "DATA_MATRIX"), (.pdf417, "PDF_417"),
        (.ean8, "EAN_8"), (.ean13, "EAN_13"), (.upce, "UPC_E"), (.code39, "CODE_39"),
        (.code39Mod43, "CODE_39"), (.code93, "CODE_93"), (.code128, "CODE_128"),
        (.interleaved2of5, "ITF"), (.itf14, "ITF"), (.codabar, "CODABAR")
    ]

    func accepts(_ format: String) -> Bool {
        formats == nil || formats!.contains(format) || (format == "EAN_13" && formats!.contains("UPC_A"))
    }

    func barcode(_ object: AVMetadataMachineReadableCodeObject) -> [String: Any]? {
        guard var raw = object.stringValue, !raw.isEmpty,
              var format = Self.supported.first(where: { $0.0 == object.type })?.1 else { return nil }
        if format == "EAN_13", formats?.contains("UPC_A") == true, formats?.contains("EAN_13") != true {
            guard raw.count == 13, raw.hasPrefix("0") else { return nil }
            raw.removeFirst()
            format = "UPC_A"
        }
        return ["rawValue": raw, "displayValue": raw, "format": format]
    }
}

/// All capture configuration, start/stop, metadata and torch operations are
/// serialized on this queue. UIKit and the website only receive main-queue data.
private final class OriginalBarcodeCapture: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    var onReady: (@MainActor (String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onCodes: (@MainActor ([[String: Any]]) -> Void)?
    private let options: OriginalBarcodeOptions
    private static let workQueue = DispatchQueue(label: "vvcourier.original.barcode", qos: .userInitiated)
    private let queue = OriginalBarcodeCapture.workQueue
    private let cancellationLock = NSLock()
    private var cancelled = false // protected by cancellationLock
    private var configured = false // everything below is capture-queue state
    private var reportedReady = false
    private var paused = false
    private var backgrounded = false
    private var device: AVCaptureDevice?
    private var recent: [String: TimeInterval] = [:]
    private var observers: [NSObjectProtocol] = []

    init(options: OriginalBarcodeOptions) {
        self.options = options
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.queue.async { [weak self] in
                guard let self, !self.isCancelled, !self.backgrounded, !self.paused else { return }
                if error?.code == .mediaServicesWereReset { self.run() }
                else { self.fail(error?.localizedDescription ?? "Ошибка видеокамеры. Закрой сканер и открой снова.") }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, !self.isCancelled, !self.backgrounded, !self.paused else { return }
                self.fail("Камера временно занята другим приложением. Закрой сканер и открой снова.")
            }
        })
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    private var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    func start() { queue.async { [self] in run() } }

    func pause() {
        queue.async { [self] in
            paused = true
            stopHardware()
        }
    }

    func resume() {
        queue.async { [self] in
            paused = false
            run()
        }
    }

    func setBackgrounded(_ value: Bool) {
        queue.async { [self] in
            backgrounded = value
            if value { stopHardware() }
            else { run() }
        }
    }

    static func afterPendingOperations(_ completion: @escaping @MainActor () -> Void) {
        workQueue.async { DispatchQueue.main.async { completion() } }
    }

    func stop(completion: (@MainActor () -> Void)? = nil) {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
        queue.async { [self] in
            stopHardware()
            session.beginConfiguration()
            for case let output as AVCaptureMetadataOutput in session.outputs {
                output.setMetadataObjectsDelegate(nil, queue: nil)
            }
            for output in session.outputs { session.removeOutput(output) }
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
            device = nil
            configured = false
            recent.removeAll()
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: options.position) else {
            throw OriginalNativeCameraError(message: "На этом устройстве нет выбранной камеры.")
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw OriginalNativeCameraError(message: "Не удалось подключить камеру.") }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { throw OriginalNativeCameraError(message: "Не удалось включить распознавание штрихкодов.") }
        session.addOutput(output)
        let available = output.availableMetadataObjectTypes
        let types = OriginalBarcodeOptions.supported.filter { available.contains($0.0) && options.accepts($0.1) }.map { $0.0 }
        guard !types.isEmpty else { throw OriginalNativeCameraError(message: "Камера не поддерживает выбранные форматы штрихкодов.") }
        output.metadataObjectTypes = types
        output.setMetadataObjectsDelegate(self, queue: queue)
        device = camera
        if (try? camera.lockForConfiguration()) != nil {
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            camera.unlockForConfiguration()
        }
        configured = true
    }

    private func run() {
        guard !isCancelled, !paused, !backgrounded else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            fail("Доступ к камере выключен в настройках iPhone."); return
        }
        do {
            if !configured { try configure() }
            guard !isCancelled, !paused, !backgrounded else { return }
            if !session.isRunning { session.startRunning() }
            guard !isCancelled else { stopHardware(); return }
            guard session.isRunning else { fail("Не удалось запустить видеокамеру."); return }
            if !reportedReady {
                reportedReady = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isCancelled else { return }
                    self.onReady?(nil)
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func fail(_ message: String) {
        guard !isCancelled else { return }
        stopHardware()
        let ready = reportedReady
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            if ready { self.onFailure?(message) }
            else { self.onReady?(message) }
        }
    }

    private func stopHardware() {
        if let device, device.hasTorch, device.torchMode != .off, (try? device.lockForConfiguration()) != nil {
            device.torchMode = .off
            device.unlockForConfiguration()
        }
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !isCancelled, !paused, !backgrounded else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var codes: [[String: Any]] = []
        for case let object as AVMetadataMachineReadableCodeObject in metadataObjects {
            guard let barcode = options.barcode(object), let raw = barcode["rawValue"] as? String,
                  let format = barcode["format"] as? String else { continue }
            let key = format + "\u{0}" + raw
            guard now - (recent[key] ?? -.infinity) >= 0.8 else { continue }
            recent[key] = now
            codes.append(barcode)
        }
        if recent.count > 256 { recent = recent.filter { now - $0.value < 5 } }
        guard !codes.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.onCodes?(codes)
        }
    }

    func isTorchAvailable(completion: @escaping @MainActor (Bool) -> Void) {
        queue.async { [self] in
            let available = !isCancelled && device?.hasTorch == true
            DispatchQueue.main.async { completion(available) }
        }
    }

    func getTorchState(completion: @escaping @MainActor (Bool) -> Void) {
        queue.async { [self] in
            let enabled = !isCancelled && session.isRunning && device?.torchMode == .on
            DispatchQueue.main.async { completion(enabled) }
        }
    }

    /// nil toggles the current state.
    func setTorch(_ enabled: Bool?, completion: @escaping @MainActor (String?) -> Void) {
        queue.async { [self] in
            var failure: String?
            do {
                guard !isCancelled, let device, device.hasTorch else {
                    throw OriginalNativeCameraError(message: "У выбранной камеры нет доступного фонарика.")
                }
                let turnOn = enabled ?? (device.torchMode != .on)
                if turnOn, (!session.isRunning || !device.isTorchAvailable || !device.isTorchModeSupported(.on)) {
                    throw OriginalNativeCameraError(message: "Фонарик сейчас недоступен.")
                }
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if turnOn { try device.setTorchModeOn(level: 1) }
                else { device.torchMode = .off }
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async { completion(failure) }
        }
    }
}

@MainActor
private final class OriginalBarcodeCaptureController: UIViewController {
    let capture: OriginalBarcodeCapture
    private var preview: AVCaptureVideoPreviewLayer?
    private var observers: [NSObjectProtocol] = []

    init(options: OriginalBarcodeOptions) {
        capture = OriginalBarcodeCapture(options: options)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        let preview = AVCaptureVideoPreviewLayer(session: capture.session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
        let capture = capture
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            capture.setBackgrounded(true)
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            capture.setBackgrounded(false)
        })
        if UIApplication.shared.applicationState != .active { capture.setBackgrounded(true) }
    }

    deinit {
        capture.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if let connection = preview?.connection, connection.isVideoOrientationSupported {
            switch view.window?.windowScene?.interfaceOrientation {
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
    }
}
