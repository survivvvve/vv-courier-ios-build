import SwiftUI

extension CourierAPI {
    func archivedParcels(daysAgo: Int) async throws -> [Parcel] {
        guard (0...2).contains(daysAgo) else { throw CourierError(message: "ВВ показывает архив только за последние три дня.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        let start = calendar.startOfDay(for: day), end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!.addingTimeInterval(-0.001)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [Parcel] = [], pagination = CourierPagination(limit: 25)
        while true {
            try Task.checkCancellation()
            let data = try await dictionary(Self.root + "/v1/courier/get_parcels_archive", body: ["id_courier": session?.courierID ?? "", "pagination": ["offset": pagination.offset, "limit": pagination.limit], "date_time_start": formatter.string(from: start), "date_time_end": formatter.string(from: end)])
            guard let rows = data["parcels"] as? [[String: Any]] else { throw CourierError(message: "Не удалось прочитать архив ВВ.") }
            let page = try pagination.consume(rows, reportedTotal: data["total"])
            result += page.rows.map(Parcel.init)
            if page.complete { return result }
        }
    }
}

struct ArchiveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var day = 0
    @State private var rows: [Parcel] = []
    @State private var selected: Parcel?
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var generation = UUID()
    private var requestKey: String { model.identity + ":\(day)" }
    var body: some View {
        CourierPage("Архив заказов", subtitle: "Последние три дня по московскому времени", artwork: 4) {
            if model.demo { DemoBanner() }
            Picker("Дата", selection: $day) { Text("Сегодня").tag(0); Text("Вчера").tag(1); Text("Позавчера").tag(2) }.pickerStyle(.segmented)
            if loading { CourierCard { ProgressView("Загружаем архив…") } }
            if let failure { CourierErrorCard(message: failure) { Task { await load() } } }
            if loaded && rows.isEmpty && failure == nil { CourierEmpty(title: "Архив пуст", message: "За выбранный день ВВ не показывает завершённых заказов.", symbol: "archivebox") }
            ForEach(rows) { parcel in Button { selected = parcel } label: { CourierCard { ParcelSummary(parcel: parcel) } }.buttonStyle(.plain) }
        }.navigationBarTitleDisplayMode(.inline).task(id: requestKey) { await load() }.refreshable { await load() }
            .sheet(item: $selected) { value in NavigationStack { ParcelDetailView(initial: value, source: .assembly) } }
    }
    private func load() async {
        let id = UUID(), key = requestKey; generation = id; loading = true; loaded = false; failure = nil; rows = []; selected = nil
        defer { if generation == id { loading = false } }
        if model.demo { rows = Demo.orders(.available).map { parcel in var value = parcel; value.status = "delivered"; return value }; loaded = true; return }
        let client = model.api, selectedDay = day
        do { let value = try await client.archivedParcels(daysAgo: selectedDay); guard generation == id, key == requestKey, !Task.isCancelled else { return }; rows = value; loaded = true }
        catch is CancellationError { }
        catch { if generation == id && key == requestKey { failure = error.localizedDescription; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } } }
    }
}
