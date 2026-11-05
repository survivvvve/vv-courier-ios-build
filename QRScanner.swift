import SwiftUI
import AVFoundation
import UIKit

/// One-shot remains the default for terminal/queue QR. Package inspection opts
/// into continuous capture and pauses delivery of codes while VV is responding.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void
    var continuous = false
    var paused = false
    var restartToken = 0
    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode; controller.onError = onError
        controller.continuous = continuous; controller.paused = paused
        return controller
    }
    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onCode = onCode; controller.onError = onError
        controller.continuous = continuous; controller.paused = paused
        controller.rearm(token: restartToken)
    }
    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) { controller.stop() }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var continuous = false
    var paused = false
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "vvcourier.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var configured = false
    private var configuring = false
    private var delivered = false
    private var visible = false
    private var gate = ScannerCodeGate()
    private var restartToken = 0
    private var observers: [NSObjectProtocol] = []
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.authorizeAndStart() })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: capture, queue: .main) { [weak self] note in
            guard let self, self.visible else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            if error?.code == .mediaServicesWereReset { self.start() }
            else { self.onError?("Камера временно недоступна. Закрой сканер и открой снова.") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: capture, queue: .main) { [weak self] _ in
            guard let self, self.visible else { return }
            self.onError?("Сканирование прервано: камера занята другим приложением. Вернись в сканер после завершения звонка или записи.")
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: capture, queue: .main) { [weak self] _ in self?.authorizeAndStart() })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); visible = true; authorizeAndStart()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); visible = false; stop()
    }
    private func authorizeAndStart() {
        guard visible, UIApplication.shared.applicationState == .active else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            guard !configuring else { return }; configuring = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }; self.configuring = false
                    guard self.visible else { return }
                    if granted { self.configure() }
                    else { self.onError?("Разреши доступ к камере: Настройки iPhone → VV Courier → Камера. После этого снова открой сканер.") }
                }
            }
        default: onError?("Доступ к камере выключен. Разреши его: Настройки iPhone → VV Courier → Камера.")
        }
    }
    private func configure() {
        if configured { start(); return }
        guard !configuring else { return }; configuring = true
        queue.async { [weak self] in
            guard let self else { return }
            self.capture.beginConfiguration()
            var failure: String?
            do {
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video) else { throw CourierError(message: "На этом устройстве нет доступной камеры.") }
                let input = try AVCaptureDeviceInput(device: camera)
                guard self.capture.canAddInput(input) else { throw CourierError(message: "Камера занята или недоступна.") }
                self.capture.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard self.capture.canAddOutput(output) else { throw CourierError(message: "Не удалось запустить распознавание QR.") }
                self.capture.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                guard output.availableMetadataObjectTypes.contains(.qr) else { throw CourierError(message: "Камера не поддерживает распознавание QR.") }
                output.metadataObjectTypes = [.qr]
            } catch { failure = error.localizedDescription }
            if failure != nil {
                for input in self.capture.inputs { self.capture.removeInput(input) }
                for output in self.capture.outputs { self.capture.removeOutput(output) }
            }
            self.capture.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.configuring = false
                if let failure { self.onError?(failure); return }
                self.configured = true
                let preview = AVCaptureVideoPreviewLayer(session: self.capture)
                preview.videoGravity = .resizeAspectFill
                self.view.layer.insertSublayer(preview, at: 0); self.preview = preview
                preview.frame = self.view.bounds
                self.start()
            }
        }
    }
    private func start() {
        guard visible, configured, !delivered, UIApplication.shared.applicationState == .active else { return }
        queue.async { [capture] in if !capture.isRunning { capture.startRunning() } }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds
        if let connection = preview?.connection, connection.isVideoOrientationSupported {
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            connection.videoOrientation = orientation == .landscapeLeft ? .landscapeLeft : orientation == .landscapeRight ? .landscapeRight : orientation == .portraitUpsideDown ? .portraitUpsideDown : .portrait
        }
    }
    func rearm(token: Int) {
        guard token != restartToken else { return }; restartToken = token
        gate = ScannerCodeGate(); delivered = false; authorizeAndStart()
    }
    func stop() { queue.async { [capture] in if capture.isRunning { capture.stopRunning() } } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard visible, !paused, !delivered, UIApplication.shared.applicationState == .active else { return }
        guard let raw = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
              let code = gate.accept(raw, now: ProcessInfo.processInfo.systemUptime) else { return }
        if !continuous { delivered = true; stop() }
        onCode?(code)
    }
}
