import Foundation
import Combine
import AVFoundation

final class WheelAlarmPreferences: ObservableObject {
    static let shared = WheelAlarmPreferences()
    @Published var speed: WheelPhoneAlarmRule { didSet { save() } }
    @Published var pwm: WheelPhoneAlarmRule { didSet { save() } }
    @Published var duckMusic: Bool { didSet { save() } }
    private let key = "wheel.phone.alarms.v1"
    private struct Stored: Codable { let speed: WheelPhoneAlarmRule; let pwm: WheelPhoneAlarmRule; let duckMusic: Bool? }
    private init() {
        let data = UserDefaults.standard.data(forKey: "wheel.phone.alarms.v1")
        let stored = data.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        speed = (stored?.speed ?? WheelPhoneAlarmRule(enabled: false, threshold: 35, repeatInterval: 5)).normalized(pwm: false)
        pwm = (stored?.pwm ?? WheelPhoneAlarmRule(enabled: false, threshold: 80, repeatInterval: 5)).normalized(pwm: true)
        duckMusic = stored?.duckMusic ?? false
    }
    private func save() {
        if let data = try? JSONEncoder().encode(Stored(speed: speed.normalized(pwm: false), pwm: pwm.normalized(pwm: true), duckMusic: duckMusic)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// Phone-only alerts: this class has no BLE command API. It never changes any
// wheel setting. Called on the main queue with complete CRC-valid telemetry.
final class WheelPhoneAlarmMonitor: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = WheelPhoneAlarmMonitor()
    @Published private(set) var audioError: String?
    private let preferences = WheelAlarmPreferences.shared
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var latest: WheelTelemetry?
    private var demo = true
    private var player: AVAudioPlayer?
    private var playingPreview = false
    private var audioSessionActive = false
    private var soundID = UUID()
    private var interruptionObserver: NSObjectProtocol?
    private var lastAnySound = Date.distantPast
    private var speedState = WheelAlarmLatch()
    private var pwmState = WheelAlarmLatch()
    override private init() {
        super.init()
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in self?.stopSound() }
        #endif
        subscription = preferences.objectWillChange.sink { [weak self] _ in
            // Published emits before assignment. Evaluate the completed change.
            DispatchQueue.main.async { self?.configurationChanged() }
        }
    }
    func activate(demo value: Bool) {
        if demo != value { reset(); latest = nil }
        demo = value
        configureTimer()
    }
    func receive(_ sample: WheelTelemetry) {
        guard !demo else { return }
        latest = sample
        evaluate(at: Date())
    }
    func disconnected() { latest = nil; reset(); stopSound() }
    func preview(pwm: Bool) { play(pwm: pwm, preview: true) }
    private func configurationChanged() {
        reset()
        configureTimer()
        evaluate(at: Date())
    }
    private func configureTimer() {
        timer?.invalidate(); timer = nil
        guard !demo, preferences.speed.enabled || preferences.pwm.enabled else { return }
        // Stops sound after lost telemetry even if no disconnect callback arrives.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.evaluate(at: Date()) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func evaluate(at date: Date) {
        guard let inputs = WheelAlarmInputs(sample: latest, demo: demo, at: date, percentage: WheelSpeedPreferences.shared.percentage) else { reset(); return }
        guard !playingPreview else { return }
        let speed = preferences.speed.normalized(pwm: false)
        let pwm = preferences.pwm.normalized(pwm: true)
        speedState.evaluate(value: inputs.speed, rule: speed)
        pwmState.evaluate(value: inputs.pwm, rule: pwm)
        guard date.timeIntervalSince(lastAnySound) >= 0.75 else { return }
        if pwmState.active, date.timeIntervalSince(pwmState.lastSound) >= pwm.repeatInterval {
            pwmState.lastSound = date; lastAnySound = date; play(pwm: true)
        } else if speedState.active, date.timeIntervalSince(speedState.lastSound) >= speed.repeatInterval {
            speedState.lastSound = date; lastAnySound = date; play(pwm: false)
        }
    }
    private func reset() {
        // Keep the last beep timestamps across threshold chatter/signal loss.
        speedState.active = false; pwmState.active = false
        if !playingPreview { stopSound() }
    }
    private func play(pwm: Bool, preview: Bool = false) {
        stopSound()
        playingPreview = preview
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            let options: AVAudioSession.CategoryOptions = preferences.duckMusic ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
            try session.setCategory(.playback, mode: .default, options: options)
            try session.setActive(true)
            audioSessionActive = true
            #endif
            let sound = try AVAudioPlayer(data: Self.wave(pwm: pwm), fileTypeHint: "wav")
            sound.delegate = self; sound.volume = 1; sound.prepareToPlay()
            player = sound
            guard sound.play() else { throw NSError(domain: "WheelAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "iPhone не запустил звук."]) }
            audioError = nil
            // Finish callbacks can be omitted on route/interruption failures.
            // Release ducking after this short tone even without the delegate.
            let id = UUID(); soundID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + (pwm ? 0.65 : 0.42)) { [weak self] in
                guard self?.soundID == id else { return }
                self?.stopSound()
            }
        } catch {
            audioError = "Не удалось воспроизвести сигнал: " + error.localizedDescription
            stopSound()
        }
    }
    private func stopSound() {
        soundID = UUID()
        player?.stop(); player = nil; playingPreview = false
        #if os(iOS)
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
        #endif
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        if !flag { audioError = "Воспроизведение сигнала было прервано." }
        stopSound()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard self.player === player else { return }
        audioError = "Ошибка звука: " + (error?.localizedDescription ?? "неизвестная причина")
        stopSound()
    }
    private static func wave(pwm: Bool) -> Data {
        // Short mono PCM tone, generated locally: speed one low beep, PWM two
        // higher beeps. No network, assets, silent background loop or microphone.
        let rate = 44_100
        let duration = pwm ? 0.45 : 0.22
        let count = Int(Double(rate) * duration)
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let segment = pwm ? t.truncatingRemainder(dividingBy: 0.25) : t
            let sounding = !pwm || t < 0.18 || t >= 0.25
            let envelope = min(1, segment / 0.008, max(0, (0.20 - segment) / 0.012))
            let amplitude = sounding ? sin(2 * .pi * (pwm ? 1_400 : 900) * t) * 0.65 * envelope : 0
            var sample = Int16(amplitude * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var result = Data()
        func text(_ string: String) { result.append(contentsOf: string.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
