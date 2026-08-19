import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import Foundation

private let rightOptionKeyCode: UInt16 = 61
private let minimumRecordingDuration = 0.3

private enum AppState {
    case loading
    case ready
    case recording
    // Запись, зафиксированная двойным нажатием: идёт без удержания клавиши.
    // Отдельное состояние, а не флаг при .recording — строка меню обязана
    // отличать её от обычной записи, иначе режимы неразличимы.
    case lockedRecording
    case transcribing
    case failed(String)

    /// Идёт ли запись в любой из двух форм: обычной или зафиксированной.
    /// Проверки вида `case .recording = state` пропустили бы фиксацию,
    /// и зафиксированная запись не остановилась бы.
    var isRecording: Bool {
        switch self {
        case .recording, .lockedRecording: return true
        case .loading, .ready, .transcribing, .failed: return false
        }
    }
}

private final class ASRWorker {
    var onReady: (() -> Void)?
    var onResult: ((String, URL) -> Void)?
    var onError: ((String, URL?) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    private var pendingFiles: [String: URL] = [:]

    func start() throws {
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(
                domain: "Chirper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Не найдены ресурсы приложения"]
            )
        }
        let executable = resources.appendingPathComponent("ASR/ChirperASR")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(
                domain: "Chirper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Не найден встроенный ASR-модуль"]
            )
        }

        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            FileLogger.shared.write(text)
        }
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                let message = "ASR-процесс завершился с кодом \(process.terminationStatus)"
                self?.failPending(message)
                self?.onError?(message, nil)
            }
        }
        try process.run()
    }

    /// Подтянуть модель обратно в память, пока идёт запись.
    ///
    /// Простаивающий воркер держит ~1 ГБ, который macOS вытесняет в swap, и
    /// тогда первое распознавание начинается с многосекундного чтения с диска.
    /// Прогрев идёт параллельно речи, так что к «стоп» модель уже горячая.
    /// Ошибку глотаем: прогрев — оптимизация, его провал не должен мешать
    /// записи, а реальная поломка канала всплывёт на transcribe.
    func warmup() {
        try? send(["command": "warmup"])
    }

    func transcribe(_ url: URL) throws {
        let id = UUID().uuidString
        pendingFiles[id] = url
        do {
            try send(["command": "transcribe", "id": id, "audio_path": url.path])
        } catch {
            pendingFiles.removeValue(forKey: id)
            throw error
        }
    }

    func stop() {
        try? send(["command": "shutdown"])
        input.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        for url in pendingFiles.values { try? FileManager.default.removeItem(at: url) }
        pendingFiles.removeAll()
    }

    private func send(_ object: [String: String]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let event = object["event"] as? String
            else {
                failPending("ASR вернул повреждённый ответ")
                continue
            }

            switch event {
            case "ready":
                onReady?()
            case "result":
                guard
                    let id = object["id"] as? String,
                    let url = pendingFiles.removeValue(forKey: id)
                else { continue }
                onResult?(object["text"] as? String ?? "", url)
            case "error":
                let id = object["id"] as? String
                let url = id.flatMap { pendingFiles.removeValue(forKey: $0) }
                onError?(object["error"] as? String ?? "Ошибка распознавания", url)
            case "failed":
                onError?(object["error"] as? String ?? "Модель не загрузилась", nil)
            default:
                break
            }
        }
    }

    private func failPending(_ message: String) {
        let files = Array(pendingFiles.values)
        pendingFiles.removeAll()
        for url in files { onError?(message, url) }
    }
}

private final class MicrophoneRecorder {
    var onLevel: ((Float) -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var previousInputDevice: AudioDeviceID?
    private(set) var startedAt = Date()

    var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async { completion(allowed) }
            }
        default:
            completion(false)
        }
    }

    func start() throws -> URL {
        previousInputDevice = AudioInputRouting.useBuiltInMicrophone()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Chirper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // После аварийного завершения личное аудио не должно оставаться.
        for oldFile in (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [] where oldFile.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: oldFile)
        }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            restoreInputDevice()
            throw error
        }
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            restoreInputDevice()
            throw NSError(
                domain: "Chirper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "macOS не начала запись с микрофона"]
            )
        }
        self.recorder = recorder
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            // AVAudioRecorder показывает заметно более высокий шумовой фон,
            // чем прежний sounddevice. Ниже -42 dB считаем тишиной; выше
            // растягиваем диапазон до 0...1 для живой реакции на речь.
            let decibels = recorder.averagePower(forChannel: 0)
            let voiceLevel = min(1, max(0, (decibels + 42) / 32))
            self.onLevel?(voiceLevel)
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
        startedAt = Date()
        return url
    }

    @discardableResult
    func stop() -> UInt64 {
        meterTimer?.invalidate()
        meterTimer = nil
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        restoreInputDevice()
        onLevel?(0)
        guard
            let url,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.uint64Value
    }

    private func restoreInputDevice() {
        if let previousInputDevice {
            AudioInputRouting.setDefaultInput(previousInputDevice)
        }
        previousInputDevice = nil
    }
}

private enum AudioInputRouting {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func useBuiltInMicrophone() -> AudioDeviceID? {
        guard let current = defaultInput(), let builtIn = builtInInput(), current != builtIn else {
            return nil
        }
        setDefaultInput(builtIn)
        return current
    }

    static func setDefaultInput(_ device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = device
        AudioObjectSetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &value
        )
    }

    private static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &value) == noErr,
              value != kAudioObjectUnknown else { return nil }
        return value
    }

    private static func builtInInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
            return nil
        }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }
        return devices.first { device in
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                device, &transportAddress, 0, nil, &transportSize, &transport
            ) == noErr, transport == kAudioDeviceTransportTypeBuiltIn else { return false }

            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(
                device, &streamsAddress, 0, nil, &streamsSize
            ) == noErr && streamsSize > 0
        }
    }
}

private final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pressed = false

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == rightOptionKeyCode else { return }
        let isDown = event.modifierFlags.contains(.option)
        guard isDown != pressed else { return }
        pressed = isDown
        DispatchQueue.main.async {
            if isDown { self.onPress?() } else { self.onRelease?() }
        }
    }
}

/// Материал огранки оверлея. Задаёт цвета рамки и оправы рубиновой лампы.
/// Иконки приложения и строки меню от него не зависят: настраиваемые параметры
/// существуют только у оверлея.
enum BezelMaterial: Int, CaseIterable {
    case gold = 0
    case bluedSteel = 1

    var title: String {
        switch self {
        case .gold: return "Золото"
        case .bluedSteel: return "Воронёная сталь"
        }
    }

    /// Грани огранки: светлая сверху слева, средний тон, тёмная снизу справа.
    /// Значения взяты из таблицы палитры в ДИЗАЙН.md и различаются по теме —
    /// в тёмной блик поднят, иначе рамка теряет объём на тёмном фоне.
    struct Грани {
        let светлая: NSColor
        let средняя: NSColor
        let тёмная: NSColor
    }

