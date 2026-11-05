import Foundation
import CoreLocation

struct GeoPoint {
    let latitude: Double
    let longitude: Double
    init?(_ raw: [String: Any], latitudeKeys: [String] = ["latitude", "lat", "shop_lat"], longitudeKeys: [String] = ["longitude", "lon", "lng", "shop_lon"]) {
        guard let latitude = latitudeKeys.lazy.compactMap({ Double(string(raw[$0])) }).first(where: { $0.isFinite && (-90...90).contains($0) }),
              let longitude = longitudeKeys.lazy.compactMap({ Double(string(raw[$0])) }).first(where: { $0.isFinite && (-180...180).contains($0) }),
              !(latitude == 0 && longitude == 0) else { return nil }
        self.latitude = latitude; self.longitude = longitude
    }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

@MainActor final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?
    private var requestID: UUID?
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest }
    func position() async throws -> CLLocation {
        try Task.checkCancellation()
        guard continuation == nil else { throw CourierError(message: "Определение позиции уже выполняется.") }
        guard CLLocationManager.locationServicesEnabled() else { throw CourierError(message: "Включи службы геолокации на iPhone, чтобы подтвердить нахождение у адреса.") }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { pending in
            requestID = id
            continuation = pending
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.finish(.failure(CourierError(message: "Не удалось получить свежую точную позицию. Подойди к открытому месту и повтори.")))
            }
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
            default: finish(.failure(CourierError(message: "Разреши геопозицию для VV Courier в настройках iPhone.")))
            }
        }
        }, onCancel: { [self] in
            Task { @MainActor [self] in
                guard self.requestID == id else { return }
                self.finish(.failure(CancellationError()))
            }
        })
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.authorizationChanged() }
    }
    private func authorizationChanged() {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finish(.failure(CourierError(message: "Геопозиция не разрешена. Измени доступ в настройках iPhone.")))
        default: break
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.received(locations) }
    }
    private func received(_ locations: [CLLocation]) {
        guard let location = locations.filter({ $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100 && abs($0.timestamp.timeIntervalSinceNow) <= 30 }).last else { return }
        finish(.success(location))
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.finish(.failure(CourierError(message: "Не удалось определить геопозицию. Проверь разрешение и связь GPS."))) }
    }
    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel(); timeout = nil
        requestID = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}

extension CourierAPI {
    func verifyPosition(parcel: Parcel, action: String) async throws {
        let response = try await dictionary(Self.root + "/v1/courier/shops")
        guard let shops = response["shops"] as? [[String: Any]], let shop = shops.first(where: { string($0["shopno"]) == string(parcel.raw["shopno"]) }) else { throw CourierError(message: "Не удалось проверить правила магазина этого заказа.") }
        let key = ["take": "get_order_check", "arrived": "arrive_order_check", "deliver": "done_order_check", "returned": "return_order_check"][action]
        guard let key, truth(shop[key]) else { return }
        if action == "arrived", !(try await taskFlags()).contains(302) { return }
        let position = try await LocationService.shared.position()
        if action == "take" { return }
        let address = parcel.raw["delivery_address"] as? [String: Any] ?? [:]
        let target = action == "returned" ? GeoPoint(shop) : GeoPoint(parcel.raw) ?? GeoPoint(address)
        guard let target else { throw CourierError(message: "В заказе нет координат для геопроверки. Уточни адрес через поддержку ВВ.") }
        guard position.distance(from: target.location) <= 500 else { throw CourierError(message: action == "returned" ? "Подойди к магазину: для возврата нужно быть в пределах 500 м." : "Подойди к адресу заказа: для этого действия нужно быть в пределах 500 м.") }
    }
}
