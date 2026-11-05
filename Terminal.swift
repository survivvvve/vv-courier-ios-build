import SwiftUI
import CoreImage.CIFilterBuiltins

extension CourierAPI {
    func terminalStatus() async throws -> [String: Any] {
        let result = try await dictionary(Self.root + "/v1/courier/terminal/getreturn", body: ["courier_id": session?.courierID ?? "", "only_check": 1, "is_ios": 1])
        guard integer(result["res"]) != nil else { throw CourierError(message: "Неизвестный ответ при проверке терминала.") }
        return result
    }
    func checkedTerminal(qr: String) async throws -> [String: Any] {
        guard !qr.isEmpty, qr.count <= 2048, let escaped = qr.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw CourierError(message: "Некорректный QR-код.") }
        let result = try await dictionary(Self.root + "/v1/courier/terminal/qr-code-check/" + escaped)
        guard result["res"].map({ integer($0) != nil }) ?? true, integer(result["res"]) != -1, !string(result["terminal_id"]).isEmpty, string(result["terminal_id"]) != "0", (integer(result["shopno"]) ?? 0) > 0 else { throw CourierError(message: "ВВ не распознал терминал. Проверь QR-код.") }
        return result
    }
    func receiveTerminal(qr: String) async throws {
        let current = try await terminalStatus()
        guard number(current["res"]) >= 1, string(current["terminal_id"]).isEmpty || string(current["terminal_id"]) == "0" else { throw CourierError(message: "ВВ не разрешил получение. Обнови статус терминала.") }
        let checked = try await checkedTerminal(qr: qr)
        guard let shop = Int(string(checked["shopno"])), shop > 0 else { throw CourierError(message: "ВВ не сообщил магазин терминала. Проверь код и обнови данные.") }
        let result = try await dictionary(Self.root + "/v1/courier/terminal/getreturn", body: ["courier_id": session?.courierID ?? "", "terminal_id": checked["terminal_id"]!, "shopno": shop, "only_check": 0, "is_ios": 1])
        guard number(result["res"]) == 1 else { throw CourierError(message: "ВВ не подтвердил получение. Обнови статус перед повтором.") }
        let updated = try await terminalStatus()
        guard string(updated["terminal_id"]) == string(checked["terminal_id"]), [0, 2].contains(integer(updated["res"]) ?? -1) else { throw CourierError(message: "Запрос принят, но назначение пока не подтверждено. Обнови статус; не повторяй получение сразу.") }
    }
    func returnTerminalQR() async throws -> String {
        let state = try await terminalStatus()
        let id = string(state["terminal_id"])
        guard [0, 2].contains(integer(state["res"]) ?? -1), !id.isEmpty, id != "0" else { throw CourierError(message: "За тобой не закреплён терминал.") }
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw CourierError(message: "Некорректный номер терминала.") }
        let result = try await dictionary(Self.root + "/v1/courier/terminal/qr-code-get/" + escaped)
        guard let qr = result["qrcode"] as? String, !qr.isEmpty else { throw CourierError(message: "ВВ не выдал код сдачи.") }
        return qr
    }
}

struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    @State private var assignment: [String: Any]?
    @State private var failure: String?
    @State private var loading = false
    @State private var loadID = UUID()
    @State private var loadedIdentity = ""
    @State private var qr = ""
    @State private var returnCode: String?
    @State private var receiveConfirmation = false
    @State private var scanning = false
    private var assigned: Bool {
        guard let assignment else { return false }
        let id = string(assignment["terminal_id"])
        return [0, 2].contains(integer(assignment["res"]) ?? -1) && !id.isEmpty && id != "0"
    }
    var body: some View {
        CourierPage("Терминал", subtitle: "Получение и сдача оборудования", artwork: 3) {
            if model.demo { DemoBanner() }
            if loading { CourierCard { ProgressView("Проверяем терминал…").frame(maxWidth: .infinity) } }
            if let failure { CourierErrorCard(message: failure) { Task { await refresh() } } }
            if let assignment {
                CourierCard {
                    Image(systemName: "creditcard").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(Palette.muted)
                    Text(assigned ? "Терминал закреплён" : "Терминал не назначен").font(.title3.weight(.semibold))
                    if assigned {
                        Text("№" + string(assignment["terminal_id"])).font(.headline).monospacedDigit()
                        if let shop = assignment["shopno"] { Text("Магазин №" + string(shop)).font(.subheadline).foregroundStyle(Palette.muted) }
                    }
                    if !assigned { Text("Отсканируй код терминала, который выдали тебе на магазине.").font(.subheadline).foregroundStyle(Palette.muted) }
                }
                if !assigned {
                    CourierCard("Получение") {
                        Button { scanning = true } label: { Label("Сканировать QR", systemImage: "qrcode.viewfinder") }.buttonStyle(CourierButtonStyle(primary: true)).disabled(model.busy)
                        DisclosureGroup("Ввести код вручную") {
                            TextField("Содержимое QR-кода", text: $qr).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12).background(Palette.field, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 8)
                        }.font(.subheadline)
                        if !qr.isEmpty { Label("Код считан", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Palette.success) }
                        Button("Подтвердить получение") { receiveConfirmation = true }.buttonStyle(CourierButtonStyle()).disabled(qr.isEmpty || model.busy)
                    }
                } else {
                    CourierCard("Сдача на магазин") {
                        Text("Покажи код сотруднику магазина. После приёма обнови статус терминала.").font(.subheadline).foregroundStyle(Palette.muted)
                        Button("Показать QR для сдачи") {
                            let client = model.api, identity = model.identity, demo = model.demo
                            model.perform {
                                let code = demo ? "DEMO-ONLY-NOT-VALID" : try await client.returnTerminalQR()
                                guard model.identity == identity, !Task.isCancelled else { return }; returnCode = code
                            }
                        }.buttonStyle(CourierButtonStyle(primary: true)).disabled(model.busy)
                        if let returnCode, let image = qrImage(returnCode) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12)).frame(maxWidth: .infinity)
                            if model.demo { Text("Демонстрационный код не действителен").font(.caption).foregroundStyle(Palette.muted) }
                        }
                    }
                }
            }
            Button("Обновить статус") { Task { await refresh() } }.buttonStyle(CourierButtonStyle()).disabled(model.busy || loading)
        }.navigationTitle("Терминал").navigationBarTitleDisplayMode(.inline).modifier(CourierErrors())
            .task(id: model.identity) {
                if loadedIdentity != model.identity {
                    loadedIdentity = model.identity; loadID = UUID(); loading = false
                    assignment = nil; returnCode = nil; qr = ""; scanning = false; receiveConfirmation = false
                }
                await refresh()
            }.refreshable { await refresh() }
            .confirmationDialog("Подтвердить получение терминала?", isPresented: $receiveConfirmation, titleVisibility: .visible) {
                Button("Получить") {
                    let client = model.api, code = qr, identity = model.identity, demo = model.demo
                    model.perform {
                        guard identity == model.identity, !Task.isCancelled else { return }
                        if demo { assignment = ["terminal_id": "DEMO-001", "shopno": model.selectedShopID ?? 101, "res": 2] }
                        else { try await client.receiveTerminal(qr: code); guard identity == model.identity, !Task.isCancelled else { return }; await refresh() }
                        guard identity == model.identity, !Task.isCancelled else { return }
                        qr = ""
                    }
                }
            }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScanner(onCode: { qr = $0; scanning = false }, onError: { model.error = $0; scanning = false })
                        .navigationTitle("QR терминала").toolbar { Button("Отмена") { scanning = false } }.modifier(CourierErrors())
                }
            }
    }
    private func refresh() async {
        let id = UUID(), identity = model.identity, client = model.api
        loadID = id; loading = true; failure = nil
        defer { if loadID == id { loading = false } }
        if model.demo { if assignment == nil { assignment = ["terminal_id": "", "res": 1] }; return }
        do { let updated = try await client.terminalStatus(); guard loadID == id, model.identity == identity, !Task.isCancelled else { return }; assignment = updated; if !assigned { returnCode = nil } }
        catch is CancellationError { }
        catch { guard loadID == id, model.identity == identity else { return }; failure = error.localizedDescription; assignment = nil; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } }
    }
    private func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: image)
    }
}
