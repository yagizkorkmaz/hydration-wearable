import Foundation

// MARK: - Cikti

/// Ekranda gosterilen tek bir anlik durum.
///
/// Ham alanlar (`gsr`, `red`, ...) son pakettendir; turetilmis alanlar
/// (`heartRate`, `prediction`, ...) kayan pencere uzerinden hesaplanir ve
/// saniyede bir tazelenir.
struct Vitals: Hashable {

    // Ham (son paket)
    var espMillis: Double = 0
    var gsr: Double = 0
    var red: Double = 0
    var ir: Double = 0
    var temperature: Double = 0
    var humidity: Double = 0

    // Turetilmis
    var heartRate: Double?
    /// 0-1. Spektral tepe ne kadar belirgin. 0.35 altini gostermiyoruz.
    var heartRateQuality: Double = 0
    var systolic: Double?
    var diastolic: Double?
    /// Perfuzyon indeksi: PPG'nin AC/DC orani (%). Damar dolgunlugu gostergesi.
    var perfusionIndex: Double?
    var prediction: HydrationPrediction?
    /// Modelin ihtiyac duydugu 60 sn'lik pencerenin ne kadari doldu (0-1).
    var windowProgress: Double = 0
    /// Parmak sensorde mi (IR seviyesine gore).
    var hasContact: Bool = false
    /// Modele verilen 8 ozellik — teshis / CSV icin.
    var features: [Double]?

    var hydrationClass: HydrationClass? { prediction?.hydrationClass }
    var wni: Double? { prediction?.wni }

    /// Kalp atisi gosterilebilir mi.
    var heartRateIsUsable: Bool {
        hasContact && heartRate != nil && heartRateQuality >= VitalsEngine.minHeartRateQuality
    }
}

// MARK: - CSV

extension Vitals {

    /// Turetilmis olculerin yazildigi ikinci dosyanin basligi.
    /// Ilk kolonu `DataLogger` ekler.
    static let csvHeader = [
        "received_at", "esp_millis", "gsr", "red", "ir", "temperature", "humidity",
        "heart_rate_bpm", "hr_quality", "systolic_est", "diastolic_est", "perfusion_index",
        "hydration_class", "wni", "confidence", "nearest_distance",
        "p_low", "p_moderate", "p_high"
    ].joined(separator: ",") + "," + HydrationModel.featureNames.joined(separator: ",")

    var csvRow: String {
        func number(_ value: Double?, _ decimals: Int = 2) -> String {
            guard let value, value.isFinite else { return "" }
            return String(format: "%.\(decimals)f", value)
        }

        var columns: [String] = [
            String(format: "%.0f", espMillis),
            String(format: "%.0f", gsr),
            String(format: "%.0f", red),
            String(format: "%.0f", ir),
            number(temperature),
            number(humidity),
            heartRateIsUsable ? number(heartRate, 1) : "",
            number(heartRateQuality, 3),
            number(systolic, 0),
            number(diastolic, 0),
            number(perfusionIndex, 3),
            prediction?.hydrationClass.rawName ?? "",
            number(prediction?.wni, 1),
            number(prediction?.confidence, 1),
            number(prediction?.nearestDistance, 3),
            number(prediction?.probability[0], 3),
            number(prediction?.probability[1], 3),
            number(prediction?.probability[2], 3)
        ]

        for i in 0..<HydrationModel.featureCount {
            columns.append(number(features?[i], 4))
        }
        return columns.joined(separator: ",")
    }
}

// MARK: - Motor

/// Gelen 5 Hz ham paket akisindan turetilmis olculeri uretir.
///
/// - 60 sn'lik kayan pencere → `HydrationModel`'in bekledigi 8 ozellik
///   (`gsr_mean, gsr_sd, gsr_slope, red_mean, red_sd, ir_mean, ir_sd, red_ir_ratio`)
/// - 30 sn'lik IR penceresi → nabiz (frekans alaninda)
/// - nabiz + perfuzyon → **tahmini** kan basinci
///
/// Thread: tek bir seri kuyruktan (BLE kuyrugu) cagrilir, kendi kilidi yoktur.
final class VitalsEngine {

    // MARK: Ayarlar

