import Foundation
import CoreBluetooth
import Combine

// MARK: - UI alani

struct DisplayField: Identifiable, Hashable {
    let label: String
    let value: String
    var id: String { label }
}

// MARK: - HydrationSensor paketi

/// ESP32-S3'un (`esp_kodu_uykusuz.txt` / `esp_kodu.txt`) yayinladigi veri paketi.
///
/// Sketch, `loop()` icinde 200 ms'de bir (5 Hz) su stringi notify ediyor:
/// ```
/// String(millis()) + "," + String(latestGSR) + "," +
/// String((unsigned long)latestRed) + "," + String((unsigned long)latestIR) + "," +
/// String(latestTemperature, 2) + "," + String(latestHumidity, 2)
/// ```
/// Ornek: `15240,1874,84231,91342,24.63,46.18`
struct HydrationPacket {

    /// ESP'nin `millis()` degeri (cihaz acilisindan beri gecen ms).
    let espMillis: Double
    /// GSR ham ADC okumasi (12 bit, 0-4095).
    let gsr: Double
    /// MAX30102 kirmizi LED ham degeri.
    let red: Double
    /// MAX30102 kizilotesi LED ham degeri.
    let ir: Double
    /// SHT31 sicaklik (C).
    let temperature: Double
    /// SHT31 bagil nem (%).
    let humidity: Double

    /// Cihazin gonderdigi ham string. CSV'ye bu yazilir; boylece ESP'nin
    /// urettigi basamak sayisi birebir korunur, yeniden bicimlendirme kaynakli
    /// hassasiyet kaybi olmaz.
    let raw: String

    static let csvHeader = "received_at,esp_millis,gsr,red,ir,temperature,humidity"

    /// Tek bir notification'i cozumler. Format tutmuyorsa `nil`.
    ///
    /// Sketch'in gonderdigi paket ~48 byte; MTU 100 ile tek notification'a
    /// sigar, yani parcalanma olmaz ve her notification tam bir kayittir.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }

        var values: [Double] = []
        values.reserveCapacity(6)
        for part in parts {
            // `isFinite`: sensor okumasi bozulursa String(float,2) "nan"/"inf"
            // uretebilir; Double("nan") gecerli sayildigi icin ayrica bakiyoruz.
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)),
                  value.isFinite else { return nil }
            values.append(value)
        }

        espMillis = values[0]
        gsr = values[1]
        red = values[2]
        ir = values[3]
        temperature = values[4]
        humidity = values[5]
        raw = trimmed
    }

    var csvRow: String { raw }

    var displayFields: [DisplayField] {
        [
            DisplayField(label: "ESP millis", value: String(format: "%.0f", espMillis)),
            DisplayField(label: "GSR", value: String(format: "%.0f", gsr)),
            DisplayField(label: "RED", value: String(format: "%.0f", red)),
            DisplayField(label: "IR", value: String(format: "%.0f", ir)),
            DisplayField(label: "Sıcaklık", value: String(format: "%.2f °C", temperature)),
            DisplayField(label: "Nem", value: String(format: "%.2f %%", humidity))
        ]
    }
}

// MARK: - Cihaz oturumu

/// Tek bir bagli cihazin kayit durumu.
///
/// Dosya, ilk GECERLI paket geldiginde acilir. Boylece dogru adi tasiyip
/// beklenen veriyi gondermeyen bir cihaz bos dosya birakmaz.
private final class DeviceSession {

    let peripheral: CBPeripheral
    /// `DataLogger` ve `pending` icin anahtar.
    let key: String
    /// Tarama sirasinda goruldugu reklam adi (iOS onbelleginden etkilenmez).
    let advertisedName: String?

    var fileName: String?
    var packetCount = 0
    var lastLine: String?
    var lastFields: [DisplayField] = []
    /// Beklenen formata uymayan notification sayisi (teshis icin).
    private(set) var unrecognized = 0

    /// Ham paketlerden nabiz / kan basinci / hidrasyon sinifi ureten motor.
    let engine = VitalsEngine()
    var latestVitals = Vitals()

    /// Turetilmis olculerin yazildigi ikinci CSV. Ham dosya bozulmasin diye
    /// ayri tutulur (ham dosya egitim verisi olarak kullaniliyor).
    var vitalsFileName: String?
    /// Turetilmis CSV'ye en son yazilan `esp_millis` (saniyede bir yazilir).
    var lastVitalsLogMillis: Double = -.greatestFiniteMagnitude

    /// `DataLogger` icinde turetilmis dosyanin anahtari.
    var vitalsKey: String { key + "#vitals" }

    init(peripheral: CBPeripheral, advertisedName: String?) {
        self.peripheral = peripheral
        self.key = peripheral.identifier.uuidString
        self.advertisedName = advertisedName
    }