    private static func цвет(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    func грани(тёмнаяТема: Bool) -> Грани {
        switch self {
        case .gold:
            return тёмнаяТема
                ? Грани(светлая: Self.цвет(0xFFF0BF), средняя: Self.цвет(0xE2B85B), тёмная: Self.цвет(0x9A7130))
                : Грани(светлая: Self.цвет(0xFFE6A3), средняя: Self.цвет(0xD7AA4E), тёмная: Self.цвет(0x8C6428))
        case .bluedSteel:
            return тёмнаяТема
                ? Грани(светлая: Self.цвет(0x91A7C7), средняя: Self.цвет(0x33445E), тёмная: Self.цвет(0x121B29))
                : Грани(светлая: Self.цвет(0x6F83A2), средняя: Self.цвет(0x263247), тёмная: Self.цвет(0x0D1420))
        }
    }
}

private final class EqualizerView: NSView {
    /// Полный цикл пульсации лампы в секундах: заметно, но не тревожно.
    private let lockWarningPeriod: TimeInterval = 1.0
    private var level: Float = 0
    private var frameNumber: CGFloat = 0
    /// Толщина огранки в pt. 1,25 — базовое значение: при 1,0 три слоя
    /// металла не помещаются и рамка вырождается в линию; на @2x это 2,5 px.
    var bezelWidth: CGFloat = 1.25
    /// Множитель блика и тени огранки. 1,0 — как задано материалом.
    var bezelBrightness: CGFloat = 1.0
    var material: BezelMaterial = .gold

    /// Плотность стекла: пользовательская «прозрачность». Управляет только
    /// молочной тонировкой, не трогая размытие, огранку, полоски и лампу.
    var glassDensity: CGFloat = 0.30

    /// Тонировка стекла поверх размытия. Базовые цвета из таблицы палитры,
    /// но непрозрачность масштабируется плотностью: раньше она была
    /// фиксированной, а прозрачность гасила весь слой размытия.
    private func тонировка(тёмнаяТема: Bool) -> NSColor {
        // При стандартной прозрачности 30% тонировка равна 0,22 в светлой теме
        // и 0,18 в тёмной — значения из таблицы палитры. Настройка масштабирует
        // их пропорционально, поэтому 30% даёт ровно табличную плотность.
        let доля = min(1, max(0, glassDensity)) / 0.30
        return тёмнаяТема
            ? NSColor(srgbRed: 0xD8 / 255, green: 0xE0 / 255, blue: 0xEC / 255,
                      alpha: min(0.45, 0.18 * доля))
            : NSColor(srgbRed: 0xF2 / 255, green: 0xEE / 255, blue: 0xE6 / 255,
                      alpha: min(0.50, 0.22 * доля))
    }

    /// Вертикальный подсвет стекла: сверху светлее, снизу прозрачнее.
    /// Даёт эффект преломления на выпуклом срезе — без него тонировка
    /// выглядит равномерной плёнкой, а не стеклом.
    private func подсвет(тёмнаяТема: Bool) -> NSGradient? {
        // Блик держится у верхней грани и сходит на нет к 0,34 высоты.
        NSGradient(
            colors: [
                NSColor(white: 1, alpha: тёмнаяТема ? 0.10 : 0.14),
                NSColor(white: 1, alpha: 0),
                NSColor(white: 1, alpha: 0.04),
            ],
            atLocations: [0.0, 0.34, 1.0],
            colorSpace: .sRGB
        )
    }

    /// Внутренняя кромка стекла между огранкой и материалом. Табличные
    /// значения: 65% в светлой теме, 56% в тёмной.
    private func кромка(тёмнаяТема: Bool) -> NSColor {
        NSColor(white: 1, alpha: тёмнаяТема ? 0.56 : 0.65)
    }
    // Красная точка слева: запись зафиксирована двойным нажатием и идёт
    // без удержания клавиши. Без индикации режимы неотличимы.
    var locked = false
    // Момент, с которого лампа начинает мигать: до автоостановки осталось
    // меньше `lockWarningLead`. Пульсация — единственное предупреждение,
    // иначе зафиксированная запись обрывается молча.
    var lockWarningStartedAt: Date?

    func update(level: Float) {
        self.level = min(1, max(0, level))
        frameNumber += 1
        needsDisplay = true
    }

    /// Кольцо между двумя скруглёнными прямоугольниками. NSBezierPath не умеет
    /// градиентный stroke, а перевод линии в контур доступен только с macOS 14.
    private func кольцо(_ прямоугольник: NSRect, толщина: CGFloat) -> NSBezierPath {
        let путь = NSBezierPath()
        let внешний = прямоугольник
        let внутренний = прямоугольник.insetBy(dx: толщина, dy: толщина)
        путь.appendRoundedRect(
            внешний,
            xRadius: внешний.height / 2,
            yRadius: внешний.height / 2
        )
        путь.appendRoundedRect(
            внутренний,
            xRadius: max(0, внутренний.height / 2),
            yRadius: max(0, внутренний.height / 2)
        )
        путь.windingRule = .evenOdd
        return путь
    }

