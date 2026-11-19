import Foundation
import Testing
@testable import DecksmithObservability

struct DecksmithObservabilityTests {
    @Test
    func diagnosticsPersistAsJsonLines() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decksmith-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let logger = FileDiagnosticLogger(fileURL: url)
        await logger.append(category: "import.error", message: "invalid manifest")

        let records = await logger.read(category: "import.error")
        #expect(records.count == 1)
        #expect(records.first?.message == "invalid manifest")
        #expect((try? String(contentsOf: url, encoding: .utf8))?.contains("\"category\":\"import.error\"") == true)
    }
}