    /// ESP `SEND_INTERVAL = 200` → 5 Hz. Model de bu hizda egitildi.
    static let sampleRate: Double = HydrationModel.expectedSampleRate
    /// Model penceresi (sn). `hydration_model.h`: 60 sn @ 5 Hz = 300 kayit.
    static let modelWindow: Double = HydrationModel.windowSeconds
    /// Nabiz icin daha kisa pencere: 30 sn hem yeterli frekans cozunurlugu
    /// (~2 bpm) verir hem de nabiz degisimini daha hizli takip eder.
    static let heartWindow: Double = 30

    /// Tahmin icin pencerenin en az bu kadari dolmali.
    /// Tam 300 ornek beklemek, tek bir dusen pakette bile tahmini durdururdu.
    static let minWindowFill: Double = 0.8

    /// Bu IR seviyesinin altinda parmak sensorde degil sayilir.
    /// Egitim verisinde `ir_mean` ~104.700; bos sensor tipik olarak <10.000 okur.
    static let contactIRThreshold: Double = 20_000

    /// Altindaki spektral tepeler nabiz olarak gosterilmez.
    static let minHeartRateQuality: Double = 0.35

    /// Aranan nabiz araligi. Ust sinir Nyquist'in (5 Hz / 2 = 150 bpm) altinda
    /// tutuldu; sinira yakin frekanslar guvenilir degil.
    static let minBPM: Double = 42
    static let maxBPM: Double = 132

    /// `gsr_slope` ornek indeksine gore mi (birim: ADC/ornek) yoksa saniyeye
    /// gore mi (ADC/sn) hesaplaniyor.
    ///
    /// Egitim tarafinda `polyfit(arange(n), gsr, 1)` varsayildi → ornek basina.
    /// Egitim kodunda zaman ekseni saniye ise burayi `false` yap; aksi halde
    /// slope 5 kat kayar ve HIGH/LOW siniflari birbirine karisir.
    static let slopePerSample = true

    // MARK: Durum

    private struct Sample {
        let t: Double        // saniye (ESP millis / 1000)
        let gsr: Double
        let red: Double
        let ir: Double
    }

    private var samples: [Sample] = []
    private var lastESPMillis: Double = -1
    private var lastComputeTime: Double = -.greatestFiniteMagnitude

    /// Turetilmis degerler saniyede bir hesaplanir; aradaki paketlerde
    /// yalnizca ham alanlar tazelenir.
    private let computeInterval: Double = 1.0

    private(set) var vitals = Vitals()

    /// Oturumun ilk 60 saniyesinde toplanan perfuzyon taban degeri.
    /// Kan basinci tahmini bu tabana gore sapmayi kullanir.
    private var baselinePI: Double?
    private var baselinePISum: Double = 0
    private var baselinePICount: Int = 0
    private var firstSampleTime: Double?

    /// Nabzi yumusatmak icin ussel ortalama; tek bir kotu pencere
    /// ekrandaki degeri zipllatmasin.
    private var smoothedBPM: Double?

    // MARK: - Giris

