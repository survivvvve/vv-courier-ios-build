import SwiftUI
import WebKit
import SafariServices

/// The courier website owns its navigation, map, orders and payment rules.
/// Native additions share one persistent web view instead of recreating screens.
struct OriginalCourierShell: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var controller = OriginalCourierController()
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                OriginalCourierSurface(controller: controller, model: model)
                if controller.wheelOpen {
                    NavigationStack {
                        WheelView()
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button { controller.closeWheel() } label: { Label("ВВ", systemImage: "chevron.left") }
                                        .accessibilityIdentifier("original.wheel.close")
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button { controller.presented = .settings } label: { Image(systemName: "gearshape") }
                                        .accessibilityLabel("Настройки дополнения")
                                }
                            }
                    }
                    .frame(height: max(0, geometry.size.height - (controller.barVisible ? controller.barHeight : 0)))
                    .background(Palette.background)
                    .accessibilityIdentifier("original.wheel.page")
                }
                if controller.runtimeFailed && !controller.wheelOpen {
                    OriginalWebRecoveryView(controller: controller)
                } else if let failure = controller.failure, !controller.wheelOpen {
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        Text("Не удалось открыть ВВ").font(.headline)
                        Text(failure).font(.subheadline).multilineTextAlignment(.center)
                        Button("Повторить загрузку") { controller.reload() }.buttonStyle(CourierButtonStyle(primary: true))
                        Button("Мои заказы") { controller.openRecoveryOrders() }.buttonStyle(CourierButtonStyle())
                        Button("Колесо") { controller.openWheel() }.buttonStyle(CourierButtonStyle())
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
                        .accessibilityIdentifier("original.web.error")
                } else if controller.loading && !controller.wheelOpen {
                    ProgressView("ВкусВилл Курьер").padding(24).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
            }
        }.background {
            if controller.showsNativeSurface {
                Rectangle().fill(Palette.background).ignoresSafeArea()
            } else {
                Color(uiColor: controller.pageBackground).ignoresSafeArea()
            }
        }
            .sheet(item: $controller.presented) { destination in
                switch destination {
                case .income:
                    IncomeView(onClose: { controller.presented = nil })
                        .modifier(CompanionNotificationOverlay())
                case .settings:
                    NavigationStack { CompanionSettingsView().toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { controller.presented = nil } } } }.modifier(CompanionNotificationOverlay())
                case .recoveryOrders:
                    NavigationStack {
                        OrdersView()
                            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Готово") { controller.presented = nil }.accessibilityIdentifier("original.orders-recovery.close") } }
                    }.modifier(CompanionNotificationOverlay())
                }
            }
            .onChange(of: model.loginPresented) { _, value in
                if value { controller.presented = nil; controller.closeWheel(); controller.navigate("/start/auth"); model.loginPresented = false }
            }
            .onChange(of: model.notificationTarget?.id) { _, _ in controller.openNotification() }
            .alert("Проверки перед сменой", isPresented: Binding(get: { controller.shiftIssue != nil }, set: { if !$0 { controller.shiftIssue = nil } }), presenting: controller.shiftIssue) { issue in
                if issue.phase == .failed && issue.status != 429 {
                    Button("Обновить экран") { controller.shiftIssue = nil; controller.reload() }
                }
                Button("Скопировать код ошибки") { UIPasteboard.general.string = controller.diagnosticReport; controller.shiftIssue = nil }
                Button("Понятно", role: .cancel) { controller.shiftIssue = nil }
            } message: { issue in Text(issue.message) }
            .modifier(CompanionNotificationOverlay())
    }
}

/// The website's React boundary must not strand an already accepted order.
/// Opening this sheet only reads the current feed; mutations keep their existing
/// confirmation, validation and server readback in the native order screens.
private struct OriginalWebRecoveryView: View {
    @ObservedObject var controller: OriginalCourierController
    @State private var copied = false
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Palette.warning)
            Text("Ошибка экрана ВВ").font(.headline)
            Text("Экран ВВ не смог показать заказы. Открой «Мои заказы», чтобы продолжить работу.")
                .font(.subheadline).multilineTextAlignment(.center)
            Button("Мои заказы") { controller.openRecoveryOrders() }
                .buttonStyle(CourierButtonStyle(primary: true)).accessibilityIdentifier("original.recovery.orders")
            Button("Повторить загрузку экрана") { controller.reload() }
                .buttonStyle(CourierButtonStyle()).accessibilityIdentifier("original.recovery.reload")
            Button("Колесо") { controller.openWheel() }
                .buttonStyle(CourierButtonStyle()).accessibilityIdentifier("original.recovery.wheel")
            Button(copied ? "Код ошибки скопирован" : "Скопировать код ошибки") {
                UIPasteboard.general.string = controller.diagnosticReport
                copied = true
            }.font(.subheadline).accessibilityIdentifier("original.recovery.copy")
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("original.web.runtime-error")
    }
}

