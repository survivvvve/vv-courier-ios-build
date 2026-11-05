import SwiftUI
import MapKit
import UIKit

extension ParcelCoordinate {
    var mapKitCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

func parcelMapColor(_ name: String) -> Color { Color(uiColor: parcelMapUIColor(name)) }

private func parcelMapUIColor(_ name: String) -> UIColor {
    let value = UInt64(ParcelMapColors.hex(name).dropFirst(), radix: 16) ?? 0x187BCC
    return UIColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
}

private struct CourierMapPoint: Identifiable {
    let id: String
    let parcelID: String?
    let shopID: Int?
    let coordinate: ParcelCoordinate
    let text: String
    let colorName: String
    let title: String
    var isShop: Bool { parcelID == nil }
}

/// The map is a fixed sibling of the order scroll view. No SwiftUI button or
/// custom gesture recognizer is placed over a pin: MKMapView owns taps, pans and
/// two-finger zoom, including gestures which begin on an annotation.
struct OrdersInlineMap: View {
    @EnvironmentObject private var model: AppModel
    let entries: [ParcelMapEntry]
    let mapShops: [[String: Any]]
    let cameraScope: String
    let loading: Bool
    let dataIsCurrent: Bool
    @Binding var selectedID: String?
    @State private var fitRequest = 0
    @StateObject private var cameraMemory = CourierMapCameraMemory()

    private var points: [CourierMapPoint] {
        var result = entries.compactMap { entry -> CourierMapPoint? in
            guard let coordinate = entry.coordinate else { return nil }
            return CourierMapPoint(id: "order:" + entry.id, parcelID: entry.id, shopID: entry.parcel.shopID, coordinate: coordinate, text: String(entry.number), colorName: entry.colorName, title: "Заказ " + entry.parcel.fullNumber + ", " + entry.parcel.address)
        }
        var shopsSeen = Set<String>()
        for raw in mapShops {
            let id = firstAddressText(raw["shopno"], raw["shop_number"], raw["ShopNO"], raw["id"])
            guard !id.isEmpty, !shopsSeen.contains(id), let coordinate = ParcelCoordinate(raw) else { continue }
            shopsSeen.insert(id)
            let shopColor = Int(id).flatMap { number in model.shops.first { $0.id == number }?.color }
            result.append(CourierMapPoint(id: "shop:" + id, parcelID: nil, shopID: Int(id), coordinate: coordinate, text: "№ " + id, colorName: firstAddressText(raw["color"], raw["colour_tt"], shopColor, "green"), title: "Магазин " + id))
        }
        // The shop list is available before the first order feed, and still
        // contains a location when an empty feed omits its map block entirely.
        for shop in model.shops where model.selectedShopID == nil || model.selectedShopID == shop.id {
            guard !shopsSeen.contains(String(shop.id)), let coordinate = shop.mapCoordinate else { continue }
            shopsSeen.insert(String(shop.id))
            result.append(CourierMapPoint(id: "shop:\(shop.id)", parcelID: nil, shopID: shop.id, coordinate: coordinate, text: "№ \(shop.id)", colorName: shop.color ?? "green", title: "Магазин \(shop.id)"))
        }
        return result
    }
    private var missingCount: Int { entries.filter { $0.coordinate == nil }.count }
    private var canFit: Bool {
        guard dataIsCurrent else { return false }
        if points.contains(where: { !$0.isShop }) { return true }
        if let selected = model.selectedShopID { return points.contains { $0.isShop && $0.shopID == selected } }
        return !points.isEmpty
    }

