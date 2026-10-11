import Foundation

/// Gelen telemetri satirlarini cihaz hafizasinda CSV dosyalarina yazar.
///
/// - Ayni anda **birden fazla cihaz** kayit yapabilir; her cihaz icin ayri
///   dosya ve ayri tampon tutulur (cihazlarin kolonlari farkli).
/// - Yazmalar kendi serial queue'sunda, tamponlanarak yapilir; boylece
///   5 Hz notify akisi arka planda da ucuz kalir.
/// - Dosyalar `Documents/` altinda tutulur, `UIFileSharingEnabled` sayesinde
///   Files uygulamasindan da erisilebilir.
final class DataLogger {

    static let shared = DataLogger()

    private let queue = DispatchQueue(label: "com.hydration.logger.file", qos: .utility)

    /// Tampon bu boyutu asinca hemen diske yazilir.
    private let flushThreshold = 4 * 1024
    /// Tampon dolmasa bile bu araliklarla diske yazilir.
    private let flushInterval: TimeInterval = 2

    /// Tek bir cihazin acik dosyasi.
    private final class Session {
        let url: URL
        let handle: FileHandle
        var buffer = Data()
        var packetCount = 0

        init(url: URL, handle: FileHandle) {
            self.url = url
            self.handle = handle
        }
    }

    /// Cihaz anahtari (peripheral identifier) -> acik dosya.
    private var sessions: [String: Session] = [:]
    private var flushTimer: DispatchSourceTimer?

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private init() {}

    // MARK: - Konum

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Oturum yonetimi

    /// Bir cihaz icin yeni dosya acar. Ayni anahtarla acik dosya varsa kapatir.
    ///
    /// - Parameters:
    ///   - key: Cihazi ayirt eden anahtar (peripheral identifier).
    ///   - header: Dosyanin ilk satiri (kolon adlari, sonunda `\n` olmadan).
    ///   - tag: Dosya adina eklenecek kisa cihaz etiketi.
    /// - Returns: Acilan dosyanin adi, hata olursa nil.
    @discardableResult
    func startSession(key: String, header: String, tag: String) -> String? {
        queue.sync {
            closeLocked(key: key)
            return startSessionLocked(key: key, header: header, tag: tag)
        }
    }

    /// Cozumlenmis bir kaydi yazar. Cagrilan thread'i bloklamaz.
    /// - Parameters:
    ///   - row: Basliktaki sirayla alanlar (bastaki `received_at` haric).
    ///   - key: Hangi cihazin dosyasina yazilacagi.
    func append(row: String, key: String) {
        let timestamp = isoFormatter.string(from: Date())

        queue.async {
            guard !row.isEmpty, let session = self.sessions[key] else { return }

            session.buffer.append(Data("\(timestamp),\(row)\n".utf8))
            session.packetCount += 1

            if session.buffer.count >= self.flushThreshold {
                self.flushLocked(session)
            }
        }
    }

    /// Tum tamponlari diske yazar (arka plana gecerken / baglanti kopunca).
    func flush() {
        queue.async {
            for session in self.sessions.values { self.flushLocked(session) }
        }
    }

    /// Tek bir cihazin oturumunu kapatir.
    func endSession(key: String) {
        queue.async { self.closeLocked(key: key) }
    }

    /// Tum oturumlari kapatir.
    func endAllSessions() {
        queue.async {
            for key in self.sessions.keys { self.closeLocked(key: key) }
        }
    }

    // MARK: - Dosya listesi

    struct SavedFile: Identifiable, Hashable {
        let url: URL
        let size: Int
        let date: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    func savedFiles() -> [SavedFile] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: Self.documentsURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension.lowercased() == "csv" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return SavedFile(
                    url: url,
                    size: values?.fileSize ?? 0,
                    date: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.date > $1.date }
    }

    func delete(_ file: SavedFile) {
        queue.sync {
            // Dosya su an yazilan bir oturuma aitse once kapat.
            if let key = sessions.first(where: { $0.value.url == file.url })?.key {
                closeLocked(key: key)
            }
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    // MARK: - Private (hepsi `queue` uzerinde calisir)

    private func startSessionLocked(key: String, header: String, tag: String) -> String? {
        let name = "\(fileNameFormatter.string(from: Date()))_\(tag).csv"
        let url = Self.documentsURL.appendingPathComponent(name)

        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: Data((header + "\n").utf8),
            attributes: [
                // Cihaz kilitliyken de yazabilmek icin: acilistan sonraki
                // ilk unlock'tan itibaren erisilebilir olsun.
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
        guard created, let handle = try? FileHandle(forWritingTo: url) else {
            NSLog("[DataLogger] Dosya olusturulamadi: \(url.path)")
            return nil
        }

        handle.seekToEndOfFile()
        sessions[key] = Session(url: url, handle: handle)
        startTimerLocked()
        return name
    }

    private func flushLocked(_ session: Session) {
        guard !session.buffer.isEmpty else { return }
        do {
            try session.handle.write(contentsOf: session.buffer)
            session.buffer.removeAll(keepingCapacity: true)
        } catch {
            // Cihaz kilitli / disk dolu gibi durumlarda tamponu koruyup
            // bir sonraki denemede tekrar yazmayi dene.
            NSLog("[DataLogger] Yazma hatasi: \(error.localizedDescription)")
        }
    }

    private func closeLocked(key: String) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        flushLocked(session)
        try? session.handle.close()
        if sessions.isEmpty {
            flushTimer?.cancel()
            flushTimer = nil
        }
    }

    private func startTimerLocked() {
        guard flushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for session in self.sessions.values { self.flushLocked(session) }
        }
        timer.resume()
        flushTimer = timer
    }
}