    /// Огранка из трёх слоёв. Основа занимает всю толщину, блик и тень
    /// накладываются локально по дуге, а не идут сплошной полосой по периметру:
    /// непрерывный яркий кант превращает металл в контур.
    /// Огранка из трёх слоёв: основа, локальный блик и контактная тень.
    /// Световая модель у металлов разная. Общий алгоритм
    /// `[средняя, тёмная, тёмная]` верен для воронёной стали, но золото от него
    /// становится бронзово-горчичным: тёмная грань захватывает почти всю рамку.
    private func рисуйОгранку(
        в область: NSRect,
        материал: BezelMaterial,
        грани: BezelMaterial.Грани,
        толщина: CGFloat
    ) {
        let кольцоОгранки = кольцо(область, толщина: толщина)

        // ── Слой 1: металлическая основа ──
        NSGraphicsContext.saveGraphicsState()
        кольцоОгранки.addClip()
        switch материал {
        case .gold:
            // Все три утверждённых оттенка. Среднее золото держится до 0,68 и
            // занимает основную площадь, тёмная грань собирается у нижнего
            // правого края. Градиент направлен явно из верхнего левого угла
            // в нижний правый, а не задан углом.
            NSGradient(
                colors: [грани.светлая, грани.средняя, грани.тёмная],
                atLocations: [0.0, 0.68, 1.0],
                colorSpace: .sRGB
            )?.draw(
                from: NSPoint(x: область.minX, y: область.maxY),
                to: NSPoint(x: область.maxX, y: область.minY),
                options: []
            )
        case .bluedSteel:
            // Полутон только в верхней трети, дальше почти чёрная основа:
            // сталь обязана остаться тёмным полированным металлом.
            NSGradient(
                colors: [грани.средняя, грани.тёмная, грани.тёмная],
                atLocations: [0.0, 0.32, 1.0],
                colorSpace: .sRGB
            )?.draw(in: область, angle: -70)
        }
        NSGraphicsContext.restoreGraphicsState()

        // ── Слой 2: блик ──
        NSGraphicsContext.saveGraphicsState()
        кольцоОгранки.addClip()
        switch материал {
        case .gold:
            // Широкий шампанский блик вдоль верхней и верхней левой грани,
            // а не светлая точка у левого края.
            let центр = NSPoint(x: область.minX + область.width * 0.25,
                                y: область.maxY - область.height * 0.05)
            NSGradient(
                colors: [
                    грани.светлая.withAlphaComponent(min(1, bezelBrightness)),
                    грани.светлая.withAlphaComponent(0.55 * bezelBrightness),
                    грани.светлая.withAlphaComponent(0),
                ],
                atLocations: [0.0, 0.55, 1.0],
                colorSpace: .sRGB
            )?.draw(
                fromCenter: центр, radius: 0,
                toCenter: центр, radius: область.width * 0.55,
                options: []
            )
        case .bluedSteel:
            // Холодный блик чуть шире прежнего, но по-прежнему узкий
            // и локальный: осветлять всю рамку нельзя.
            let центр = NSPoint(x: область.minX + область.width * 0.22,
                                y: область.maxY - область.height * 0.06)
            NSGradient(
                colors: [
                    грани.светлая.withAlphaComponent(min(1, bezelBrightness)),
                    грани.светлая.withAlphaComponent(0.35 * bezelBrightness),
                    грани.светлая.withAlphaComponent(0),
                ],
                atLocations: [0.0, 0.42, 1.0],
                colorSpace: .sRGB
            )?.draw(
                fromCenter: центр, radius: 0,
                toCenter: центр, radius: max(область.height * 1.6, область.width * 0.16),
                options: []
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        // ── Слой 3: контактная тень снизу-справа ──
        NSGraphicsContext.saveGraphicsState()
        кольцоОгранки.addClip()
        let центрТени = NSPoint(x: область.maxX - область.width * 0.22,
                                y: область.minY + область.height * 0.14)
        switch материал {
        case .gold:
            // Тень приглушена: на полной непрозрачности тёмная грань
            // перекрашивала бóльшую часть рамки в коричневый.
            NSGradient(
                colors: [
                    грани.тёмная.withAlphaComponent(0.55 * bezelBrightness),
                    грани.тёмная.withAlphaComponent(0.15 * bezelBrightness),
                    грани.тёмная.withAlphaComponent(0),
                ],
                atLocations: [0.0, 0.48, 1.0],
                colorSpace: .sRGB
            )?.draw(
                fromCenter: центрТени, radius: 0,
                toCenter: центрТени, radius: область.width * 0.38,
                options: []
            )
        case .bluedSteel:
            NSGradient(
                colors: [
                    грани.тёмная,
                    грани.тёмная.withAlphaComponent(0.30 * bezelBrightness),
                    грани.тёмная.withAlphaComponent(0),
                ],
                atLocations: [0.0, 0.5, 1.0],
                colorSpace: .sRGB
            )?.draw(
                fromCenter: центрТени, radius: 0,
                toCenter: центрТени, radius: область.width * 0.38,
                options: []
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let тёмнаяТема = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let грани = material.грани(тёмнаяТема: тёмнаяТема)

        // Огранка — градиент по диагонали, а не однотонная линия: без перехода
        // от светлой грани к тёмной рамка читается как нарисованный жёлтый
        // контур, что спецификация прямо запрещает.
        // Слой 3: молочная диффузия. Ложится поверх размытия и придаёт стеклу
        // плотность — без неё на цветном фоне пилюля выглядит просто размытием.
        let стекло = NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        тонировка(тёмнаяТема: тёмнаяТема).setFill()
        стекло.fill()

        // Преломление: светлее у верхней кромки, прозрачнее к середине.
        NSGraphicsContext.saveGraphicsState()
        стекло.addClip()
        подсвет(тёмнаяТема: тёмнаяТема)?.draw(in: bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Слой 4: внутренняя кромка — тонкая светлая линия сразу под огранкой.
        // Она отделяет металл от стекла и даёт эффект преломления на срезе.
        let кромкаRect = bounds.insetBy(dx: bezelWidth + 0.5, dy: bezelWidth + 0.5)
        let линияКромки = NSBezierPath(
            roundedRect: кромкаRect,
            xRadius: кромкаRect.height / 2,
            yRadius: кромкаRect.height / 2
        )
        линияКромки.lineWidth = 0.5
        кромка(тёмнаяТема: тёмнаяТема).setStroke()
        линияКромки.stroke()

        // Слой 5: огранка. Один градиентный штрих читался как плоская линия,
        // поэтому металл собирается из трёх слоёв: основа во всю толщину,
        // локальный блик сверху-слева и контактная тень снизу-справа.
        рисуйОгранку(в: bounds, материал: material, грани: грани, толщина: bezelWidth)

        NSColor(white: 1, alpha: 0xEB / 255).setFill()
        let barWidth: CGFloat = 4
        let gap: CGFloat = 8
        let startX = (bounds.width - (barWidth * 5 + gap * 4)) / 2
        for index in 0..<5 {
            let phase = sin(frameNumber * 0.55 + CGFloat(index) * 1.15) * 0.5 + 0.5
            let height = 3 + CGFloat(level) * 16 * (0.35 + 0.65 * phase)
            let rect = NSRect(
                x: startX + CGFloat(index) * (barWidth + gap),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
        }

        if locked {
            let diameter: CGFloat = 6
            let dot = NSRect(
                x: bounds.minX + bounds.height / 2 - diameter / 2,
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            // Пульсация считается от реального времени, а не от номера кадра:
            // кадры приходят от таймера микрофона и могут запаздывать, а
            // предупреждение обязано идти ровно и совпадать с обратным отсчётом.
            var crystalAlpha: CGFloat = 1
            if let startedAt = lockWarningStartedAt {
                let elapsed = Date().timeIntervalSince(startedAt)
                let cycle = sin(elapsed * .pi * 2 / lockWarningPeriod)
                crystalAlpha = 0.25 + 0.75 * (cycle * 0.5 + 0.5)
            }

            // Оправа лампы огранена тем же способом, что и наружная рамка, и
            // тем же материалом. Непрозрачность держит 1,0 всегда: пульсирует
            // только рубин. Если гасить лампу целиком, на светлом фоне она в
            // нижней точке пропадает, и предупреждение читается как сбой отрисовки.
            let оправа = dot.insetBy(dx: -1.6, dy: -1.6)
            рисуйОгранку(в: оправа, материал: material, грани: грани, толщина: 1.25)

            // Рубин: согласованный цвет из палитры вместо системного красного,
            // который меняется вместе с системным акцентом.
            let рубин = тёмнаяТема
                ? NSColor(srgbRed: 0xE0 / 255, green: 0x46 / 255, blue: 0x52 / 255, alpha: 1)
                : NSColor(srgbRed: 0xC9 / 255, green: 0x2F / 255, blue: 0x3D / 255, alpha: 1)

            // Небольшой локальный ореол вокруг кристалла. Радиус чуть больше
            // самого рубина — подсветка на срезе стекла, не неоновое свечение.
            let ореол = NSGradient(
                colors: [
                    рубин.withAlphaComponent(0.42 * crystalAlpha),
                    рубин.withAlphaComponent(0),
                ],
                atLocations: [0, 1],
                colorSpace: .sRGB
            )
            let центр = NSPoint(x: dot.midX, y: dot.midY)
            NSGraphicsContext.saveGraphicsState()
            ореол?.draw(
                fromCenter: центр, radius: diameter * 0.4,
                toCenter: центр, radius: diameter * 1.5,
                options: []
            )
            NSGraphicsContext.restoreGraphicsState()

            рубин.withAlphaComponent(crystalAlpha).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}

private final class OverlayPreferences {
    private enum Key {
        static let styleVersion = "overlay.styleVersion"
        static let width = "overlay.width"
        static let height = "overlay.height"
        static let opacity = "overlay.opacity"
        static let bezelMaterial = "overlay.bezelMaterial"
        static let borderWidth = "overlay.borderWidth"
        static let borderBrightness = "overlay.borderBrightness"
        static let shadow = "overlay.shadow"
        static let shadowOpacity = "overlay.shadowOpacity"
        static let shadowRadius = "overlay.shadowRadius"
        static let shadowOffsetY = "overlay.shadowOffsetY"
        static let bottomOffset = "overlay.bottomOffset"
        static let material = "overlay.material"
    }

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            Key.width: 100.0, Key.height: 30.0, Key.opacity: 0.30,
            Key.bezelMaterial: BezelMaterial.gold.rawValue,
            Key.borderWidth: 1.25, Key.borderBrightness: 1.0,
            Key.shadow: true,
            Key.shadowOpacity: 0.17952991522530728,
            Key.shadowRadius: 8.392724578971325,
            Key.shadowOffsetY: -2.0,
            Key.bottomOffset: 120.0,
            Key.material: 0,
        ])
        // Версия 6 — переход на новую визуальную систему. Прежние преднастройки
        // не сохраняются: огранка больше не настраивается вручную, а старые
        // значения толщины и яркости рамки не имеют соответствия в новой модели.
        if defaults.integer(forKey: Key.styleVersion) < 6 {
            for ключ in [
                Key.width, Key.height, Key.opacity, Key.shadow,
                Key.shadowOpacity, Key.shadowRadius, Key.shadowOffsetY,
                Key.bottomOffset, Key.material, Key.bezelMaterial,
                Key.borderWidth, Key.borderBrightness,
            ] {
                defaults.removeObject(forKey: ключ)
            }
            defaults.set(6, forKey: Key.styleVersion)
        }
    }

    var width: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.width)) }
        set { defaults.set(Double(newValue), forKey: Key.width) }
    }
    var height: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.height)) }
        set { defaults.set(Double(newValue), forKey: Key.height) }
    }
    var opacity: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.opacity)) }
        set { defaults.set(Double(newValue), forKey: Key.opacity) }
    }
    /// Толщина огранки в pt. Влияет на все три слоя металла разом.
    var borderWidth: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.borderWidth)) }
        set { defaults.set(Double(newValue), forKey: Key.borderWidth) }
    }
    /// Интенсивность блика и тени огранки. 1,0 — как задано материалом.
    var borderBrightness: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.borderBrightness)) }
        set { defaults.set(Double(newValue), forKey: Key.borderBrightness) }
    }
    var bezelMaterial: BezelMaterial {
        get { BezelMaterial(rawValue: defaults.integer(forKey: Key.bezelMaterial)) ?? .gold }
        set { defaults.set(newValue.rawValue, forKey: Key.bezelMaterial) }
    }
    var shadow: Bool {
        get { defaults.bool(forKey: Key.shadow) }
        set { defaults.set(newValue, forKey: Key.shadow) }
    }
    var shadowOpacity: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.shadowOpacity)) }
        set { defaults.set(Double(newValue), forKey: Key.shadowOpacity) }
    }
    var shadowRadius: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.shadowRadius)) }
        set { defaults.set(Double(newValue), forKey: Key.shadowRadius) }
    }
    var shadowOffsetY: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.shadowOffsetY)) }
        set { defaults.set(Double(newValue), forKey: Key.shadowOffsetY) }
    }
    var bottomOffset: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.bottomOffset)) }
        set { defaults.set(Double(newValue), forKey: Key.bottomOffset) }
    }
    var materialIndex: Int {
        get { defaults.integer(forKey: Key.material) }
        set { defaults.set(newValue, forKey: Key.material) }
    }
    var material: NSVisualEffectView.Material {
        switch materialIndex {
        case 1: return .hudWindow
        case 2: return .windowBackground
        case 3: return .contentBackground
        // .sidebar подмешивает собственную тонировку и уводит стекло в
        // серо-зелёный, .fullScreenUI кладёт плотную серую подложку.
        // .underWindowBackground пропускает фон лучше всех при сохранении
        // размытия — замер на пёстром фоне: R74 против R76 рядом.
        default: return .underWindowBackground
        }
    }

    func apply(width: CGFloat, height: CGFloat, opacity: CGFloat, borderWidth: CGFloat,
               borderBrightness: CGFloat, shadow: Bool, materialIndex: Int = 0) {
        self.width = width
        self.height = height
        self.opacity = opacity
        self.borderWidth = borderWidth
        self.borderBrightness = borderBrightness
        self.shadow = shadow
        self.materialIndex = materialIndex
    }
}