@MainActor private struct CompanionNotificationOverlay: ViewModifier {
    @ObservedObject private var center = ExpressNotificationCenter.shared
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if !center.foregroundEvents.isEmpty {
                ExpressNotificationBanner()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    .padding(.horizontal, 12).padding(.top, 8)
            }
        }
    }
}

private struct OriginalCourierSurface: UIViewControllerRepresentable {
    let controller: OriginalCourierController
    let model: AppModel
    func makeUIViewController(context: Context) -> OriginalCourierController { controller.attach(model); return controller }
    func updateUIViewController(_ controller: OriginalCourierController, context: Context) {
        Task { @MainActor [weak controller] in controller?.updateWebsiteAppearance() }
    }
}

private struct CompanionSettingsView: View {
    var body: some View {
        CourierPage("Дополнение к ВВ") {
            CourierCard {
                NavigationLink { IncomeView() } label: { CourierMenuRow(title: "Итоги смены", symbol: "chart.bar") }
            }
            CourierCard {
                NavigationLink { WheelSpeedSettingsView() } label: { CourierMenuRow(title: "Поправка скорости", symbol: "speedometer") }
                Divider()
                NavigationLink { WheelDashboardSettingsView() } label: { CourierMenuRow(title: "Плитки телеметрии", symbol: "square.grid.2x2") }
                Divider()
                NavigationLink { WheelAlarmSettingsView() } label: { CourierMenuRow(title: "Звуковые предупреждения", symbol: "speaker.wave.2") }
            }
            HStack(spacing: 4) { Text("Завайбкожено by"); Link("survive", destination: URL(string: "https://t.me/survivee")!) }
                .font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
        }
    }
}

