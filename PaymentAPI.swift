import Foundation

extension CourierAPI {
    /// SBER terminal/QR is confirmation of an already successful physical
    /// terminal transaction. This call neither launches nor fakes acquiring.
    func completeDelivery(_ id: String, confirmation: DeliveryPaymentConfirmation?) async throws -> DeliveryCompletion {
        let mine = try await feed(.mine)
        guard mine.parcels.contains(where: { $0.id == id }) else { throw CourierError(message: "Заказ больше не находится в «Мои». Обнови список.") }
        let parcel = try await parcel(id)
        guard ["on_the_way", "arrived"].contains(parcel.status) else { throw CourierError(message: "Статус изменился. Обнови заказ.") }
        guard integer(parcel.raw["pay_way"]) != 9 else { throw CourierError(message: "Проверка оплаты по ссылке пока не поддерживается. Завершение недоступно, способ оплаты не изменён.") }
        try await verifyPosition(parcel: parcel, action: "deliver")
        try await verifyPackageInspection(parcelID: id, after: true)
        let terminal = confirmation?.method == .cash || confirmation == nil ? [:] : try await terminalStatus()
        let flags = confirmation?.method == .cash ? try await taskFlags() : []
        let body = try DeliveryPaymentRules.completionBody(parcel: parcel.raw, courierID: session?.courierID ?? "", confirmation: confirmation, terminal: terminal, flags: flags)
        do {
            try await expectEmpty(Self.root + "/v3/courier/change_task_status", body: body)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // A network timeout does not prove rejection. This parcel was just
            // verified in this account's My feed; read its state, never re-send.
            let failure = error as? CourierError
            if failure?.statusCode == nil || (failure?.statusCode ?? 0) >= 500 {
                if let readback = try? await self.parcel(id), readback.id == id, readback.status == "delivered" {
                    let actual: Int?
                    if DeliveryPaymentRules.usesPaidCollectionBranch(parcel.raw) {
                        actual = DeliveryPaymentRules.actualPaymentWay(readback.raw) ?? DeliveryPaymentRules.actualPaymentWay(parcel.raw)
                    } else {
                        let way = integer(firstAddressText(readback.raw["pay_way_fact"], readback.raw["pay_way"]))
                        actual = way.flatMap { [0, 1, 2, 3, 4, 5, 9].contains($0) ? $0 : nil }
                    }
                    return DeliveryCompletion(parcelID: id, payWay: actual)
                }
                throw CourierError(message: "Не удалось подтвердить ответ ВВ. Заказ мог быть закрыт: обнови «Мои» или архив, не подтверждай оплату повторно. Фото чека доступно в полной карточке архива.", statusCode: failure?.statusCode)
            }
            throw error
        }
        if DeliveryPaymentRules.usesPaidCollectionBranch(parcel.raw) {
            // A6e's legacy pay_way4 does not establish the actual paid method.
            // A failed read cannot turn an acknowledged close into another close.
            let readback = try? await self.parcel(id)
            let actual = readback.flatMap { $0.id == id && $0.status == "delivered" ? DeliveryPaymentRules.actualPaymentWay($0.raw) : nil }
                ?? DeliveryPaymentRules.actualPaymentWay(parcel.raw)
            return DeliveryCompletion(parcelID: id, payWay: actual)
        }
        // An empty v3 response is the same successful acknowledgement used by
        // the official client. Do not re-close if a subsequent list refresh fails.
        return DeliveryCompletion(parcelID: id, payWay: Int(number(body["pay_way"])))
    }

    func uploadReceiptPhoto(_ jpeg: Data) async throws -> String {
        guard !jpeg.isEmpty, jpeg.count <= 8 * 1024 * 1024 else { throw CourierError(message: "Фото слишком большое. Сделай новый снимок.") }
        let result = try await dictionary(Self.root + "/v1/courier/upload_parcel_receipt_photo", body: ["file": jpeg.base64EncodedString().replacingOccurrences(of: "=", with: ""), "format": "jpeg", "id_courier": session?.courierID ?? ""])
        let id = string(result["id"])
        guard !id.isEmpty, id != "0" else { throw CourierError(message: "ВВ не подтвердил загрузку фото.") }
        return id
    }
    func attachReceiptPhotos(parcelID: String, uploadedIDs: [String]) async throws -> [ReceiptPhoto] {
        guard !uploadedIDs.isEmpty, uploadedIDs.count <= 10, uploadedIDs.allSatisfy({ !$0.isEmpty }) else { throw CourierError(message: "Сначала добавь фото чека.") }
        let ids: [Any] = uploadedIDs.map { Int64($0).map { $0 as Any } ?? $0 }
        let result = try await dictionary(Self.root + "/v1/courier/change_parcel_receipt_photos", body: ["id_courier": session?.courierID ?? "", "id_parcel": parcelID, "add": ids, "remove": []])
        guard let rows = result["check_photo"] as? [[String: Any]] else { throw CourierError(message: "ВВ не подтвердил прикрепление фото. Черновик сохранён: обнови фото перед повтором.") }
        let photos = rows.compactMap(ReceiptPhoto.init)
        let saved = Set(photos.map(\.id))
        guard uploadedIDs.allSatisfy(saved.contains) else { throw CourierError(message: "ВВ не подтвердил все фото. Черновик сохранён: обнови список фото перед повтором.") }
        return photos
    }
}