    /// Kullaniciya gosterilecek ad. Reklam adi, iOS'un onbelleklenmis
    /// `peripheral.name` degerinden daha guvenilirdir.
    var displayName: String {
        advertisedName ?? peripheral.name ?? BLEManager.expectedDeviceName
    }

    /// Gelen notification'i cozumler. Beklenen formatta degilse `nil`.
    func decode(_ data: Data) -> HydrationPacket? {
        guard let text = String(data: data, encoding: .utf8) else {
            unrecognized += 1
            NSLog("[BLE] UTF-8 olmayan paket atlandi (\(data.count) byte)")
            return nil
        }
        guard let packet = HydrationPacket(text) else {
            unrecognized += 1
            NSLog("[BLE] Beklenmeyen paket atlandi: \(text.prefix(80))")
            return nil
        }
        return packet
    }
}

/// UI'a acilan, tek bir cihazin ozeti.
struct DeviceSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let packetCount: Int
    let fileName: String?
    let lastLine: String?
    let fields: [DisplayField]
    /// Ham + turetilmis son durum (nabiz, WNI, hidrasyon sinifi...).
    let vitals: Vitals
}

// MARK: - BLE yoneticisi

/// `HydrationSensor` cihazina baglanir ve gelen her paketi `DataLogger`'a aktarir.
///
/// Arka plan calismasi icin gerekenler:
/// - Info.plist'te `UIBackgroundModes: bluetooth-central`
/// - `CBCentralManagerOptionRestoreIdentifierKey` ile state restoration
/// - Arka plan taramasinda servis UUID'i **zorunlu** oldugu icin tarama her
///   zaman `[Self.serviceUUID]` ile yapilir.
final class BLEManager: NSObject, ObservableObject {

    static let shared = BLEManager()

    // bilgiler.txt icindeki UUID'ler
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Sketch'teki `BLEDevice::init("HydrationSensor")` ile ayni olmali.
    ///
    /// Servis UUID'i tek basina YETMEZ: `6E400001-...` Nordic UART Service'in
    /// standart kimligidir; laboratuvardaki baska ESP32'ler de (or. bileklik
    /// `BLK-let_11-9B32`) ayni UUID'i advertise eder.
    static let expectedDeviceName = "HydrationSensor"

    private static let restoreIdentifier = "com.hydration.logger.central"
    private static let knownPeripheralsKey = "knownPeripheralIdentifiers"
    private static let autoStartKey = "autoStart"

    /// Ad eslesmesi. Kucuk/buyuk harf duyarsiz, tam eslesme.
    private static func matches(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.caseInsensitiveCompare(expectedDeviceName) == .orderedSame
    }

    enum State: String {
        case bluetoothOff = "Bluetooth kapalı"
        case unauthorized = "Bluetooth izni yok"
        case idle = "Bekleniyor"
        case scanning = "HydrationSensor aranıyor…"
        case connected = "Bağlı — kayıt yapılıyor"
    }

    // MARK: - UI'a acilan durum

    @Published private(set) var state: State = .idle
    @Published private(set) var devices: [DeviceSummary] = []
    @Published private(set) var lastPacketAt: Date?

    /// Kullanici elle durdurduysa otomatik yeniden baglanma yapilmaz.
    @Published private(set) var isRunning = false

    /// Toplam paket sayaci.
    var packetCount: Int { devices.reduce(0) { $0 + $1.packetCount } }

    // MARK: - Internal

    private var central: CBCentralManager!

    /// Bagli ve kayit yapan cihazlar.
    private var sessions: [UUID: DeviceSession] = [:]

    /// `connect()` cagrilmis ama henuz baglanmamis adaylar.
    /// Cihaz degistiginde eski kimlige acilan baglanti asla gerceklesmez; bu
    /// yuzden adaylar taramayi engellemez ve referanslarini burada tutariz
    /// (CoreBluetooth peripheral'i sahiplenmez).
    private var pending: [UUID: CBPeripheral] = [:]

    /// Tarama sirasinda gorulen reklam adlari.
    ///
    /// Ad eslemesi HER ZAMAN bunun uzerinden yapilir. `peripheral.name`
    /// GATT'tan gelir ve iOS onu cihazin MAC adresine gore ONBELLEKLER;
    /// kart daha once baska bir adla calistiysa ESKI adi dondurebilir.
    private var advertisedNames: [UUID: String] = [:]

    private let queue = DispatchQueue(label: "com.hydration.logger.ble")

    /// `isRunning`'in BLE queue'sundaki karsiligi. Tum delegate kodu bunu okur;
    /// `isRunning` yalnizca UI icin main thread'de yansitilir.
    private var running = false