    /// Yeni bir paket isler ve guncel `Vitals`'i dondurur.
    @discardableResult
    func ingest(_ packet: HydrationPacket) -> Vitals {
        let t = packet.espMillis / 1000

        // ESP yeniden basladiysa (millis sifirlanir) pencereyi bosalt;
        // yoksa eski ve yeni veri ayni pencerede karisir.
        if packet.espMillis < lastESPMillis {
            reset()
        }
        lastESPMillis = packet.espMillis

        samples.append(Sample(t: t, gsr: packet.gsr, red: packet.red, ir: packet.ir))

        // Pencereden dusenleri at (model penceresi en uzun olan).
        let cutoff = t - Self.modelWindow
        if let firstKept = samples.firstIndex(where: { $0.t >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }

        if firstSampleTime == nil { firstSampleTime = t }

        vitals.espMillis = packet.espMillis
        vitals.gsr = packet.gsr
        vitals.red = packet.red
        vitals.ir = packet.ir
        vitals.temperature = packet.temperature
        vitals.humidity = packet.humidity

        if t - lastComputeTime >= computeInterval {
            lastComputeTime = t
            recompute(now: t)
        }

        return vitals
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        lastESPMillis = -1
        lastComputeTime = -.greatestFiniteMagnitude
        baselinePI = nil
        baselinePISum = 0
        baselinePICount = 0
        firstSampleTime = nil
        smoothedBPM = nil
        vitals = Vitals()
    }

    // MARK: - Hesap

    private func recompute(now: Double) {
        let expected = Self.modelWindow * Self.sampleRate
        vitals.windowProgress = min(1, Double(samples.count) / expected)

        let irMeanAll = mean(samples.map(\.ir))
        vitals.hasContact = irMeanAll >= Self.contactIRThreshold

        computeHeartRateAndBP(now: now)
        computeHydration()
    }

    // MARK: Hidrasyon

    private func computeHydration() {
        guard vitals.windowProgress >= Self.minWindowFill else {
            vitals.prediction = nil
            vitals.features = nil
            return
        }

        let gsr = samples.map(\.gsr)
        let red = samples.map(\.red)
        let ir = samples.map(\.ir)

        let redMean = mean(red)
        let irMean = mean(ir)

        // Sira `HydrationModel.featureNames` ile ayni olmali.
        let features: [Double] = [
            mean(gsr),
            std(gsr),
            slope(gsr),
            redMean,
            std(red),
            irMean,
            std(ir),
            irMean > 0 ? redMean / irMean : 0
        ]

        vitals.features = features
        vitals.prediction = HydrationModel.predict(features: features)
    }

    // MARK: Nabiz + kan basinci

    private func computeHeartRateAndBP(now: Double) {
        let window = samples.filter { $0.t >= now - Self.heartWindow }

        // Frekans cozunurlugu pencere uzunlugundan gelir; yarim pencereden
        // azi ile 40-130 bpm ayirt edilemez.
        guard vitals.hasContact,
              Double(window.count) >= Self.heartWindow * Self.sampleRate * 0.6 else {
            vitals.heartRate = nil
            vitals.heartRateQuality = 0
            vitals.perfusionIndex = nil
            vitals.systolic = nil
            vitals.diastolic = nil
            return
        }

        // 1) Paket jitter'i ve dusen paketler icin duzgun 5 Hz izgaraya tasi.
        let grid = resample(window.map { ($0.t, $0.ir) },
                            rate: Self.sampleRate,
                            from: now - Self.heartWindow,
                            to: now)
        guard grid.count >= 32 else {
            vitals.heartRate = nil
            vitals.heartRateQuality = 0
            return
        }

        // 2) DC / yavas taban kaymasini at (2 sn'lik hareketli ortalama =
        //    ~0.5 Hz uzeri gecirir; nabiz bandi 0.7-2.2 Hz).
        let dc = mean(grid)
        let ac = highPass(grid, windowSize: Int(2.0 * Self.sampleRate))

        // 3) Perfuzyon indeksi: AC genligi / DC.
        let sorted = ac.sorted()
        let low = percentile(sorted, 0.05)
        let high = percentile(sorted, 0.95)
        let pi = dc > 0 ? (high - low) / dc * 100 : 0
        vitals.perfusionIndex = pi

        // 4) Nabiz: bantli periodogram tepesi.
        let (bpm, quality) = dominantFrequency(ac, rate: Self.sampleRate)

        if let bpm, quality >= Self.minHeartRateQuality {
            // Ussel yumusatma; ani sicramalari (ornegin hareket artefakti)
            // kirpar ama gercek degisimi ~5 sn icinde takip eder.
            if let previous = smoothedBPM, abs(previous - bpm) < 25 {
                smoothedBPM = previous * 0.7 + bpm * 0.3
            } else {
                smoothedBPM = bpm
            }
            vitals.heartRate = smoothedBPM
        } else {
            // Kalitesiz pencere: son iyi degeri koru ama kaliteyi dusur;
            // UI `heartRateIsUsable` ile zaten gizleyecek.
            vitals.heartRate = smoothedBPM
        }
        vitals.heartRateQuality = quality

        updateBaselinePI(pi, now: now)
        computeBloodPressure()
    }

    /// Oturumun ilk 60 saniyesindeki perfuzyon ortalamasini taban kabul eder.
    private func updateBaselinePI(_ pi: Double, now: Double) {
        guard baselinePI == nil, let start = firstSampleTime, pi > 0 else { return }
        baselinePISum += pi
        baselinePICount += 1
        if now - start >= 60, baselinePICount >= 10 {
            baselinePI = baselinePISum / Double(baselinePICount)
        }
    }

    /// **Tahmini** kan basinci.
    ///
    /// UYARI: Tek PPG kanaliyla gercek kan basinci OLCULEMEZ. Manset olcumu
    /// yerine gecmez. Burada yapilan sey, kullanicinin girdigi taban degerden
    /// (varsayilan 120/80) nabiz ve perfuzyon sapmasina gore heuristik bir
    /// kaydirmadir:
    ///
    /// - nabiz yukseldikce → kalp debisi artar → tahmin yukari
    /// - perfuzyon (AC/DC) tabana gore dustukce → vazokonstriksiyon →
    ///   tahmin yukari
    ///
    /// Katsayilar literaturdeki tipik nabiz-basinc egimlerinden secildi ve
    /// fizyolojik sinirlara kirpilir. Kalibrasyon icin `BPCalibration`.
    private func computeBloodPressure() {
        guard let hr = vitals.heartRate,
              vitals.heartRateQuality >= Self.minHeartRateQuality,
              vitals.hasContact else {
            vitals.systolic = nil
            vitals.diastolic = nil
            return
        }

        let cal = BPCalibration.current
        let hrTerm = hr - cal.restingHeartRate

        // Perfuzyon sapmasi: taban yoksa 0 (yalnizca nabiz terimi calisir).
        var piTerm = 0.0
        if let base = baselinePI, base > 0.01, let pi = vitals.perfusionIndex {
            piTerm = max(-1, min(1, (base - pi) / base))
        }

        var systolic = cal.systolic + 0.35 * hrTerm + 12 * piTerm
        var diastolic = cal.diastolic + 0.20 * hrTerm + 7 * piTerm

        systolic = max(85, min(180, systolic))
        diastolic = max(50, min(110, diastolic))
        // Nabiz basinci fizyolojik olarak en az ~20 mmHg.
        if systolic - diastolic < 20 { diastolic = systolic - 20 }

        vitals.systolic = systolic
        vitals.diastolic = diastolic
    }
}

// MARK: - Kan basinci kalibrasyonu

/// Kullanicinin manset ile olctugu dinlenme degerleri.
/// Tahmin bu tabandan sapma olarak hesaplanir.
struct BPCalibration: Equatable {

