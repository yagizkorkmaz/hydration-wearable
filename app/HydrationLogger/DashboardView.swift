import SwiftUI

/// Canli ekran.
///
/// Ust sirada istenen uc olcu buyuk gosterilir:
/// **hidrasyon sinifi, WNI, nabiz.** Geri kalan her sey altta kucuk kartlarda.
struct DashboardView: View {

    @EnvironmentObject private var ble: BLEManager
    @State private var showCalibration = false

    /// Su an gosterilen cihaz. Birden fazla varsa ilki.
    private var device: DeviceSummary? { ble.devices.first }
    private var vitals: Vitals? { device?.vitals }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusBar

                    if let vitals, let device {
                        heroRow(vitals)
                        windowBanner(vitals)
                        //bloodPressureCard(vitals)
                        metrics(vitals, device: device)
                        probabilityCard(vitals)
                        disclaimer
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Canlı")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kalibrasyon", systemImage: "slider.horizontal.3") {
                        showCalibration = true
                    }
                }
            }
            .sheet(isPresented: $showCalibration) { CalibrationView() }
            .onAppear { ble.resumeIfPreviouslyRunning() }
        }
    }

    // MARK: - Durum

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(ble.state.rawValue).font(.subheadline.weight(.medium))
                if let device {
                    Text("\(device.name) · \(device.packetCount) paket")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(ble.isRunning ? "Durdur" : "Başlat") {
                ble.isRunning ? ble.stop() : ble.start()
            }
            .buttonStyle(.bordered)
            .tint(ble.isRunning ? .red : .accentColor)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusColor: Color {
        switch ble.state {
        case .connected: return .green
        case .scanning: return .orange
        case .bluetoothOff, .unauthorized: return .red
        case .idle: return .gray
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "drop.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(ble.isRunning ? "Cihaz bekleniyor…" : "Ölçümü başlat")
                .font(.headline)
            Text("HydrationSensor bağlandığında veriler burada görünür.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Ust sira: sinif + WNI + nabiz

    @ViewBuilder
    private func heroRow(_ vitals: Vitals) -> some View {
        VStack(spacing: 12) {
            hydrationCard(vitals)

            HStack(spacing: 12) {
                wniCard(vitals)
                heartRateCard(vitals)
            }
        }
    }

    private func hydrationCard(_ vitals: Vitals) -> some View {
        let hydration = vitals.hydrationClass

        return VStack(alignment: .leading, spacing: 6) {
            Text("HYDRATION CLASS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(hydration?.shortTitle ?? "—")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(color(for: hydration))
                .contentTransition(.numericText())

            Text(hydration?.subtitle ?? "60 sn'lik pencere bekleniyor")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let prediction = vitals.prediction {
                Text("güven %\(Int(prediction.confidence.rounded()))"
                     + (prediction.nearestDistance > 4 ? " · eğitim verisine uzak okuma" : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color(for: hydration).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func wniCard(_ vitals: Vitals) -> some View {
        VStack(spacing: 8) {
            Text("WNI")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ZStack {
                Circle()
                    .stroke(Color(.systemFill), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: (vitals.wni ?? 0) / 100)
                    .stroke(color(for: vitals.hydrationClass),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: vitals.wni)

                VStack(spacing: 0) {
                    Text(vitals.wni.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("/100").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(height: 96)

            Text("Water Need Index")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func heartRateCard(_ vitals: Vitals) -> some View {
        VStack(spacing: 8) {
            Text("HEART RATE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Image(systemName: "heart.fill")
                .font(.title2)
                .foregroundStyle(.pink)
                .symbolEffect(.pulse, isActive: vitals.heartRateIsUsable)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(vitals.heartRateIsUsable
                     ? "\(Int((vitals.heartRate ?? 0).rounded()))"
                     : "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("bpm").font(.caption).foregroundStyle(.secondary)
            }

            Text(heartRateNote(vitals))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    private func heartRateNote(_ vitals: Vitals) -> String {
        if !vitals.hasContact { return "parmağını sensöre koy" }
        if !vitals.heartRateIsUsable { return "sinyal zayıf, kıpırdama" }
        return "sinyal %\(Int((vitals.heartRateQuality * 100).rounded()))"
    }

    // MARK: - Pencere durumu

    @ViewBuilder
    private func windowBanner(_ vitals: Vitals) -> some View {
        if vitals.prediction == nil {
            let seconds = Int(VitalsEngine.modelWindow * (1 - vitals.windowProgress))
            HStack(spacing: 10) {
                ProgressView(value: vitals.windowProgress)
                    .frame(width: 90)
                Text("Model 60 sn'lik pencere kullanıyor — ~\(seconds) sn kaldı")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Kan basinci

    private func bloodPressureCard(_ vitals: Vitals) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("BLOOD PRESSURE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("TAHMİNİ")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }

                if let systolic = vitals.systolic, let diastolic = vitals.diastolic {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int(systolic.rounded()))/\(Int(diastolic.rounded()))")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("mmHg").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").font(.system(size: 28, weight: .bold, design: .rounded))
                }

                Text(BPCalibration.isCalibrated
                     ? "kalibrasyon tabanına göre"
                     : "kalibre edilmedi — 120/80 tabanı kullanılıyor")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Kalibre et") { showCalibration = true }
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Ham olculer

    private func metrics(_ vitals: Vitals, device: DeviceSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(title: "GSR", value: format(vitals.gsr, 0), unit: "ADC",
                       icon: "hand.raised.fill", tint: .teal)
            MetricTile(title: "RED", value: format(vitals.red, 0), unit: "",
                       icon: "circle.fill", tint: .red)
            MetricTile(title: "IR", value: format(vitals.ir, 0), unit: "",
                       icon: "circle.fill", tint: .indigo)
            MetricTile(title: "Perfüzyon", value: vitals.perfusionIndex.map { format($0, 2) } ?? "—",
                       unit: "%", icon: "drop.fill", tint: .blue)
            MetricTile(title: "Temperature", value: format(vitals.temperature, 2), unit: "°C",
                       icon: "thermometer.medium", tint: .orange)
            MetricTile(title: "Humidity", value: format(vitals.humidity, 2), unit: "%",
                       icon: "humidity.fill", tint: .cyan)
            MetricTile(title: "esp_millis", value: format(vitals.espMillis, 0), unit: "ms",
                       icon: "clock.fill", tint: .gray)
            MetricTile(title: "Paket", value: "\(device.packetCount)", unit: "",
                       icon: "antenna.radiowaves.left.and.right", tint: .green)
        }
    }

    // MARK: - Sinif olasiliklari

    @ViewBuilder
    private func probabilityCard(_ vitals: Vitals) -> some View {
        if let prediction = vitals.prediction {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sınıf ağırlıkları")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(HydrationClass.allCases, id: \.self) { hydrationClass in
                    let value = prediction.probability[hydrationClass.rawValue]
                    HStack(spacing: 10) {
                        Text(hydrationClass.shortTitle)
                            .font(.caption.monospaced())
                            .frame(width: 78, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(.systemFill))
                                Capsule()
                                    .fill(color(for: hydrationClass))
                                    .frame(width: geo.size.width * value)
                            }
                        }
                        .frame(height: 8)
                        Text("%\(Int((value * 100).rounded()))")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var disclaimer: some View {
        Text("Hidrasyon sınıfı ve WNI, 17 Ağustos 2026 kayıtlarından üretilen deneysel "
             + "bir k-NN modelinin çıktısıdır; klinik dehidrasyon ölçümü değildir. "
             + "Kan basıncı tek PPG kanalından türetilen bir tahmindir, manşet ölçümü "
             + "yerine geçmez.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Yardimcilar

    private func color(for hydration: HydrationClass?) -> Color {
        switch hydration {
        case .low: return .green
        case .moderate: return .orange
        case .high: return .red
        case nil: return .gray
        }
    }

    private func format(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

// MARK: - Kucuk olcu karti

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2).foregroundStyle(tint)
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Kalibrasyon ekrani

/// Kan basinci tahmininin taban degerleri.
/// Manset ile olculen dinlenme degerleri girilirse tahmin anlamli olur.
struct CalibrationView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var systolic: Double = BPCalibration.current.systolic
    @State private var diastolic: Double = BPCalibration.current.diastolic
    @State private var restingHeartRate: Double = BPCalibration.current.restingHeartRate

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    stepper("Sistolik", value: $systolic, range: 80...180, unit: "mmHg")
                    stepper("Diyastolik", value: $diastolic, range: 45...120, unit: "mmHg")
                    stepper("Dinlenme nabzı", value: $restingHeartRate, range: 40...110, unit: "bpm")
                } header: {
                    Text("Taban değerler")
                } footer: {
                    Text("Bir manşetli tansiyon aleti ile dinlenirken ölçtüğün değerleri gir. "
                         + "Uygulama, anlık nabız ve perfüzyon sapmasını bu tabana ekleyerek "
                         + "tahmin üretir. Taban girilmezse 120/80 varsayılır.")
                }

                Section {
                    Button("Varsayılana dön", role: .destructive) {
                        systolic = BPCalibration.default.systolic
                        diastolic = BPCalibration.default.diastolic
                        restingHeartRate = BPCalibration.default.restingHeartRate
                    }
                }
            }
            .navigationTitle("Kalibrasyon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        BPCalibration.current = BPCalibration(
                            systolic: systolic,
                            diastolic: max(45, min(diastolic, systolic - 20)),
                            restingHeartRate: restingHeartRate
                        )
                        dismiss()
                    }
                }
            }
        }
    }

    private func stepper(_ title: String, value: Binding<Double>,
                         range: ClosedRange<Double>, unit: String) -> some View {
        Stepper(value: value, in: range, step: 1) {
            LabeledContent(title) {
                Text("\(Int(value.wrappedValue)) \(unit)").monospacedDigit()
            }
        }
    }
}

#Preview {
    DashboardView().environmentObject(BLEManager.shared)
}
