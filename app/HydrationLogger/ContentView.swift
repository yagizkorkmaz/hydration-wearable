import SwiftUI

/// Iki sekme: canli gostergeler ve ham kayit dosyalari.
struct ContentView: View {

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Canlı", systemImage: "drop.fill") }

            LoggerView()
                .tabItem { Label("Kayıtlar", systemImage: "externaldrive.fill") }
        }
    }
}

/// Kayit yonetimi: baslat/durdur, ham paket akisi, dosya listesi.
struct LoggerView: View {

    @EnvironmentObject private var ble: BLEManager
    @State private var files: [DataLogger.SavedFile] = []
    @State private var fileToDelete: DataLogger.SavedFile?

    var body: some View {
        NavigationStack {
            List {
                statusSection
                liveSection
                filesSection
            }
            .navigationTitle("Kayıtlar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Yenile", systemImage: "arrow.clockwise") { refresh() }
                }
            }
            .onAppear {
                ble.resumeIfPreviouslyRunning()
                refresh()
            }
            // Kayit sirasinda dosya boyutu buyudugu icin listeyi periyodik tazele.
            .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
                refresh()
            }
            .confirmationDialog(
                "Bu dosya silinsin mi?",
                isPresented: Binding(get: { fileToDelete != nil },
                                     set: { if !$0 { fileToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Sil", role: .destructive) {
                    if let file = fileToDelete {
                        DataLogger.shared.delete(file)
                        fileToDelete = nil
                        refresh()
                    }
                }
                Button("Vazgeç", role: .cancel) { fileToDelete = nil }
            } message: {
                Text(fileToDelete?.name ?? "")
            }
        }
    }

    // MARK: - Bolumler

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.state.rawValue)
                        .font(.headline)
                    Text(ble.devices.isEmpty
                         ? "HydrationSensor"
                         : ble.devices.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            Button {
                ble.isRunning ? ble.stop() : ble.start()
                refresh()
            } label: {
                Label(ble.isRunning ? "Kaydı Durdur" : "Kaydı Başlat",
                      systemImage: ble.isRunning ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(ble.isRunning ? .red : .accentColor)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } footer: {
            Text("Uygulama arka plandayken de kayda devam eder. Kayıt açıkken uygulamayı tamamen kapatmayın (app switcher'dan yukarı kaydırmayın).")
        }
    }

    /// Her bagli cihaz icin ayri bir bolum: kendi sayaci, dosyasi ve alanlari.
    @ViewBuilder
    private var liveSection: some View {
        if ble.devices.isEmpty {
            Section("Canlı") {
                Text(ble.isRunning ? "Cihaz bekleniyor…" : "Kayıt kapalı.")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(ble.devices) { device in
            Section(device.name) {
                LabeledContent("Paket") { Text("\(device.packetCount)").monospacedDigit() }
                LabeledContent("Dosya") {
                    Text(device.fileName ?? "—")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let line = device.lastLine {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Son veri")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(line)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
                ForEach(device.fields) { field in
                    LabeledContent(field.label) { Text(field.value).monospacedDigit() }
                }
            }
        }
    }

    private var filesSection: some View {
        Section("Kaydedilen dosyalar (\(files.count))") {
            if files.isEmpty {
                Text("Henüz kayıt yok.")
                    .foregroundStyle(.secondary)
            }
            ForEach(files) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(byteFormatter.string(fromByteCount: Int64(file.size)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: file.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
                .swipeActions {
                    Button("Sil", role: .destructive) { fileToDelete = file }
                }
            }
        }
    }

    // MARK: - Yardimcilar

    private var statusColor: Color {
        switch ble.state {
        case .connected: return .green
        case .scanning: return .orange
        case .bluetoothOff, .unauthorized: return .red
        case .idle: return .gray
        }
    }

    private func refresh() {
        files = DataLogger.shared.savedFiles()
    }

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f
    }()
}

#Preview {
    ContentView().environmentObject(BLEManager.shared)
}