    var systolic: Double
    var diastolic: Double
    var restingHeartRate: Double

    static let `default` = BPCalibration(systolic: 120, diastolic: 80, restingHeartRate: 70)

    private static let key = "bpCalibration"

    static var current: BPCalibration {
        get {
            guard let raw = UserDefaults.standard.array(forKey: key) as? [Double],
                  raw.count == 3 else { return .default }
            return BPCalibration(systolic: raw[0], diastolic: raw[1], restingHeartRate: raw[2])
        }
        set {
            UserDefaults.standard.set([newValue.systolic, newValue.diastolic,
                                       newValue.restingHeartRate], forKey: key)
        }
    }

    static var isCalibrated: Bool {
        UserDefaults.standard.array(forKey: key) != nil
    }
}

// MARK: - Sinyal yardimcilari

private func mean(_ x: [Double]) -> Double {
    guard !x.isEmpty else { return 0 }
    return x.reduce(0, +) / Double(x.count)
}

/// Populasyon standart sapmasi (ddof = 0) — numpy varsayilani.
private func std(_ x: [Double]) -> Double {
    guard x.count > 1 else { return 0 }
    let m = mean(x)
    let v = x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
    return v.squareRoot()
}

/// En kucuk kareler dogru egimi.
/// `HydrationModel` ornek indeksine gore egitildi (bkz. `slopePerSample`).
private func slope(_ y: [Double]) -> Double {
    let n = y.count
    guard n > 1 else { return 0 }
    let step = VitalsEngine.slopePerSample ? 1.0 : 1.0 / VitalsEngine.sampleRate
    let xMean = Double(n - 1) / 2 * step
    let yMean = mean(y)
    var num = 0.0
    var den = 0.0
    for i in 0..<n {
        let dx = Double(i) * step - xMean
        num += dx * (y[i] - yMean)
        den += dx * dx
    }
    return den > 0 ? num / den : 0
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = max(0, min(sorted.count - 1, Int(p * Double(sorted.count - 1))))
    return sorted[idx]
}

/// Zaman damgali orneklemeyi duzgun araliga tasir (dogrusal ara deger).
/// Dusen paketler ve BLE jitter'i frekans analizini bozmasin diye gerekli.
private func resample(_ points: [(t: Double, v: Double)],
                      rate: Double,
                      from start: Double,
                      to end: Double) -> [Double] {
    guard points.count >= 2, end > start else { return [] }
    let count = Int((end - start) * rate)
    guard count > 1 else { return [] }

    var output: [Double] = []
    output.reserveCapacity(count)
    var j = 0

    for i in 0..<count {
        let t = start + Double(i) / rate
        while j + 1 < points.count && points[j + 1].t < t { j += 1 }

        if t <= points[0].t {
            output.append(points[0].v)
        } else if t >= points[points.count - 1].t {
            output.append(points[points.count - 1].v)
        } else {
            let a = points[j]
            let b = points[min(j + 1, points.count - 1)]
            let span = b.t - a.t
            let ratio = span > 0 ? (t - a.t) / span : 0
            output.append(a.v + (b.v - a.v) * ratio)
        }
    }
    return output
}

/// Hareketli ortalamayi cikararak yavas taban kaymasini siler.
private func highPass(_ x: [Double], windowSize: Int) -> [Double] {
    let w = max(3, windowSize)
    guard x.count > w else {
        let m = mean(x)
        return x.map { $0 - m }
    }

    // Kumulatif toplamla O(n) hareketli ortalama.
    var prefix = [Double](repeating: 0, count: x.count + 1)
    for i in 0..<x.count { prefix[i + 1] = prefix[i] + x[i] }

    var output = [Double](repeating: 0, count: x.count)
    let half = w / 2
    for i in 0..<x.count {
        let lo = max(0, i - half)
        let hi = min(x.count, i + half + 1)
        let avg = (prefix[hi] - prefix[lo]) / Double(hi - lo)
        output[i] = x[i] - avg
    }
    return output
}

/// Nabiz bandindaki baskin frekansi bulur.
///
/// 5 Hz ornekleme ile klasik tepe (peak) sayimi calismaz: bir kalp vurusuna
/// yalnizca 3-4 ornek duser. Bunun yerine 0.7-2.2 Hz araliginda ince adimli
/// bir periodogram hesaplanir; 30 sn'lik pencere ~2 bpm cozunurluk verir.
///
/// - Returns: (bpm, kalite). Kalite = tepe gucunun bant toplamina orani.
private func dominantFrequency(_ x: [Double], rate: Double) -> (Double?, Double) {
    let n = x.count
    guard n >= 32 else { return (nil, 0) }

    // Hann penceresi: spektral sizintiyi azaltir, komsu tepeleri ayirir.
    var windowed = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let w = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
        windowed[i] = x[i] * w
    }

