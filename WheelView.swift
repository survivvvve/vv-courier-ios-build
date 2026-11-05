import SwiftUI

struct WheelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var wheel = WheelConnection.shared
    @StateObject private var dashboard = WheelDashboardPreferences.shared
    @StateObject private var speed = WheelSpeedPreferences.shared
    @StateObject private var rides = WheelRideStore.shared
    @State private var armConfirmation = false

    var body: some View {
        CourierPage("Колесо", subtitle: wheel.sample.map { $0.modelName + " · " + $0.family.title } ?? "Показания и поддерживаемые функции твоего колеса") {
            if model.demo { DemoBanner() }
            connectionCard
            if wheel.scanning || !wheel.nearby.isEmpty {
                CourierCard("Устройства рядом") {
                    if wheel.scanning { ProgressView("Поиск…") }
                    ForEach(wheel.nearby) { device in
                        Button { wheel.connect(device.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).font(.subheadline.weight(.semibold))
                                    Text("Сигнал \(device.rssi) дБм").font(.caption).foregroundStyle(Palette.muted)
                                    if let hint = device.protocolHint { Text(hint).font(.caption2).foregroundStyle(Palette.muted) }
                                }
                                Spacer(); Text("Подключить").font(.subheadline.weight(.semibold))
                            }.padding(.vertical, 6)
                        }.buttonStyle(.plain).accessibilityIdentifier("wheel.device.\(device.id.uuidString)")
                    }
                    Text("Выбери своё колесо. Модель проверится по полученным данным.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            if wheel.supported {
                NavigationLink { WheelSettingsView() } label: { Label("Настройки колеса", systemImage: "slider.horizontal.3") }.buttonStyle(CourierButtonStyle()).accessibilityIdentifier("wheel.settings")
            } else if wheel.connected {
                CourierCard { Text("Настройки этой модели пока доступны в приложении производителя. Показания, приборы, поправка скорости и сигналы iPhone работают отдельно.").font(.caption).foregroundStyle(Palette.muted) }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let fresh = model.demo ? wheel.connected : wheel.connected && wheel.sample?.isFresh(at: context.date) == true
                instruments(fresh: fresh, at: context.date)
                rideSummary
                controls(fresh: fresh, at: context.date)
            }
            if let message = wheel.message {
                CourierCard {
                    Text(message).font(.subheadline)
                    Button("Понятно") { wheel.message = nil }.font(.subheadline.weight(.medium))
                }
            }

        }
        .courierBrandHeader()
        .onAppear { wheel.activate(demo: model.demo) }
        .onChange(of: model.demo) { _, value in wheel.activate(demo: value) }
        .onChange(of: scenePhase) { _, value in if value == .active { wheel.activate(demo: model.demo) } }
        .confirmationDialog("Поставить колесо на охрану?", isPresented: $armConfirmation, titleVisibility: .visible) {
            Button("Колесо в P · включить охрану") { wheel.setAlarm(true) }
        } message: {
            Text("Останови колесо и включи парковку P на его панели. Кнопка покажет охрану только после подтверждения от колеса.")
        }
    }

    private var connectionCard: some View {
        CourierCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: wheel.connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash").font(.title3).foregroundStyle(wheel.connected ? Palette.success : Palette.muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text(wheel.name).font(.headline)
                    Text(wheel.status).font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("wheel.screen")
                    if let sample = wheel.sample { Text("Прошивка \(sample.version)").font(.caption).foregroundStyle(Palette.muted) }
                }
                Spacer()
                if wheel.connecting { ProgressView() }
            }
            if wheel.hasSavedWheel || model.demo {
                Toggle("Подключаться автоматически", isOn: Binding(get: { wheel.automaticConnection }, set: { wheel.setAutomaticConnection($0) })).font(.subheadline).accessibilityIdentifier("wheel.autoconnect")
            }
            if !model.demo {
                if wheel.connected || wheel.connecting {
                    Button("Отключить колесо") { wheel.disconnect() }.buttonStyle(CourierButtonStyle()).accessibilityIdentifier("wheel.disconnect")
                } else {
                    Button(wheel.scanning ? "Остановить поиск" : "Найти колесо") { if wheel.scanning { wheel.stopSearch() } else { wheel.scan() } }.buttonStyle(CourierButtonStyle(primary: true)).accessibilityIdentifier("wheel.connect")
                    if wheel.hasSavedWheel {
                        Button("Подключить сохранённое") { wheel.reconnect() }.font(.subheadline).disabled(wheel.scanning)
                    }
                }
            }
        }
    }

    private func instruments(fresh: Bool, at date: Date) -> some View {
        CourierCard {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 20) {
                ForEach(dashboard.metrics) { metric in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(metric.title + (metric == .charge && wheel.sample?.batteryIsEstimated == true ? " ≈" : "") + " · " + metric.unit).font(.caption).foregroundStyle(Palette.muted)
                        Text(metric.value(sample: wheel.sample, battery: wheel.batteryReading, fresh: fresh, at: date, demo: model.demo, speedPercentage: speed.percentage))
                            .font(.system(size: metric == .speed ? 52 : 38, weight: .semibold, design: .rounded))
                            .monospacedDigit().minimumScaleFactor(0.45).lineLimit(1)
                            .foregroundStyle(metric == .pwm && fresh && (wheel.sample?.pwm ?? 0) >= 85 ? Palette.danger : metric == .pwm && fresh && (wheel.sample?.pwm ?? 0) >= 70 ? Palette.warning : Palette.text)
                            .accessibilityIdentifier("wheel." + metric.rawValue)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            Text(fresh ? "«—» — показатель не поддерживается или свежие данные ещё не получены. Заряд с ≈ оценён по напряжению." : "Свежих данных нет. Подключись к колесу для обновления.").font(.caption).foregroundStyle(Palette.muted)
            if abs(speed.percentage - 100) >= 0.05 { Text(String(format: "Поправка скорости: %.1f%%", speed.percentage)).font(.caption).foregroundStyle(Palette.muted) }
            NavigationLink { WheelSpeedSettingsView() } label: { Label("Поправка скорости", systemImage: "speedometer") }.font(.subheadline.weight(.medium)).foregroundStyle(Palette.accent)
            HStack {
                NavigationLink { WheelDashboardSettingsView() } label: { Label("Приборы", systemImage: "square.grid.2x2") }.accessibilityIdentifier("wheel.dashboard")
                Spacer()
                NavigationLink { WheelAlarmSettingsView() } label: { Label("Сигналы", systemImage: "speaker.wave.2") }
            }.font(.subheadline.weight(.medium)).foregroundStyle(Palette.accent)
        }
    }

    private var rideSummary: some View {
        CourierCard("Езда за сегодня · МСК") {
            if !model.demo, let summary = rides.today, summary.hasData {
                HStack {
                    CourierMetric(title: "Записанный путь", value: String(format: "%.2f км", summary.meters / 1000))
                    CourierMetric(title: "В движении", value: "\(Int(summary.movingSeconds) / 60) мин")
                }
                HStack {
                    CourierMetric(title: "Средняя", value: summary.averageSpeed.map { String(format: "%.1f км/ч", $0) } ?? "—")
                    CourierMetric(title: "Максимальная", value: summary.maxSpeed.map { String(format: "%.1f км/ч", $0) } ?? "—")
                }
                Text(rides.recordingAllowed ? "Записывается только во время подтверждённой смены ВВ. Разрывы связи не дополняются; полные итоги и ₽/км — в доходах." : "Запись приостановлена. Показаны сохранённые отрезки за сегодня, без восстановления пропусков.").font(.caption).foregroundStyle(Palette.muted)
            } else {
                Text(model.demo ? "В демо поездки не записываются." : rides.recordingAllowed ? "Запись начнётся со свежей телеметрии колеса." : "Для записи нужна авторизация и подтверждённая активная смена ВВ.").font(.subheadline).foregroundStyle(Palette.muted)
                Text("История начинается после обновления: прошлые километры не восстанавливаются.").font(.caption).foregroundStyle(Palette.muted)
            }
            if let error = rides.storageError { Text(error).font(.caption).foregroundStyle(Palette.warning) }
        }
    }

    private func controls(fresh: Bool, at date: Date) -> some View {
        let available = fresh && wheel.supported && wheel.pending == nil
        let alarmFresh = model.demo ? wheel.alarm != nil : wheel.alarmIsFresh(at: date)
        let lampFresh = model.demo ? wheel.lightOn != nil : wheel.lightIsFresh(at: date)
        return VStack(spacing: 12) {
            if wheel.supported || model.demo {
            CourierCard {
                HStack {
                    Image(systemName: alarmFresh && wheel.alarm?.enabled == true ? "lock.shield.fill" : "lock.shield")
                    Text("Сигнализация").font(.headline)
                    Spacer()
                }
                Text(alarmFresh ? wheel.alarm?.title ?? "Состояние неизвестно" : "Состояние неизвестно").font(.subheadline).foregroundStyle(alarmFresh && wheel.alarm?.enabled == true ? Palette.success : Palette.muted)
                Button(alarmFresh && wheel.alarm?.enabled == true ? "Снять с охраны" : "Поставить на охрану") {
                    if wheel.alarm?.enabled == true { wheel.setAlarm(false) } else { armConfirmation = true }
                }.buttonStyle(CourierButtonStyle(primary: true)).disabled(!available || !alarmFresh || (wheel.alarm?.enabled != true && abs(wheel.sample?.speed ?? 1) >= 0.1)).accessibilityIdentifier("wheel.alarm")
                if fresh && !wheel.supported {
                    Text("Сигнализация этой прошивки пока не опознана. Управление станет доступно после получения совместимого состояния.").font(.caption).foregroundStyle(Palette.muted)
                } else {
                    Text("Для постановки нужна остановка и парковка P. После снятия с охраны парковка остаётся включённой.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            }
            if wheel.lightSupported || wheel.lightOn != nil || model.demo {
            CourierCard {
                HStack {
                    Label("Фара", systemImage: "light.beacon.max").font(.headline)
                    Spacer()
                    Text(lampFresh ? wheel.lightOn == true ? "Включена" : "Выключена" : "Нет свежего состояния").font(.caption).foregroundStyle(Palette.muted)
                }
                HStack(spacing: 10) {
                    Button("Включить") { wheel.setLight(true) }.buttonStyle(CourierButtonStyle(primary: lampFresh && wheel.lightOn == true)).disabled(!fresh || !wheel.lightSupported || wheel.pending != nil).accessibilityIdentifier("wheel.light.on")
                    Button("Выключить") { wheel.setLight(false) }.buttonStyle(CourierButtonStyle(primary: lampFresh && wheel.lightOn == false)).disabled(!fresh || !wheel.lightSupported || wheel.pending != nil).accessibilityIdentifier("wheel.light.off")
                }
            }
            }
            if let pending = wheel.pending { HStack(spacing: 10) { ProgressView(); Text(pending).font(.subheadline) }.frame(maxWidth: .infinity) }
        }
    }
}