    private override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    // MARK: - Kontrol

    /// Taramayi baslatir; HydrationSensor bulununca otomatik baglanir.
    func start() {
        UserDefaults.standard.set(true, forKey: Self.autoStartKey)
        queue.async {
            self.running = true
            self.publish { self.isRunning = true }
            self.startScanIfPossible()
        }
    }

    /// Baglantiyi keser, kaydi kapatir ve yeniden baglanmayi durdurur.
    func stop() {
        UserDefaults.standard.set(false, forKey: Self.autoStartKey)
        queue.async {
            self.running = false
            self.central.stopScan()

            for session in self.sessions.values {
                self.central.cancelPeripheralConnection(session.peripheral)
            }
            self.sessions.removeAll()
            self.cancelPending(except: nil)

            DataLogger.shared.endAllSessions()

            let poweredOn = self.central.state == .poweredOn
            self.publish {
                self.isRunning = false
                self.devices = []
                if poweredOn { self.state = .idle }
            }
        }
    }

    /// Uygulama acildiginda, kullanici en son "baslat" demisse kaydi surdurur.
    func resumeIfPreviouslyRunning() {
        guard UserDefaults.standard.bool(forKey: Self.autoStartKey) else { return }
        start()
    }

    // MARK: - Private

    private func startScanIfPossible() {
        guard running else { return }

        switch central.state {
        case .poweredOff:
            publish { self.state = .bluetoothOff }
            return
        case .unauthorized:
            publish { self.state = .unauthorized }
            return
        case .poweredOn:
            break
        default:
            return
        }

        // Daha once baglandigimiz cihaza bekleyen baglanti ac: tarama
        // gerektirmez ve arka planda cok daha guvenilirdir.
        //
        // DIKKAT: burada `return` YOK. Kart degistirildiginde BLE adresi --
        // dolayisiyla peripheral kimligi -- degisir, ama `retrievePeripherals`
        // eski cihazi yine de dondurur ve `connect` timeout'suz oldugu icin
        // sonsuza kadar bekler. Taramayi paralel yurutmezsek yeni cihaz asla
        // bulunamaz.
        let knownIDs = UserDefaults.standard.stringArray(forKey: Self.knownPeripheralsKey) ?? []
        let uuids = knownIDs.compactMap(UUID.init(uuidString:))
        if !uuids.isEmpty {
            for known in central.retrievePeripherals(withIdentifiers: uuids) {
                connectCandidate(known)
            }
        }

        // Halihazirda bagli (baska bir uygulama tarafindan da olabilir) cihaz.
        for already in central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        where Self.matches(already.name) {
            connectCandidate(already)
        }

        // Baglantı kopunca yeniden bulabilmek icin bagliyken de taramaya devam.
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        publishState()
    }

    /// Cihaza bekleyen bir baglanti acar. Taramayi durdurmaz.
    /// Timeout verilmez: iOS bekleyen baglantiyi arka planda da tutar,
    /// cihaz menzile girdigi anda baglanir.
    private func connectCandidate(_ p: CBPeripheral) {
        guard sessions[p.identifier] == nil, pending[p.identifier] == nil else { return }
        pending[p.identifier] = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    private func cancelPending(except keep: CBPeripheral?) {
        for (id, p) in pending where id != keep?.identifier {
            central.cancelPeripheralConnection(p)
        }
        pending.removeAll()
    }

    private func remember(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.knownPeripheralsKey) ?? []
        let value = id.uuidString
        guard !ids.contains(value) else { return }
        ids.append(value)
        UserDefaults.standard.set(ids, forKey: Self.knownPeripheralsKey)
    }