    let energy = windowed.reduce(0) { $0 + $1 * $1 }
    guard energy > 0 else { return (nil, 0) }

    let minF = VitalsEngine.minBPM / 60
    let maxF = VitalsEngine.maxBPM / 60
    // Adim, pencere cozunurlugunun (1/T) ucte biri — tepe kaymasi olmasin.
    let step = rate / Double(n) / 3

    var bestPower = 0.0
    var bestFreq = minF
    var totalPower = 0.0

    var f = minF
    while f <= maxF {
        var re = 0.0
        var im = 0.0
        let omega = 2 * .pi * f / rate
        for i in 0..<n {
            let phase = omega * Double(i)
            re += windowed[i] * cos(phase)
            im += windowed[i] * sin(phase)
        }
        let power = re * re + im * im
        totalPower += power
        if power > bestPower {
            bestPower = power
            bestFreq = f
        }
        f += step
    }

    guard totalPower > 0 else { return (nil, 0) }

    // Kalite: tepe cevresindeki dar bandin toplam banda orani.
    // Gercek nabizda enerji tek bir tepede toplanir; hareket artefaktinda dagilir.
    let quality = min(1, bestPower / totalPower * Double(max(1, Int((maxF - minF) / step))) / 12)
    return (bestFreq * 60, quality)
}