@MainActor final class OriginalCourierController: UIViewController, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Destination: String, Identifiable { case income, settings, recoveryOrders; var id: String { rawValue } }
    @Published var wheelOpen = false { didSet { synchronizePageAppearance() } }
    @Published var loading = true
    @Published var failure: String? { didSet { synchronizePageAppearance() } }
    @Published private(set) var runtimeFailed = false {
        didSet { webView?.accessibilityElementsHidden = runtimeFailed; synchronizePageAppearance() }
    }
    @Published private(set) var pageBackground = UIColor.systemBackground
    @Published var shiftIssue: OriginalShiftReadinessIssue?
    @Published var barVisible = false
    @Published var barHeight: CGFloat = 58
    @Published var presented: Destination? { didSet { synchronizePageAppearance() } }
    private(set) var webView: WKWebView!
    private weak var model: AppModel?
    private var hardware: OriginalCameraBridge?
    private var backgroundObservation: NSKeyValueObservation?
    private weak var appearanceScene: UIWindowScene?
    private var sceneAppearanceObservation: (any UITraitChangeRegistration)?
    private var documentID: String?
    private var pendingToken: String?
    private var candidateSession: Session?
    private var runtime = ""
    private var runtimeReady = false
    private var pendingNotification: (id: UUID, path: String)?
    private var sessionWork: Task<Void, Never>?
    private var fixture: Bool { model?.originalFixture == true }
    var showsNativeSurface: Bool { wheelOpen || runtimeFailed || failure != nil || presented != nil }

    func attach(_ model: AppModel) { self.model = model }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateWebsiteAppearance()
    }

    func updateWebsiteAppearance() {
        guard isViewLoaded, let webView, let scene = view.window?.windowScene else { return }
        if appearanceScene !== scene {
            if let appearanceScene, let sceneAppearanceObservation {
                appearanceScene.unregisterForTraitChanges(sceneAppearanceObservation)
            }
            appearanceScene = scene
            sceneAppearanceObservation = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIWindowScene, _: UITraitCollection) in
                self?.updateWebsiteAppearance()
            }
        }
        // The window follows the page canvas for legible status-bar text.
        // Keep CSS prefers-color-scheme tied to the user's setting/system scene,
        // rather than feeding that window override back into the website.
        let preference = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
        let style: UIUserInterfaceStyle
        switch preference {
        case .light: style = .light
        case .dark: style = .dark
        case .system: style = scene.traitCollection.userInterfaceStyle
        }
        if webView.overrideUserInterfaceStyle != style { webView.overrideUserInterfaceStyle = style }
        refreshPageBackground()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        guard let url = Bundle.main.url(forResource: "OriginalRuntime", withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) else {
            failure = "В сборке отсутствует подключение нативных функций. Переустанови последнюю IPA."; loading = false; return
        }
        guard let diagnosticURL = Bundle.main.url(forResource: "OriginalDiagnostics", withExtension: "js"),
              let diagnosticSource = try? String(contentsOf: diagnosticURL, encoding: .utf8) else {
            failure = "В сборке отсутствует обработка ошибок экрана ВВ. Переустанови последнюю IPA."; loading = false; return
        }
        guard let shiftURL = Bundle.main.url(forResource: "OriginalShiftReadiness", withExtension: "js"),
              let shiftSource = try? String(contentsOf: shiftURL, encoding: .utf8) else {
            failure = "В сборке отсутствует проверка готовности смены. Переустанови последнюю IPA."; loading = false; return
        }
        runtime = diagnosticSource + "\n" + shiftSource + "\n" + source
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(WeakOriginalMessageHandler(self), name: "vvNative")
        if fixture && ProcessInfo.processInfo.arguments.contains("--original-shift-ui-testing") {
            guard let bootstrapURL = Bundle.main.url(forResource: "OriginalShiftFixtureBootstrap", withExtension: "js"),
                  let bootstrap = try? String(contentsOf: bootstrapURL, encoding: .utf8) else {
                failure = "Отсутствует офлайн-проверка смены."; loading = false; return
            }
            configuration.userContentController.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if !fixture, let session = model?.session {
            let json = Self.json(["token": session.token, "courierID": session.courierID])
            // This migration script is removed immediately after the first boot.
            // Logging out on the website must never reimport an old token.
            let seed = "(() => { const seed = \(json); if (!localStorage.getItem('CapacitorStorage.token_courier')) { localStorage.setItem('CapacitorStorage.token_courier', seed.token); } })();"
            configuration.userContentController.addUserScript(WKUserScript(source: seed, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: runtime, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = true; webView.backgroundColor = .systemBackground
        // Follow WebKit's computed page canvas, including SPA theme changes.
        // Do not override underPageBackgroundColor: it must keep tracking HTML.
        backgroundObservation = webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshPageBackground() }
        }
        webView.accessibilityIdentifier = "original.web"
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor), webView.topAnchor.constraint(equalTo: view.topAnchor), webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        configureHardware()
        if fixture && ProcessInfo.processInfo.arguments.contains("--original-offline-ui-testing") {
            failure = "Проверка без сети."; loading = false; return
        }
        if fixture {
            let arguments = ProcessInfo.processInfo.arguments
            let name = arguments.contains("--original-shift-ui-testing") ? "OriginalShiftFixture"
                : arguments.contains("--original-appearance-ui-testing") ? "OriginalAppearanceFixture" : "OriginalFixture"
            guard let html = Bundle.main.url(forResource: name, withExtension: "html") else {
                failure = "Отсутствует проверочный экран."; loading = false; return
            }
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        } else { webView.load(URLRequest(url: URL(string: "https://courier.vkusvill.ru/start")!)) }
    }

    private func configureHardware() {
        hardware?.invalidate()
        hardware = OriginalCameraBridge(presenter: self, webView: webView)
        hardware?.reply = { [weak self] callbackID, success, data, error, keepAlive in
            var value: [String: Any] = ["callbackID": callbackID, "success": success, "keepAlive": keepAlive]
            if let data { value["data"] = data }; if let error { value["error"] = error }
            self?.send(value)
        }
    }

    private func refreshPageBackground() {
        guard let webView else { return }
        let color = (webView.underPageBackgroundColor ?? UIColor.systemBackground).resolvedColor(with: webView.traitCollection)
        if !pageBackground.isEqual(color) { pageBackground = color }
        view.backgroundColor = color
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        synchronizePageAppearance()
    }

    private func synchronizePageAppearance() {
        guard let model else { return }
        let scheme: ColorScheme? = showsNativeSurface ? nil : (pageBackground.relativeLuminance < 0.179 ? .dark : .light)
        if model.webColorScheme != scheme { model.webColorScheme = scheme }
    }

    func openWheel() { if !wheelOpen { wheelOpen = true }; evaluate("window.__vvCompanion?.setWheel(true)") }
    func closeWheel() { if wheelOpen { wheelOpen = false }; evaluate("window.__vvCompanion?.setWheel(false)") }
    func navigate(_ path: String) {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\") else { return }
        if runtimeFailed && !fixture {
            runtimeFailed = false
            loading = true
            guard let url = URL(string: "https://courier.vkusvill.ru" + path), trusted(url) else { return }
            webView.load(URLRequest(url: url))
            return
        }
        evaluate("window.__vvCompanion?.navigate(\(Self.json(path)))")
    }
    func reload() { guard webView != nil else { return }; failure = nil; runtimeFailed = false; loading = true; webView.reload() }
    func openRecoveryOrders() {
        model?.selectedFeed = .mine
        closeWheel()
        presented = .recoveryOrders
    }
    var diagnosticReport: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return "VV Courier " + version + "\n" + OriginalWebDiagnostics.shared.reportText
    }
    func openNotification() {
        guard let target = model?.notificationTarget, target.courierID == model?.session?.courierID else { return }
        presented = nil
        closeWheel()
        var destination = URLComponents()
        destination.path = "/order"
        destination.queryItems = [URLQueryItem(name: "type", value: target.kind == .ready ? "done" : "prepare"), URLQueryItem(name: "id_parcel", value: target.parcelID)]
        guard let path = destination.string else { return }
        pendingNotification = (target.id, path)
        if runtimeReady { navigate(path) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, trusted(message.frameInfo.request.url),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let incomingDocument = body["documentID"] as? String, incomingDocument.count < 150 else { return }
        // A late diagnostic/plugin reply from the previous page cannot claim a
        // new navigation. Only its document-start boot establishes identity.
        if kind == "boot" { documentID = incomingDocument; runtimeFailed = false }
        guard documentID == incomingDocument else { return }
        // Token migration runs once; future navigations get only the bridge.
        if kind == "boot" || kind == "ready" {
            userContentController.removeAllUserScripts()
            userContentController.addUserScript(WKUserScript(source: runtime, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        switch kind {
        case "shift-readiness":
            guard let raw = body["phase"] as? String, let phase = OriginalShiftReadinessIssue.Phase(rawValue: raw) else { return }
            var value: [String: Any] = ["kind": "diagnostic", "category": phase == .loading ? "shift_checks_loading" : "shift_checks_failed",
                "fatal": false, "path": webView.url?.path ?? "/<other>"]
            if let status = body["status"] { value["httpStatus"] = status }
            guard let event = OriginalWebDiagnostics.shared.record(value) else { return }
            shiftIssue = OriginalShiftReadinessIssue(phase: phase, status: event.httpStatus)
        case "diagnostic":
            if let event = OriginalWebDiagnostics.shared.record(body), event.fatal {
                runtimeFailed = true
                loading = false
                barVisible = false
            }
        case "ready": loading = false; failure = nil; runtimeReady = true; openNotification()
        case "navigation":
            let visible = body["barVisible"] as? Bool ?? false
            if visible != barVisible { barVisible = visible }
            let height = CGFloat(number(body["barHeight"]))
            if height.isFinite, (44...150).contains(height), abs(height - barHeight) > 0.5 { barHeight = height }
            if let pendingNotification, body["path"] as? String == pendingNotification.path,
               model?.notificationTarget?.id == pendingNotification.id {
                model?.notificationTarget = nil; self.pendingNotification = nil
            }
        case "action":
            switch body["action"] as? String {
            case "wheel": openWheel()
            case "courier": closeWheel()
            case "income": presented = .income
            case "settings": presented = .settings
            default: break
            }
        case "plugin":
            guard let plugin = body["plugin"] as? String, let method = body["method"] as? String,
                  let callbackID = body["callbackID"] as? String, callbackID.hasPrefix(incomingDocument + ":"), callbackID.count < 200 else { return }
            let handled = hardware?.handle(plugin: plugin, method: method, options: body["options"] as? [String: Any] ?? [:], callbackID: callbackID) ?? false
            if !handled { send(["callbackID": callbackID, "success": false, "error": "Эта нативная функция пока не поддерживается.", "code": "UNIMPLEMENTED"]) }
        case "session":
            if let token = body["token"] as? String, let id = body["courierID"] as? String, !token.isEmpty, token.count < 32_768, !id.isEmpty, id.allSatisfy(\.isNumber) {
                candidateSession = Session(token: token, courierID: id)
                if pendingToken == token { accept(candidateSession!) }
            }
        case "token": observeToken(body["token"] as? String ?? "")
        case "account": observeAccount(body)
        default: break
        }
    }

    private func observeToken(_ token: String) {
        guard !fixture, let model, token.count < 32_768 else { return }
        pendingToken = token
        if token.isEmpty {
            sessionWork?.cancel(); candidateSession = nil
            if model.session != nil { model.logout() }
            return
        }
        if model.session?.token == token { return }
        // The website may have switched accounts. Stop old-account polling and
        // reports immediately, even if discovering the new profile later fails.
        model.logout(); presented = nil; pendingNotification = nil
        if let candidateSession, candidateSession.token == token { accept(candidateSession); return }
        sessionWork?.cancel()
        // Recover an existing website session without sending an SMS. The server
        // profile, not an old account ID, determines ownership of an imported token.
        sessionWork = Task { [weak self] in
            do {
                let profile = try await CourierAPI(session: Session(token: token, courierID: "unresolved")).profile()
                guard let self, !Task.isCancelled, self.pendingToken == token else { return }
                let id = firstAddressText(profile["id_courier"], profile["courier_id"], profile["id"])
                guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return }
                self.accept(Session(token: token, courierID: id))
            } catch { /* The website presents its own login state; never request a code here. */ }
        }
    }
    private func accept(_ session: Session) {
        guard !fixture, pendingToken == session.token, let model else { return }
        do {
            if model.session?.token != session.token || model.session?.courierID != session.courierID { try model.finishLogin(session) }
            Task { await model.bootstrap() }
        } catch { model.handle(error) }
    }
    private func observeAccount(_ body: [String: Any]) {
        guard !fixture, let model, let token = body["token"] as? String, !token.isEmpty,
              token == pendingToken, let data = body["data"] as? [String: Any] else { return }
        if model.session == nil, body["endpoint"] as? String == "/v1/courier/courier" {
            let id = firstAddressText(data["id_courier"], data["courier_id"], data["id"])
            if !id.isEmpty, id.allSatisfy(\.isNumber) { accept(Session(token: token, courierID: id)) }
        }
        guard model.session?.token == token else { return }
        switch body["endpoint"] as? String {
        case "/v1/courier/activity":
            let status = string(data["res"])
            if status == "0" || status == "1" { model.observeWebsiteActivity(status == "1") }
        case "/v1/courier/courier": model.profile = data
        case "/v1/courier/shops":
            if let shops = data["shops"] as? [[String: Any]] { model.shops = shops.filter { !truth($0["invisible"]) }.compactMap(Shop.init) }
        default: break
        }
    }
    private func trusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme == "https", url.host == "courier.vkusvill.ru" { return true }
        return fixture && url.isFileURL && url.path.hasPrefix(Bundle.main.bundlePath + "/")
    }
    private func evaluate(_ source: String) { guard webView != nil else { return }; webView.evaluateJavaScript(source, completionHandler: nil) }
    private func send(_ message: [String: Any]) {
        // The receiver is synchronous. The classic API also avoids the
        // libswiftWebKit overlay launch failure in iOS 18.5 simulators.
        evaluate("window.__vvNativeReceive?.(\(Self.json(message)))")
    }
    fileprivate static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        documentID = nil; runtimeReady = false; runtimeFailed = false; shiftIssue = nil; configureHardware(); loading = true; failure = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; failure = nil; refreshPageBackground() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) { if (error as NSError).code != NSURLErrorCancelled { loading = false; failure = error.localizedDescription } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { hardware?.invalidate(); reload() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false, !trusted(url), url.scheme != "about" {
            decisionHandler(.cancel); openExternal(url); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { if trusted(url) { webView.load(navigationAction.request) } else { openExternal(url) } }
        return nil
    }
    private func openExternal(_ url: URL) {
        if url.scheme == "https" || url.scheme == "http" { present(SFSafariViewController(url: url), animated: true) }
        else if ["tel", "mailto", "tg", "vkusvill", "sberbankonline", "bank100000000111"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: "ВкусВилл", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Понятно", style: .default) { _ in completionHandler() }); present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "ВкусВилл", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Подтвердить", style: .default) { _ in completionHandler(true) }); present(alert, animated: true)
    }
}

struct OriginalShiftReadinessIssue: Identifiable {
    enum Phase: String { case loading, failed }
    let id = UUID()
    let phase: Phase
    let status: Int?
    var message: String {
        if phase == .loading {
            return "ВВ ещё загружает обязательные проверки. Подожди несколько секунд и нажми кнопку начала смены снова."
        }
        if status == 429 { return "ВВ ограничил частоту запросов проверок. Подожди перед повторной попыткой. Код ответа: 429." }
        let code = status.map { $0 == 0 ? " Сетевой запрос не завершился." : " Код ответа: \($0)." } ?? ""
        return "Не удалось загрузить обязательные проверки ВВ. Проверь связь и обнови экран. Смена автоматически не запускается." + code
    }
}

private final class WeakOriginalMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: OriginalCourierController?
    init(_ target: OriginalCourierController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(userContentController, didReceive: message) }
}
