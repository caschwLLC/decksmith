import Foundation
import DecksmithCore

public struct DecksmithEvent: Codable, Sendable {
    public let timestamp: Date
    public let category: String
    public let message: String
    public init(timestamp: Date = .now, category: String, message: String) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

public actor EventJournal {
    private let logger: FileDiagnosticLogger

    public init(fileURL: URL? = nil) {
        logger = FileDiagnosticLogger(fileURL: fileURL ?? FileDiagnosticLogger.defaultFileURL())
    }

    public func append(_ event: DecksmithEvent) async {
        await logger.append(category: event.category, message: event.message, timestamp: event.timestamp)
    }

    public func snapshot() async -> [DecksmithEvent] {
        await logger.read(category: nil).compactMap { record in
            DecksmithEvent(timestamp: record.timestamp, category: record.category, message: record.message)
        }
    }
}

public struct MetricSample: Codable, Sendable, Equatable {
    public let name: String
    public let value: Double
    public let timestamp: Date

    public init(name: String, value: Double, timestamp: Date = .now) {
        self.name = name
        self.value = value
        self.timestamp = timestamp
    }
}

public struct ForensicRecord: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let category: String
    public let payload: Data

    public init(timestamp: Date = .now, category: String, payload: Data) {
        self.timestamp = timestamp
        self.category = category
        self.payload = payload
    }
}

public actor DiagnosticsStore {
    private let logger: FileDiagnosticLogger

    public init(fileURL: URL? = nil) {
        logger = FileDiagnosticLogger(fileURL: fileURL ?? FileDiagnosticLogger.defaultFileURL())
    }

    public func record(_ sample: MetricSample) async {
        await logger.append(
            category: "metric.\(sample.name)",
            message: String(sample.value),
            timestamp: sample.timestamp
        )
    }

    public func capture(_ record: ForensicRecord) async {
        await logger.append(
            category: record.category,
            message: record.payload.base64EncodedString(),
            timestamp: record.timestamp
        )
    }

    public func metricSnapshot() async -> [MetricSample] {
        await logger.read(categoryPrefix: "metric.").compactMap { record in
            guard let value = Double(record.message) else { return nil }
            return MetricSample(
                name: String(record.category.dropFirst("metric.".count)),
                value: value,
                timestamp: record.timestamp
            )
        }
    }

    public func forensicSnapshot() async -> [ForensicRecord] {
        await logger.read(category: nil).compactMap { record in
            guard !record.category.hasPrefix("metric."),
                  let payload = Data(base64Encoded: record.message)
            else { return nil }
            return ForensicRecord(timestamp: record.timestamp, category: record.category, payload: payload)
        }
    }

    public func fileURL() -> URL { logger.fileURL }
}

public actor FileDiagnosticLogger {
    public struct Record: Codable, Sendable, Equatable {
        public let timestamp: Date
        public let category: String
        public let message: String

        public init(timestamp: Date, category: String, message: String) {
            self.timestamp = timestamp
            self.category = category
            self.message = message
        }
    }

    public let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Decksmith/Logs/decksmith.log")
    }

    public func append(category: String, message: String, timestamp: Date = .now) {
        let record = Record(timestamp: timestamp, category: category, message: message)
        guard let data = try? encoder.encode(record) else { return }
        var line = data
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: line)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    public func read(category: String?) -> [Record] {
        readAll().filter { category == nil || $0.category == category }
    }

    public func read(categoryPrefix prefix: String) -> [Record] {
        readAll().filter { $0.category.hasPrefix(prefix) }
    }

    private func readAll() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(Record.self, from: Data(line))
        }
    }
}