    var body: some View {
        ZStack {
            NativeCourierMap(points: points, selectedID: $selectedID, cameraScope: cameraScope, fitRequest: fitRequest, selectedShopID: model.selectedShopID, preferredShopID: model.shops.first(where: \.active)?.id, dataIsCurrent: dataIsCurrent, memory: cameraMemory)
                .overlay(alignment: .topTrailing) {
                    Button { fitRequest += 1 } label: {
                        Label("Показать все", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.weight(.semibold)).padding(.horizontal, 8).frame(height: 30)
                    }.buttonStyle(.plain).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                        .padding(6).disabled(!canFit).accessibilityLabel("Показать все заказы текущей вкладки")
                }
                .overlay(alignment: .bottomLeading) {
                    Group {
                        if loading { Label("Обновляем…", systemImage: "arrow.clockwise") }
                        else if points.isEmpty { Text(entries.isEmpty ? "Заказов пока нет" : "ВВ не передал координаты") }
                        else if entries.isEmpty { Text("Заказов пока нет") }
                        else if missingCount > 0 { Text("Без координат: \(missingCount)") }
                    }.font(.caption2).padding(.horizontal, 8).padding(.vertical, 5).background(Palette.surface, in: Capsule()).padding(8).allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 0.7))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orders.map.inline")
    }
}

private struct NativeCourierMap: UIViewRepresentable {
    let points: [CourierMapPoint]
    @Binding var selectedID: String?
    let cameraScope: String
    let fitRequest: Int
    let selectedShopID: Int?
    let preferredShopID: Int?
    let dataIsCurrent: Bool
    let memory: CourierMapCameraMemory

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let map = CourierMapCanvas(frame: .zero)
        // Do not flash MapKit's default country while VV loads the shop.
        map.alpha = 0
        map.delegate = context.coordinator
        let coordinator = context.coordinator
        map.onLayout = { [weak coordinator] map in coordinator?.applyCameraAfterLayout(map) }
        map.isScrollEnabled = true; map.isZoomEnabled = true
        map.isRotateEnabled = false; map.isPitchEnabled = false
        map.showsCompass = true; map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.register(CourierPinAnnotationView.self, forAnnotationViewWithReuseIdentifier: CourierPinAnnotationView.reuseID)
        map.accessibilityIdentifier = "orders.map.canvas"
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.prepareScope(map)
        if coordinator.fitRequest != fitRequest {
            coordinator.fitRequest = fitRequest
            coordinator.pendingShowAll = true
            coordinator.pendingRestore = nil
        }
        let incoming = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let removed = coordinator.annotations.filter { incoming[$0.key] == nil }
        map.removeAnnotations(removed.map(\.value))
        for key in removed.keys { coordinator.annotations.removeValue(forKey: key) }
        for point in points {
            let annotation: CourierPinAnnotation
            if let current = coordinator.annotations[point.id] {
                annotation = current
                if current.coordinate.latitude != point.coordinate.latitude || current.coordinate.longitude != point.coordinate.longitude { current.coordinate = point.coordinate.mapKitCoordinate }
                current.point = point
            } else {
                annotation = CourierPinAnnotation(point)
                coordinator.annotations[point.id] = annotation
                map.addAnnotation(annotation)
            }
            if let view = map.view(for: annotation) as? CourierPinAnnotationView { view.configure(annotation, selected: point.parcelID != nil && point.parcelID == selectedID) }
        }
        // Native layout must be non-zero before choosing a camera; fitting a
        // zero-height representable can otherwise produce a continent-wide view.
        coordinator.applyPendingCamera(map)
        for annotation in map.selectedAnnotations {
            if let pin = annotation as? CourierPinAnnotation, pin.point.parcelID != selectedID { map.deselectAnnotation(pin, animated: false) }
        }
        if let selectedID, let annotation = coordinator.annotations["order:" + selectedID], !map.selectedAnnotations.contains(where: { ($0 as? CourierPinAnnotation)?.point.id == annotation.point.id }) { map.selectAnnotation(annotation, animated: false) }
    }
    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.rememberCamera(map)
        (map as? CourierMapCanvas)?.onLayout = nil
        map.delegate = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var owner: NativeCourierMap
        var annotations: [String: CourierPinAnnotation] = [:]
        var cameraScope: String?
        var needsInitialFocus = true
        var establishedCamera = false
        var pendingRestore: MKCoordinateRegion?
        var pendingShowAll = false
        var fitRequest = 0
        var updating = false
        init(_ owner: NativeCourierMap) { self.owner = owner }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? CourierPinAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: CourierPinAnnotationView.reuseID, for: pin) as! CourierPinAnnotationView
            view.configure(pin, selected: pin.point.parcelID != nil && pin.point.parcelID == owner.selectedID)
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let pin = view.annotation as? CourierPinAnnotation else { return }
            if let view = view as? CourierPinAnnotationView { view.configure(pin, selected: !pin.point.isShop) }
            guard !updating, let id = pin.point.parcelID else { return }
            owner.selectedID = id
        }
        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let pin = view.annotation as? CourierPinAnnotation else { return }
            if let view = view as? CourierPinAnnotationView { view.configure(pin, selected: pin.point.parcelID != nil && pin.point.parcelID == owner.selectedID) }
            // Keep the last selected order visible in the list while the map is
            // being dragged; the next pin tap changes both highlights together.
        }
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard !updating, hasActiveGesture(in: mapView) else { return }
            needsInitialFocus = false; pendingRestore = nil
            establishedCamera = true
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { rememberCamera(mapView) }
        private func hasActiveGesture(in view: UIView) -> Bool {
            if view.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true { return true }
            return view.subviews.contains(where: hasActiveGesture)
        }
        func prepareScope(_ map: MKMapView) {
            guard cameraScope != owner.cameraScope else { return }
            rememberCamera(map)
            cameraScope = owner.cameraScope
            establishedCamera = false
            pendingRestore = owner.memory.regions[owner.cameraScope]
            map.alpha = 0
            needsInitialFocus = pendingRestore == nil
            pendingShowAll = false
            fitRequest = owner.fitRequest
        }
        func rememberCamera(_ map: MKMapView) {
            guard establishedCamera, let cameraScope, map.bounds.width > 1, map.bounds.height > 1 else { return }
            owner.memory.regions[cameraScope] = map.region
        }
        func applyCameraAfterLayout(_ map: MKMapView) {
            guard !updating else { return }
            updating = true; defer { updating = false }
            applyPendingCamera(map)
        }
        func applyPendingCamera(_ map: MKMapView) {
            guard map.bounds.width > 1, map.bounds.height > 1 else { return }
            if pendingShowAll {
                guard owner.dataIsCurrent else { return }
                guard showAllOrders(map) else { return }
                pendingShowAll = false; needsInitialFocus = false; establishedCamera = true
                rememberCamera(map)
            } else if let region = pendingRestore {
                pendingRestore = nil; needsInitialFocus = false; establishedCamera = true
                map.setRegion(region, animated: false)
                rememberCamera(map)
            } else if needsInitialFocus, let center = initialCenter() {
                needsInitialFocus = false; establishedCamera = true
                showNeighborhood(map, center: center)
                rememberCamera(map)
            }
            if establishedCamera { map.alpha = 1 }
        }
        private func showNeighborhood(_ map: MKMapView, center: CLLocationCoordinate2D) {
            let widthMeters = 2400.0
            let aspect = Double(map.bounds.height / max(1, map.bounds.width))
            let heightMeters = max(400, widthMeters * aspect)
            map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: heightMeters, longitudinalMeters: widthMeters), animated: false)
        }
        private func initialCenter() -> CLLocationCoordinate2D? {
            let shops = owner.points.filter(\.isShop)
            let orders = owner.dataIsCurrent ? owner.points.filter { !$0.isShop } : []
            if let selected = owner.selectedShopID {
                if let shop = shops.first(where: { $0.shopID == selected }) { return shop.coordinate.mapKitCoordinate }
                let sameShop = orders.filter { $0.shopID == selected }
                if !sameShop.isEmpty { return denseOrderCenter(sameShop) }
                if orders.isEmpty { return nil }
            }
            if let preferred = shops.first(where: { $0.shopID == owner.preferredShopID }) { return preferred.coordinate.mapKitCoordinate }
            var counts: [Int: Int] = [:]
            for order in orders { if let shop = order.shopID { counts[shop, default: 0] += 1 } }
            let dominant = orders.compactMap(\.shopID).max { counts[$0, default: 0] < counts[$1, default: 0] }
            if let shop = shops.first(where: { $0.shopID == dominant }) ?? shops.first { return shop.coordinate.mapKitCoordinate }
            return denseOrderCenter(orders)
        }
        private struct Cell: Hashable { let x: Int; let y: Int }
        private func denseOrderCenter(_ orders: [CourierMapPoint]) -> CLLocationCoordinate2D? {
            guard let first = orders.first else { return nil }
            let size = MKMapPointsPerMeterAtLatitude(first.coordinate.latitude) * 1500
            guard size.isFinite, size > 0 else { return first.coordinate.mapKitCoordinate }
            var buckets: [Cell: [CourierMapPoint]] = [:]
            var sequence: [Cell] = []
            for order in orders {
                let point = MKMapPoint(order.coordinate.mapKitCoordinate)
                guard point.x.isFinite, point.y.isFinite else { continue }
                let cell = Cell(x: Int(floor(point.x / size)), y: Int(floor(point.y / size)))
                if buckets[cell] == nil { sequence.append(cell) }
                buckets[cell, default: []].append(order)
            }
            var best: [CourierMapPoint] = []
            for cell in sequence {
                var neighborhood: [CourierMapPoint] = []
                for x in -1...1 { for y in -1...1 { neighborhood += buckets[Cell(x: cell.x + x, y: cell.y + y)] ?? [] } }
                if neighborhood.count > best.count { best = neighborhood }
            }
            guard !best.isEmpty else { return first.coordinate.mapKitCoordinate }
            let latitudes = best.map { $0.coordinate.latitude }.sorted()
            let longitudes = best.map { $0.coordinate.longitude }.sorted()
            return CLLocationCoordinate2D(latitude: latitudes[latitudes.count / 2], longitude: longitudes[longitudes.count / 2])
        }
        private func showAllOrders(_ map: MKMapView) -> Bool {
            let orders = owner.points.filter { !$0.isShop }
            guard let first = orders.first else {
                guard let center = initialCenter() else { return false }
                showNeighborhood(map, center: center)
                return true
            }
            var rect = MKMapRect(origin: MKMapPoint(first.coordinate.mapKitCoordinate), size: MKMapSize(width: 1, height: 1))
            for point in orders.dropFirst() { rect = rect.union(MKMapRect(origin: MKMapPoint(point.coordinate.mapKitCoordinate), size: MKMapSize(width: 1, height: 1))) }
            let minimum = MKMapPointsPerMeterAtLatitude(first.coordinate.latitude) * 350
            rect = rect.insetBy(dx: -max(minimum, rect.width * 0.1), dy: -max(minimum, rect.height * 0.1))
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 44, left: 20, bottom: 8, right: 20), animated: false)
            return true
        }

    }
}

