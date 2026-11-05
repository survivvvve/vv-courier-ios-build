import Foundation
import CoreFoundation

/// VV 6.16.1 uses termocontrol.is_need_termocontrol from order/queue
/// responses. It is a JSON boolean, not a task ID or a truthy string.
enum ColdControlSignal {
    static let featureFlag = 227
    static let businessError = 102

    static func required(in response: [String: Any]) -> Bool? {
        required(from: response["termocontrol"])
    }

    static func required(from raw: Any?) -> Bool? {
        guard let control = raw as? [String: Any],
              let value = control["is_need_termocontrol"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
}

struct ColdControlSubmission: Equatable {
    /// An empty upload response acknowledges receipt. Completion is separate:
    /// only false in a subsequent status response confirms restriction removal.
    let requiredAfterUpload: Bool?
    var isComplete: Bool { requiredAfterUpload == false }
}

/// Only the need for a status read is persisted, never a photo or a successful
/// completion. Closing/reopening the sheet must not bypass uncertain-outcome
/// reconciliation after an interrupted upload.
enum ColdControlPendingStore {
    private static func key(_ courierID: String) -> String { "coldcontrol.pending-status." + courierID }
    static func needsStatus(courierID: String) -> Bool { !courierID.isEmpty && UserDefaults.standard.bool(forKey: key(courierID)) }
    static func mark(courierID: String, pending: Bool) {
        guard !courierID.isEmpty else { return }
        if pending { UserDefaults.standard.set(true, forKey: key(courierID)) }
        else { UserDefaults.standard.removeObject(forKey: key(courierID)) }
    }
}

enum ColdControlRequest {
    static func body(photo: Data?, hasPyrometer: Bool, hasColdPacks: Bool) throws -> [String: Any] {
        if hasColdPacks {
            guard let photo, !photo.isEmpty, photo.count <= 4 * 1024 * 1024,
                  photo.starts(with: [0xff, 0xd8]) else {
                throw CourierError(message: "Добавь фотографию хладоэлементов в формате JPEG.")
            }
            return ["photo_file": photo.base64EncodedString().replacingOccurrences(of: "=", with: ""),
                    "pirometr": hasPyrometer, "freeze": true]
        }
        // The official 'no cold packs' branch sends these exact values; it
        // notifies the shop and must be explicitly confirmed by the courier.
        guard photo == nil, hasPyrometer else {
            throw CourierError(message: "Подтверди отсутствие хладоэлементов отдельно от фотографии.")
        }
        return ["photo_file": NSNull(), "pirometr": true, "freeze": false]
    }
}

extension CourierAPI {
    /// Same lightweight catalog read as the official queue module. It includes
    /// the global cold-pack restriction, even when no queue has been selected.
    func coldControlRequired() async throws -> Bool? {
        guard let courierID = session?.courierID, !courierID.isEmpty else {
            throw CourierError(message: "Сначала войди в аккаунт.", statusCode: 401)
        }
        let data = try await dictionary(Self.root + "/v3/courier/queue/clusters/" + courierID)
        return ColdControlSignal.required(in: data)
    }

    func submitColdControl(photo: Data?, hasPyrometer: Bool, hasColdPacks: Bool) async throws -> ColdControlSubmission {
        guard let courierID = session?.courierID, !courierID.isEmpty,
              courierID.allSatisfy(\.isNumber) else {
            throw CourierError(message: "Сначала войди в аккаунт.", statusCode: 401)
        }
        let body = try ColdControlRequest.body(photo: photo, hasPyrometer: hasPyrometer, hasColdPacks: hasColdPacks)
        let response = try await dictionary(Self.root + "/v1/courier/" + courierID + "/freeze_photo", body: body)
        guard response.isEmpty else {
            throw CourierError(message: "ВВ не подтвердил приём фотоконтроля. Обнови статус перед повторной отправкой.")
        }
        // Never turn a readback failure after a successful write into another
        // upload attempt. The caller offers a status-only refresh instead.
        let required = try? await coldControlRequired()
        return ColdControlSubmission(requiredAfterUpload: required ?? nil)
    }
}