    private func forget(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.knownPeripheralsKey) ?? []
        ids.removeAll { $0 == id.uuidString }
        UserDefaults.standard.set(ids, forKey: Self.knownPeripheralsKey)
    }

    /// `sessions` sozlugunu UI'a yansitir. Yalnizca `queue` uzerinden cagrilir.
    private func publishSessions() {
        let summaries = sessions.values
            .map {
                DeviceSummary(
                    id: $0.key,
                    name: $0.displayName,
                    packetCount: $0.packetCount,
                    fileName: $0.fileName,
                    lastLine: $0.lastLine,
                    fields: $0.lastFields,
                    vitals: $0.latestVitals
                )
            }
            .sorted { $0.name < $1.name }

        let connected = !summaries.isEmpty
        publish {
            self.devices = summaries
            if connected { self.state = .connected }
            else if self.isRunning { self.state = .scanning }
        }
    }

    private func publishState() {
        let connected = !sessions.isEmpty
        publish {
            if connected { self.state = .connected }
            else if self.running { self.state = .scanning }
        }
    }

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    /// Sistem uygulamayi arka planda yeniden baslattiginda cagrilir.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              !restored.isEmpty else { return }

        running = true

        for p in restored {
            p.delegate = self
            if p.state == .connected {
                sessions[p.identifier] = DeviceSession(
                    peripheral: p,
                    advertisedName: advertisedNames[p.identifier]
                )
            } else {
                pending[p.identifier] = p
            }
        }

        publish { self.isRunning = true }
        publishSessions()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanIfPossible()
        case .poweredOff:
            // Baglanti koptu sayilir; tampondaki veriyi kaybetme.
            DataLogger.shared.flush()
            publish { self.state = .bluetoothOff }
        case .unauthorized:
            publish { self.state = .unauthorized }
        default:
            publish { self.state = .idle }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard running else { return }

        // Ad eslemesi REKLAM ADI uzerinden yapilir.
        //
        // `peripheral.name` GATT'tan gelir ve iOS onu MAC adresine gore
        // onbellekler; kart daha once baska bir adla calistiysa eski adi
        // dondurebilir. Reklam adi ise her tarama paketinde tazedir.
        // Yalnizca reklam adi hic gelmediyse `peripheral.name`'e duseriz.
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name

        guard Self.matches(name) else {
            NSLog("[BLE] \(name ?? "isimsiz") atlandi (aranan: \(Self.expectedDeviceName))")
            return
        }

        if let advertisedName {
            advertisedNames[peripheral.identifier] = advertisedName
        }

        connectCandidate(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pending.removeValue(forKey: peripheral.identifier)
        remember(peripheral.identifier)

        let session = DeviceSession(
            peripheral: peripheral,
            advertisedName: advertisedNames[peripheral.identifier]
        )
        sessions[peripheral.identifier] = session

        NSLog("[BLE] Baglandi: reklam adi=\(session.advertisedName ?? "-") "
              + "GATT adi=\(peripheral.name ?? "-")")

        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])

        publishSessions()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        NSLog("[BLE] Baglanti kurulamadi: \(error?.localizedDescription ?? "-")")
        pending.removeValue(forKey: peripheral.identifier)
        retry(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        pending.removeValue(forKey: peripheral.identifier)

        // Yazilmamis veri kalmasin; oturum dosyasi kapanir.
        if let session = sessions.removeValue(forKey: peripheral.identifier) {
            DataLogger.shared.endSession(key: session.key)
            DataLogger.shared.endSession(key: session.vitalsKey)
        }

        publishSessions()
        retry(peripheral)
    }

    /// Cihaz yeniden advertise ettiginde otomatik geri baglan.
    /// Taramayi da yeniden baslatir.
    private func retry(_ p: CBPeripheral) {
        guard running else { return }
        connectCandidate(p)
        startScanIfPossible()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            NSLog("[BLE] Servis bulunamadi: \(error?.localizedDescription ?? "-")")
            return
        }
        peripheral.discoverCharacteristics([Self.txCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let tx = service.characteristics?.first(where: { $0.uuid == Self.txCharacteristicUUID }) else {
            NSLog("[BLE] TX karakteristigi bulunamadi: \(error?.localizedDescription ?? "-")")
            return
        }
        // Notify acildigi andan itibaren uygulama arka planda olsa da
        // iOS her paket icin uyandirilir.
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        guard let session = sessions[peripheral.identifier] else { return }

        // Egitim verisi kirlenmesin: yalnizca beklenen format yazilir.
        guard let packet = session.decode(data) else { return }

        // Dosya ilk GECERLI pakette acilir.
        if session.fileName == nil {
            session.fileName = DataLogger.shared.startSession(
                key: session.key,
                header: HydrationPacket.csvHeader,
                tag: "hydration"
            )
            session.vitalsFileName = DataLogger.shared.startSession(
                key: session.vitalsKey,
                header: Vitals.csvHeader,
                tag: "vitals"
            )
        }

        DataLogger.shared.append(row: packet.csvRow, key: session.key)

        // Turetilmis olculer (nabiz, WNI, sinif...) burada uretilir.
        let vitals = session.engine.ingest(packet)
        session.latestVitals = vitals

        // Turetilmis degerler saniyede bir degistigi icin CSV'ye de 1 Hz yazilir.
        if packet.espMillis - session.lastVitalsLogMillis >= 1000 {
            session.lastVitalsLogMillis = packet.espMillis
            DataLogger.shared.append(row: vitals.csvRow, key: session.vitalsKey)
        }

        session.packetCount += 1
        session.lastLine = packet.csvRow
        session.lastFields = packet.displayFields

        let now = Date()
        publish { self.lastPacketAt = now }
        publishSessions()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            NSLog("[BLE] Notify acilamadi: \(error.localizedDescription)")
        }
    }
}