private final class RecordingOverlay {
    // Достаточно места для максимального blur 20 pt и смещения до 10 pt,
    // чтобы внешняя тень не обрезалась границами прозрачного NSPanel.
    private let shadowPadding: CGFloat = 36
    private let settings: OverlayPreferences
    private let panel: NSPanel
    private let equalizer = EqualizerView()
    private let effect = NSVisualEffectView()
    private let shadowView = NSView()
    private let container = NSView()
    // Страховка на случай, если кто-то встанет на наш уровень: внутри одного
    // уровня выигрывает показавшийся последним, а одного orderFrontRegardless
    // при старте записи не хватает — держим панель наверху всю запись.
    private var topmostTimer: Timer?
    private var warningTimer: Timer?
    private var spaceObserver: NSObjectProtocol?

    init(settings: OverlayPreferences) {
        self.settings = settings
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // screenSaverWindow (1000) занят чужими оверлеями — там же сидит Wispr
        // Flow. Внутри одного уровня выигрывает показавшийся последним, поэтому
        // берём assistiveTechHighWindow (1500): выше всех обычных оверлеев.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        // .stationary конфликтует с .canJoinAllSpaces: панель должна следовать
        // за активным Space, а не оставаться на своём. .ignoresCycle убирает
        // её из Cmd-Tab / Exposé.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Стандартная NSPanel-тень слишком тяжёлая на прозрачной пилюле.
        panel.hasShadow = false

        shadowView.wantsLayer = true
        effect.blendingMode = .behindWindow
        effect.state = .active
        // Тему не фиксируем: палитра стекла задана отдельно для светлой и
        // тёмной, а жёсткий vibrantDark заставлял бы размытие всегда быть
        // тёмным и спорить с молочной тонировкой в светлой теме.
        effect.appearance = nil
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        container.addSubview(shadowView)
        container.addSubview(effect)
        container.addSubview(equalizer)
        panel.contentView = container
        applySettings()
    }