private final class CourierMapCameraMemory: ObservableObject {
    var regions: [String: MKCoordinateRegion] = [:]
}

private final class CourierMapCanvas: MKMapView {
    var onLayout: ((MKMapView) -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?(self) }
}

private final class CourierPinAnnotation: NSObject, MKAnnotation {
    var point: CourierMapPoint
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { point.title }
    init(_ point: CourierMapPoint) { self.point = point; coordinate = point.coordinate.mapKitCoordinate }
}

/// First-party VV CSS: container 28×42, 15px regular numeral, 2px status
/// border, white fill/outer edge and an 18px narrow tail. Stores use 13px type.
/// Source: /assets/index-Cdr-PP_y.css (_container_8w4nj_1 / _placemark_8w4nj_21).
private final class CourierPinAnnotationView: MKAnnotationView {
    static let reuseID = "CourierOriginalPin"
    private var text = ""
    private var colorName = "green"
    private var shop = false
    private var highlightedOrder = false
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false; isEnabled = true
        backgroundColor = .clear; isOpaque = false
        collisionMode = .rectangle; displayPriority = .required
        centerOffset = CGPoint(x: 0, y: -20)
        isAccessibilityElement = true; accessibilityTraits = .button
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.45
        layer.shadowRadius = 2; layer.shadowOffset = CGSize(width: 3, height: -1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(_ annotation: CourierPinAnnotation, selected: Bool) {
        self.annotation = annotation
        text = annotation.point.text; colorName = annotation.point.colorName
        shop = annotation.point.isShop; highlightedOrder = selected
        let font = UIFont.systemFont(ofSize: shop ? 13 : 15)
        let width = max(28, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8)
        bounds = CGRect(x: 0, y: 0, width: width + 4, height: 44)
        accessibilityIdentifier = shop ? "map." + annotation.point.id.replacingOccurrences(of: ":", with: ".") : "map.order." + (annotation.point.parcelID ?? "")
        accessibilityLabel = annotation.point.title
        accessibilityValue = selected ? "Выбран" : nil
        layer.zPosition = selected ? 1000 : shop ? 100 : 0
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        let color = parcelMapUIColor(colorName)
        let bubble = CGRect(x: 2, y: 1, width: bounds.width - 4, height: 25)
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: bubble.midX - 2, y: 19))
        tail.addLine(to: CGPoint(x: bubble.midX + 11, y: 19))
        tail.addLine(to: CGPoint(x: bubble.midX + 2, y: 41))
        tail.addLine(to: CGPoint(x: bubble.midX - 3, y: 31)); tail.close()
        color.setFill(); tail.fill()
        let outer = UIBezierPath(roundedRect: bubble.insetBy(dx: -1, dy: -1), cornerRadius: 15)
        UIColor.white.setFill(); outer.fill()
        let shape = UIBezierPath(roundedRect: bubble, cornerRadius: 14)
        UIColor.white.setFill(); shape.fill(); color.setStroke(); shape.lineWidth = 2; shape.stroke()
        if highlightedOrder {
            let ring = UIBezierPath(roundedRect: bubble.insetBy(dx: -2, dy: -2), cornerRadius: 16)
            UIColor.label.setStroke(); ring.lineWidth = 1.5; ring.stroke()
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: CGRect(x: bubble.minX + 2, y: bubble.minY + (shop ? 4 : 3), width: bubble.width - 4, height: 20), withAttributes: [.font: UIFont.systemFont(ofSize: shop ? 13 : 15), .foregroundColor: UIColor.black, .paragraphStyle: paragraph])
    }
}