    func applySettings() {
        let panelSize = NSSize(
            width: settings.width + shadowPadding * 2,
            height: settings.height + shadowPadding * 2
        )
        let panelFrame = NSRect(origin: .zero, size: panelSize)
        let pillFrame = NSRect(
            x: shadowPadding, y: shadowPadding,
            width: settings.width, height: settings.height
        )
        panel.setContentSize(panelSize)
        container.frame = panelFrame
        shadowView.frame = panelFrame
        effect.frame = pillFrame
        equalizer.frame = pillFrame
        effect.material = settings.material
        // alphaValue не связан с пользовательской прозрачностью: она управляет
        // плотностью тонировки. Здесь фиксированное значение, чуть смягчающее
        // системную подложку, чтобы фон проходил сквозь стекло.
        effect.alphaValue = 0.64
        equalizer.glassDensity = settings.opacity
        effect.layer?.cornerRadius = settings.height / 2
        equalizer.material = settings.bezelMaterial
        equalizer.bezelWidth = max(0.5, settings.borderWidth)
        equalizer.bezelBrightness = settings.borderBrightness
        equalizer.needsDisplay = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = settings.shadow ? Float(settings.shadowOpacity) : 0
        shadowView.layer?.shadowRadius = settings.shadowRadius
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: settings.shadowOffsetY)
        let pillPath = CGPath(
            roundedRect: pillFrame,
            cornerWidth: settings.height / 2,
            cornerHeight: settings.height / 2,
            transform: nil
        )
        shadowView.layer?.shadowPath = pillPath

        // Вырезаем середину: иначе тень лежит под полупрозрачным material
        // и воспринимается как ещё один тёмный фон внутри пилюли.
        let outside = CGMutablePath()
        outside.addRect(panelFrame)
        outside.addPath(pillPath)
        let mask = CAShapeLayer()
        mask.frame = panelFrame
        mask.path = outside
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        shadowView.layer?.mask = mask
        if panel.isVisible { position() }
    }

    func show() {
        position()
        panel.orderFrontRegardless()
        startKeepingOnTop()
    }

    private func startKeepingOnTop() {
        stopKeepingOnTop()
        // Секунда — незаметно для глаза, но не нагружает оконный сервер.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.raise()
        }
        RunLoop.main.add(timer, forMode: .common)
        topmostTimer = timer

        // Переключение Space роняет панель под окна нового рабочего стола.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.position()
            self?.raise()
        }
    }

    private func stopKeepingOnTop() {
        topmostTimer?.invalidate()
        topmostTimer = nil
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
    }

    private func raise() {
        guard panel.isVisible else { return }
        // Переприсваивание level вместе с orderFrontRegardless возвращает панель
        // поверх окон, вставших выше нас внутри того же уровня.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.orderFrontRegardless()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - settings.width / 2 - shadowPadding,
            y: frame.minY + settings.bottomOffset - shadowPadding
        ))
    }

    func hide() {
        // Каждый показ начинается незафиксированным: фиксация включается
        // явно двойным нажатием, а скрытие всегда завершает запись.
        setLocked(false)
        setLockWarning(false)
        stopKeepingOnTop()
        panel.orderOut(nil)
    }

    func setLocked(_ flag: Bool) {
        equalizer.locked = flag
        if !flag { setLockWarning(false) }
        equalizer.needsDisplay = true
    }

    /// Включает пульсацию лампы перед автоостановкой зафиксированной записи.
    func setLockWarning(_ flag: Bool) {
        guard flag else {
            warningTimer?.invalidate()
            warningTimer = nil
            equalizer.lockWarningStartedAt = nil
            equalizer.needsDisplay = true
            return
        }
        guard warningTimer == nil else { return }
        equalizer.lockWarningStartedAt = Date()
        // Перерисовку оверлея двигает уровень микрофона, а он приходит только
        // при звуке. В тишине лампа замерла бы на полукадре, поэтому на время
        // предупреждения заводим собственный тик.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.equalizer.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        warningTimer = timer
    }

    func update(level: Float) { equalizer.update(level: level) }
}

private final class OverlaySettingsController: NSObject, NSWindowDelegate {
    private struct Preset {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let bottomOffset: CGFloat
        let opacity: CGFloat
        let borderWidth: CGFloat
        let borderBrightness: CGFloat
        let shadow: Bool
        let shadowOpacity: CGFloat
        let shadowRadius: CGFloat
        let shadowOffsetY: CGFloat
        let materialIndex: Int
        let bezel: BezelMaterial
    }

    // Преднастройки новой визуальной системы. Прежние не переносятся: они
    // задавали толщину и яркость рамки, которых больше нет.
    private let presets = [
        Preset(name: "Золотая огранка · базовая", width: 100, height: 30, bottomOffset: 120,
               opacity: 0.30, borderWidth: 1.25, borderBrightness: 1.0, shadow: true, shadowOpacity: 0.18, shadowRadius: 8.4,
               shadowOffsetY: -2, materialIndex: 0, bezel: .gold),
        Preset(name: "Воронёная сталь", width: 100, height: 30, bottomOffset: 120,
               opacity: 0.30, borderWidth: 1.25, borderBrightness: 1.0, shadow: true, shadowOpacity: 0.18, shadowRadius: 8.4,
               shadowOffsetY: -2, materialIndex: 0, bezel: .bluedSteel),
        Preset(name: "Крупная пилюля", width: 132, height: 38, bottomOffset: 126,
               opacity: 0.28, borderWidth: 1.25, borderBrightness: 1.0, shadow: true, shadowOpacity: 0.14, shadowRadius: 12,
               shadowOffsetY: -3, materialIndex: 0, bezel: .gold),
        Preset(name: "Без тени", width: 100, height: 30, bottomOffset: 120,
               opacity: 0.30, borderWidth: 1.25, borderBrightness: 1.0, shadow: false, shadowOpacity: 0, shadowRadius: 8,
               shadowOffsetY: -2, materialIndex: 0, bezel: .gold),
    ]

    private let settings: OverlayPreferences
    private let overlay: RecordingOverlay
    private let window: NSWindow
    private let widthSlider = NSSlider(value: 100, minValue: 80, maxValue: 220, target: nil, action: nil)
    private let heightSlider = NSSlider(value: 30, minValue: 24, maxValue: 70, target: nil, action: nil)
    private let bottomOffsetSlider = NSSlider(value: 120, minValue: 50, maxValue: 240, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 0.30, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let bezelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let borderSlider = NSSlider(value: 1.25, minValue: 0.5, maxValue: 3, target: nil, action: nil)
    private let brightnessSlider = NSSlider(value: 1.0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let shadowButton = NSButton(checkboxWithTitle: "Тень", target: nil, action: nil)
    private let shadowOpacitySlider = NSSlider(value: 0.16, minValue: 0, maxValue: 0.5, target: nil, action: nil)
    private let shadowRadiusSlider = NSSlider(value: 8, minValue: 2, maxValue: 20, target: nil, action: nil)
    private let shadowOffsetSlider = NSSlider(value: -2, minValue: -10, maxValue: 6, target: nil, action: nil)
    private let materialPopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private var valueLabels: [NSTextField] = []
    var onClose: (() -> Void)?

    init(settings: OverlayPreferences, overlay: RecordingOverlay) {
        self.settings = settings
        self.overlay = overlay
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 730),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Настройка оверлея"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.delegate = self
        configureControls()
        loadValues()
    }

    func show() {
        loadValues()
        overlay.applySettings()
        overlay.show()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func configureControls() {
        guard let view = window.contentView else { return }
        let title = NSTextField(labelWithString: "Индикатор записи")
        title.font = .boldSystemFont(ofSize: 20)
        title.frame = NSRect(x: 24, y: 682, width: 440, height: 28)
        view.addSubview(title)

        let hint = NSTextField(labelWithString: "Настройте стекло, огранку и тень — результат сразу виден внизу экрана.")
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 654, width: 452, height: 20)
        view.addSubview(hint)

        addSection("ПРЕСЕТ", y: 620)
        presetPopup.addItems(withTitles: presets.map(\.name) + ["Пользовательский"])
        presetPopup.frame = NSRect(x: 24, y: 586, width: 452, height: 30)
        presetPopup.target = self
        presetPopup.action = #selector(applyPreset)
        view.addSubview(presetPopup)

        addSection("ГЕОМЕТРИЯ", y: 556)
        addRow(title: "Ширина", slider: widthSlider, y: 516)
        addRow(title: "Высота", slider: heightSlider, y: 476)
        addRow(title: "Отступ снизу", slider: bottomOffsetSlider, y: 436)

        addSection("СТЕКЛО", y: 402)
        let materialLabel = NSTextField(labelWithString: "Материал")
        materialLabel.frame = NSRect(x: 24, y: 367, width: 160, height: 20)
        view.addSubview(materialLabel)

        materialPopup.addItems(withTitles: ["Sidebar · мягкий", "HUD · контрастный", "Окно", "Контент"])
        materialPopup.frame = NSRect(x: 190, y: 363, width: 226, height: 28)
        materialPopup.target = self
        materialPopup.action = #selector(valuesChanged)
        view.addSubview(materialPopup)
        addRow(title: "Плотность", slider: opacitySlider, y: 328)

        addSection("ОГРАНКА", y: 294)
        let bezelTitle = NSTextField(labelWithString: "Материал")
        bezelTitle.frame = NSRect(x: 24, y: 254, width: 160, height: 20)
        view.addSubview(bezelTitle)
        bezelPopup.addItems(withTitles: BezelMaterial.allCases.map(\.title))
        bezelPopup.frame = NSRect(x: 190, y: 250, width: 226, height: 28)
        bezelPopup.target = self
        bezelPopup.action = #selector(valuesChanged)
        view.addSubview(bezelPopup)
        addRow(title: "Толщина", slider: borderSlider, y: 214)
        addRow(title: "Яркость", slider: brightnessSlider, y: 178)

        addSection("ТЕНЬ", y: 180, lineWidth: 250)
        shadowButton.frame = NSRect(x: 392, y: 176, width: 84, height: 24)
        shadowButton.target = self
        shadowButton.action = #selector(valuesChanged)
        view.addSubview(shadowButton)
        addRow(title: "Интенсивность", slider: shadowOpacitySlider, y: 140)
        addRow(title: "Размытие", slider: shadowRadiusSlider, y: 100)
        addRow(title: "Смещение по Y", slider: shadowOffsetSlider, y: 60)

        let close = NSButton(title: "Готово", target: window, action: #selector(NSWindow.close))
        close.keyEquivalent = "\r"
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 378, y: 16, width: 98, height: 30)
        view.addSubview(close)
    }

    private func addSection(_ title: String, y: CGFloat, lineWidth: CGFloat = 364) {
        guard let view = window.contentView else { return }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 24, y: y, width: 180, height: 18)
        view.addSubview(label)
        let line = NSBox(frame: NSRect(x: 112, y: y + 8, width: lineWidth, height: 1))
        line.boxType = .separator
        view.addSubview(line)
    }

    private func addRow(title: String, slider: NSSlider, y: CGFloat) {
        guard let view = window.contentView else { return }
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 24, y: y, width: 155, height: 20)
        view.addSubview(label)
        slider.frame = NSRect(x: 190, y: y - 3, width: 226, height: 24)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(valuesChanged)
        view.addSubview(slider)
        let value = NSTextField(labelWithString: "")
        value.alignment = .right
        value.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.frame = NSRect(x: 420, y: y, width: 56, height: 20)
        view.addSubview(value)
        valueLabels.append(value)
    }

    private func loadValues() {
        widthSlider.doubleValue = Double(settings.width)
        heightSlider.doubleValue = Double(settings.height)
        bottomOffsetSlider.doubleValue = Double(settings.bottomOffset)
        opacitySlider.doubleValue = Double(settings.opacity)
        bezelPopup.selectItem(at: settings.bezelMaterial.rawValue)
        borderSlider.doubleValue = Double(settings.borderWidth)
        brightnessSlider.doubleValue = Double(settings.borderBrightness)
        shadowButton.state = settings.shadow ? .on : .off
        shadowOpacitySlider.doubleValue = Double(settings.shadowOpacity)
        shadowRadiusSlider.doubleValue = Double(settings.shadowRadius)
        shadowOffsetSlider.doubleValue = Double(settings.shadowOffsetY)
        materialPopup.selectItem(at: min(settings.materialIndex, materialPopup.numberOfItems - 1))
        presetPopup.selectItem(at: matchingPresetIndex() ?? presets.count)
        updateShadowControls()
        updateLabels()
    }

    private func matchingPresetIndex() -> Int? {
        presets.firstIndex { preset in
            abs(preset.width - settings.width) < 0.1 &&
            abs(preset.height - settings.height) < 0.1 &&
            abs(preset.bottomOffset - settings.bottomOffset) < 0.1 &&
            abs(preset.opacity - settings.opacity) < 0.001 &&
            preset.bezel == settings.bezelMaterial &&
            abs(preset.borderWidth - settings.borderWidth) < 0.001 &&
            abs(preset.borderBrightness - settings.borderBrightness) < 0.001 &&
            preset.shadow == settings.shadow &&
            abs(preset.shadowOpacity - settings.shadowOpacity) < 0.001 &&
            abs(preset.shadowRadius - settings.shadowRadius) < 0.01 &&
            abs(preset.shadowOffsetY - settings.shadowOffsetY) < 0.01 &&
            preset.materialIndex == settings.materialIndex
        }
    }

    @objc private func valuesChanged() {
        settings.apply(
            width: CGFloat(widthSlider.doubleValue.rounded()),
            height: CGFloat(heightSlider.doubleValue.rounded()),
            opacity: CGFloat(opacitySlider.doubleValue),
            borderWidth: CGFloat(borderSlider.doubleValue),
            borderBrightness: CGFloat(brightnessSlider.doubleValue),
            shadow: shadowButton.state == .on,
            materialIndex: materialPopup.indexOfSelectedItem
        )
        settings.bezelMaterial = BezelMaterial(rawValue: bezelPopup.indexOfSelectedItem) ?? .gold
        settings.shadowOpacity = CGFloat(shadowOpacitySlider.doubleValue)
        settings.shadowRadius = CGFloat(shadowRadiusSlider.doubleValue)
        settings.shadowOffsetY = CGFloat(shadowOffsetSlider.doubleValue)
        settings.bottomOffset = CGFloat(bottomOffsetSlider.doubleValue.rounded())
        presetPopup.selectItem(at: presets.count)
        updateShadowControls()
        updateLabels()
        overlay.applySettings()
        overlay.show()
    }

    @objc private func applyPreset() {
        guard presetPopup.indexOfSelectedItem < presets.count else { return }
        let preset = presets[presetPopup.indexOfSelectedItem]
        settings.apply(
            width: preset.width,
            height: preset.height,
            opacity: preset.opacity,
            borderWidth: preset.borderWidth,
            borderBrightness: preset.borderBrightness,
            shadow: preset.shadow,
            materialIndex: preset.materialIndex
        )
        settings.bezelMaterial = preset.bezel
        settings.bottomOffset = preset.bottomOffset
        settings.shadowOpacity = preset.shadowOpacity
        settings.shadowRadius = preset.shadowRadius
        settings.shadowOffsetY = preset.shadowOffsetY
        loadValues()
        overlay.applySettings()
        overlay.show()
    }

    private func updateShadowControls() {
        let enabled = shadowButton.state == .on
        shadowOpacitySlider.isEnabled = enabled
        shadowRadiusSlider.isEnabled = enabled
        shadowOffsetSlider.isEnabled = enabled
    }

    private func updateLabels() {
        guard valueLabels.count == 9 else { return }
        valueLabels[0].stringValue = "\(Int(widthSlider.doubleValue.rounded())) px"
        valueLabels[1].stringValue = "\(Int(heightSlider.doubleValue.rounded())) px"
        valueLabels[2].stringValue = "\(Int(bottomOffsetSlider.doubleValue.rounded())) px"
        valueLabels[3].stringValue = "\(Int(opacitySlider.doubleValue * 100))%"
        valueLabels[4].stringValue = String(format: "%.2f pt", borderSlider.doubleValue)
        valueLabels[5].stringValue = "\(Int(brightnessSlider.doubleValue * 100))%"
        valueLabels[6].stringValue = "\(Int(shadowOpacitySlider.doubleValue * 100))%"
        valueLabels[7].stringValue = String(format: "%.1f px", shadowRadiusSlider.doubleValue)
        valueLabels[8].stringValue = String(format: "%.1f px", shadowOffsetSlider.doubleValue)
    }
}

private struct HistoryEntry: Codable {
    let date: Date
    let text: String
}

private final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Chirper", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url) {
            entries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    func add(_ text: String) {
        entries.insert(HistoryEntry(date: Date(), text: text), at: 0)
        entries = Array(entries.prefix(20))
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}

private final class FileLogger {
    static let shared = FileLogger()
    private let url: URL

    private init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = library.appendingPathComponent("Logs/Chirper", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("asr.log")
    }

    func write(_ text: String) {
        let data = Data(text.utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// Значки строки меню: отрисованы дизайном и лежат в бандле готовыми.
/// Все шесть монохромные, поэтому включаются в `template`-режим — строка меню
/// сама красит их под тему и подсветку, отдельные светлый и тёмный варианты
/// не нужны.
private enum StatusIcon {
    /// Строка меню работает в пунктах: значок нарисован на сетке 18 × 18 pt,
    /// а в бандле лежит @2x. Без явного размера AppKit взял бы пиксельный
    /// и значок оказался бы вдвое крупнее системных соседей.
    private static let size = NSSize(width: 18, height: 18)
    private static var кэш: [String: NSImage] = [:]

    private static func значок(_ имя: String) -> NSImage? {
        if let готовый = кэш[имя] { return готовый }
        guard let url = Bundle.main.url(
            forResource: имя,
            withExtension: "png",
            subdirectory: "Значки"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.size = size
        image.isTemplate = true
        кэш[имя] = image
        return image
    }

    static func loading() -> NSImage? { значок("menu-loading") }
    static func ready() -> NSImage? { значок("menu-ready") }
    static func recording() -> NSImage? { значок("menu-recording") }
    static func locked() -> NSImage? { значок("menu-locked") }
    static func transcribing() -> NSImage? { значок("menu-transcribing") }
    static func failed() -> NSImage? { значок("menu-failed") }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenuItem = NSMenuItem(title: "Запускаю модель…", action: nil, keyEquivalent: "")
    private let lastMenuItem = NSMenuItem(title: "Последняя надиктовка", action: nil, keyEquivalent: "")
    private let soundMenuItem = NSMenuItem(title: "Звук", action: nil, keyEquivalent: "")
    private let recorder = MicrophoneRecorder()
    private let hotkey = HotkeyMonitor()
    private let overlayPreferences = OverlayPreferences()
    private lazy var overlay = RecordingOverlay(settings: overlayPreferences)
    private lazy var overlaySettings = OverlaySettingsController(
        settings: overlayPreferences,
        overlay: overlay
    )
    private let history = HistoryStore()
    private var worker: ASRWorker?
    private var state = AppState.loading
    private var recordingURL: URL?
    private var soundsEnabled = true

    // Жест хоткея. Удержание — запись, пока держишь (как всегда было).
    // Два быстрых нажатия фиксируют запись: она идёт без удержания, следующее
    // нажатие — стоп. Запись стартует сразу по первому нажатию, порог ждёт
    // только второе нажатие — иначе каждая диктовка начиналась бы с задержки.
    private enum HotkeyGesture {
        case idle        // записи нет
        case held        // запись на удержании
        case tapPending  // клавишу быстро отпустили — ждём второе нажатие
        case locked      // запись зафиксирована двойным нажатием
    }

    private var gesture = HotkeyGesture.idle
    private var pressStartedAt = Date.distantPast
    private var tapTimer: Timer?
    private let tapThreshold: TimeInterval = 0.35
    // Страховка от забытой записи: фиксация сама завершается распознаванием.
    private let lockedRecordingLimit: TimeInterval = 10 * 60
    /// За сколько до автоостановки лампа начинает мигать.
    private let lockWarningLead: TimeInterval = 30
    private var lockLimitTimer: Timer?
    private var lockWarningTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        requestAccessibility()
        recorder.onLevel = { [weak self] level in self?.overlay.update(level: level) }
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.start()
        recorder.requestPermission { _ in }
        startWorker()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        _ = recorder.stop()
        worker?.stop()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
    }

    private func configureMenu() {
        statusItem.button?.image = StatusIcon.ready()

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        lastMenuItem.target = self
        lastMenuItem.action = #selector(copyLast)
        menu.addItem(lastMenuItem)
        let historyItem = NSMenuItem(title: "История…", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        menu.addItem(.separator())
        let overlayItem = NSMenuItem(
            title: "Настроить оверлей…",
            action: #selector(showOverlaySettings),
            keyEquivalent: ""
        )
        overlayItem.target = self
        menu.addItem(overlayItem)
        soundMenuItem.target = self
        soundMenuItem.action = #selector(toggleSound)
        soundMenuItem.state = .on
        menu.addItem(soundMenuItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func startWorker() {
        let worker = ASRWorker()
        worker.onReady = { [weak self] in self?.setState(.ready) }
        worker.onResult = { [weak self] text, url in self?.received(text: text, file: url) }
        worker.onError = { [weak self] error, url in
            if let url { try? FileManager.default.removeItem(at: url) }
            if url == nil {
                self?.setState(.failed(error))
            } else {
                self?.showAlert(message: "Не удалось распознать", details: error)
                self?.setState(.ready)
            }
            self?.play("Basso")
        }
        self.worker = worker
        do { try worker.start() } catch { setState(.failed(error.localizedDescription)) }
    }

    private func hotkeyPressed() {
        switch gesture {
        case .idle:
            pressStartedAt = Date()
            startRecording()
            // Запись могла не начаться (модель грузится, нет микрофона) —
            // тогда жест не переводим, иначе появится фантомное состояние.
            if case .recording = state { gesture = .held }
        case .tapPending:
            tapTimer?.invalidate()
            tapTimer = nil
            gesture = .locked
            overlay.setLocked(true)
            setState(.lockedRecording)
            startLockLimitTimer()
        case .locked:
            finishLockedRecording()
        case .held:
            // Невозможно: повторный press приходит только после release.
            break
        }
    }

    private func hotkeyReleased() {
        switch gesture {
        case .held:
            if Date().timeIntervalSince(pressStartedAt) < tapThreshold {
                // Быстрое отпускание — возможно, первая половина двойного
                // нажатия. Запись продолжается, ждём второе нажатие.
                gesture = .tapPending
                let timer = Timer(timeInterval: tapThreshold, repeats: false) { [weak self] _ in
                    guard let self, case .tapPending = self.gesture else { return }
                    self.tapTimer = nil
                    self.gesture = .idle
                    // Одиночный быстрый тап — случайность: раньше такая запись
                    // отсеивалась порогом длительности, но за время ожидания
                    // второго нажатия она успевает его перерасти. Отменяем явно.
                    self.cancelRecording()
                }
                RunLoop.main.add(timer, forMode: .common)
                tapTimer = timer
            } else {
                gesture = .idle
                stopRecording()
            }
        case .locked, .tapPending, .idle:
            // Отпускание второго нажатия (фиксация) и третьего (стоп) —
            // не команды: иначе фиксация выключалась бы сразу после включения.
            break
        }
    }

    private func finishLockedRecording() {
        lockLimitTimer?.invalidate()
        lockLimitTimer = nil
        lockWarningTimer?.invalidate()
        lockWarningTimer = nil
        gesture = .idle
        stopRecording()
    }

    private func startLockLimitTimer() {
        lockLimitTimer?.invalidate()
        lockWarningTimer?.invalidate()
        let timer = Timer(timeInterval: lockedRecordingLimit, repeats: false) { [weak self] _ in
            guard let self, case .locked = self.gesture else { return }
            self.lockLimitTimer = nil
            self.finishLockedRecording()
        }
        RunLoop.main.add(timer, forMode: .common)
        lockLimitTimer = timer

        let warning = Timer(
            timeInterval: lockedRecordingLimit - lockWarningLead,
            repeats: false
        ) { [weak self] _ in
            guard let self, case .locked = self.gesture else { return }
            self.lockWarningTimer = nil
            self.overlay.setLockWarning(true)
        }
        RunLoop.main.add(warning, forMode: .common)
        lockWarningTimer = warning
    }

    private func cancelRecording() {
        guard state.isRecording, let url = recordingURL else { return }
        _ = recorder.stop()
        overlay.hide()
        recordingURL = nil
        try? FileManager.default.removeItem(at: url)
        setState(.ready)
    }

    private func startRecording() {
        guard case .ready = state else { return }
        guard recorder.hasPermission else {
            setState(.failed("Нет доступа к микрофону. Разрешите его и перезапустите Chirper."))
            return
        }
        do {
            recordingURL = try recorder.start()
            overlay.show()
            setState(.recording)
            play("Tink")
            // Греем сразу после старта записи: дальше время всё равно уходит
            // на речь, и модель успевает вернуться из swap параллельно ей.
            worker?.warmup()
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    private func stopRecording() {
        guard state.isRecording, let url = recordingURL else { return }
        let duration = Date().timeIntervalSince(recorder.startedAt)
        let bytesWritten = recorder.stop()
        overlay.hide()
        recordingURL = nil
        if duration < minimumRecordingDuration {
            try? FileManager.default.removeItem(at: url)
            setState(.ready)
            return
        }
        guard bytesWritten > 4_096 else {
            try? FileManager.default.removeItem(at: url)
            showAlert(
                message: "Микрофон не записал звук",
                details: "Проверьте выбранный микрофон и разрешение Microphone, затем попробуйте снова."
            )
            setState(.ready)
            return
        }
        setState(.transcribing)
        play("Pop")
        do { try worker?.transcribe(url) } catch {
            try? FileManager.default.removeItem(at: url)
            setState(.failed(error.localizedDescription))
        }
    }

    private func received(text: String, file: URL) {
        try? FileManager.default.removeItem(at: file)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            setState(.ready)
            return
        }
        history.add(cleanText)
        paste(cleanText)
        setState(.ready)
    }

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard AXIsProcessTrusted() else {
                self.showAccessibilityHelp()
                self.setState(.ready)
                return
            }
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            guard let previous else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func setState(_ newState: AppState) {
        state = newState
        switch newState {
        case .loading:
            statusMenuItem.title = "Запускаю модель…"
            statusItem.button?.image = StatusIcon.loading()
        case .ready:
            statusMenuItem.title = "Готов — зажми правый ⌥"
            statusItem.button?.image = StatusIcon.ready()
        case .recording:
            statusMenuItem.title = "Идёт запись — отпусти ⌥"
            statusItem.button?.image = StatusIcon.recording()
        case .lockedRecording:
            statusMenuItem.title = "Запись зафиксирована — нажми ⌥, чтобы остановить"
            statusItem.button?.image = StatusIcon.locked()
        case .transcribing:
            statusMenuItem.title = "Распознаю…"
            statusItem.button?.image = StatusIcon.transcribing()
        case let .failed(message):
            statusMenuItem.title = "Ошибка — нажми, чтобы посмотреть"
            statusMenuItem.target = self
            statusMenuItem.action = #selector(showError)
            statusMenuItem.representedObject = message
            statusItem.button?.image = StatusIcon.failed()
        }
        if case .failed = newState {} else {
            statusMenuItem.action = nil
            statusMenuItem.representedObject = nil
        }
    }

    private func play(_ name: String) {
        if soundsEnabled { NSSound(named: NSSound.Name(name))?.play() }
    }

    @objc private func copyLast() {
        guard let text = history.entries.first?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func showHistory() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let text = history.entries.prefix(10).map {
            "\(formatter.string(from: $0.date))  \($0.text.prefix(80))"
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Последние надиктовки"
        alert.informativeText = text.isEmpty ? "История пуста" : text
        alert.runModal()
    }

    @objc private func toggleSound() {
        soundsEnabled.toggle()
        soundMenuItem.state = soundsEnabled ? .on : .off
    }

    @objc private func showOverlaySettings() {
        overlaySettings.onClose = { [weak self] in
            guard let self else { return }
            if self.state.isRecording { return }
            self.overlay.hide()
        }
        overlaySettings.show()
    }

    @objc private func showError() {
        let details = statusMenuItem.representedObject as? String ?? "Неизвестная ошибка"
        if details.contains("Accessibility") {
            showAccessibilityHelp()
            return
        }
        showAlert(
            message: "Chirper",
            details: details
        )
    }

    private func showAccessibilityHelp() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Нужно разрешение Accessibility"
        alert.informativeText = "Текст уже скопирован в буфер обмена — его можно вставить вручную. Включите Chirper в разделе Privacy & Security → Accessibility."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(message: String, details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = details
        alert.runModal()
    }

    @objc private func quitApplication() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
