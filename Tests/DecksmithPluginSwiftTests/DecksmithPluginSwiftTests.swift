import Foundation
import Testing
@testable import DecksmithPluginSwift

struct DecksmithPluginSwiftTests {
    @Test
    func importsPluginManifestWithoutImplementingPluginBehavior() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decksmith-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = """
        {
          "UUID": "com.example.volume",
          "Name": "Existing Volume Controller",
          "SDKVersion": "2",
          "Version": "1.2.3",
          "Author": "Example",
          "Actions": [
            {"UUID": "com.example.volume.action", "Name": "Volume", "Tooltip": "Imported action", "Controllers": ["Encoder"]}
          ]
        }
        """
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))

        let package = try StreamDeckPluginImporter.importPackage(at: directory)

        #expect(package.manifest.name == "Existing Volume Controller")
        #expect(package.actions.first?.id == "com.example.volume.action")
        #expect(package.actions.first?.supportedControls == ["encoder"])
    }

    @Test
    func importsMultiProfileBackupWithPerActionPluginIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("decksmith-backup-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("Profiles/Test.sdProfile", isDirectory: true)
        let page = profile.appendingPathComponent("Profiles/page-1", isDirectory: true)
        try FileManager.default.createDirectory(at: page, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rootManifest = """
        {"Name":"Test","Device":{"Model":"20GBD9901"},"Pages":{"Current":"page-1"}}
        """
        let pageManifest = """
        {"Controllers":[{"Type":"Keypad","Actions":{"0,0":{"UUID":"com.example.key","Name":"Key","Plugin":{"UUID":"com.example.keys","Name":"Keys"},"Settings":{"value":true},"State":1,"States":[{"Title":"Off"},{"Title":"On","Image":"Images/key.png"}]}}},{"Type":"Encoder","Actions":{"0,0":{"UUID":"com.example.encoder","Name":"Encoder","Plugin":{"UUID":"com.example.encoders","Name":"Encoders"},"Settings":{"value":2}}}}]}
        """
        try Data(rootManifest.utf8).write(to: profile.appendingPathComponent("manifest.json"))
        try Data(pageManifest.utf8).write(to: page.appendingPathComponent("manifest.json"))
        try FileManager.default.createDirectory(at: page.appendingPathComponent("Images"), withIntermediateDirectories: true)
        let validPNG = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try validPNG.write(to: page.appendingPathComponent("Images/key.png"))

        let archive = root.deletingLastPathComponent()
            .appendingPathComponent("decksmith-backup-\(UUID().uuidString).streamDeckProfilesBackup")
        defer { try? FileManager.default.removeItem(at: archive) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-cf", archive.path, "-C", root.deletingLastPathComponent().path, root.lastPathComponent]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let profiles = try StreamDeckPluginImporter.importProfiles(at: archive)
        #expect(profiles.count == 1)
        #expect(profiles.reduce(0) { $0 + $1.assignments.count } == 2)
        #expect(profiles.first?.name == "Test")
        #expect(profiles.first?.pageName == "page-1")
        #expect(profiles.first?.assignments.contains { $0.pluginID?.rawValue == "com.example.keys" } == true)
        #expect(profiles.first?.assignments.contains { $0.pluginID?.rawValue == "com.example.encoders" } == true)
        #expect(profiles.first?.assignments.first?.pluginID != nil)
        let keyAssignment = profiles
            .flatMap(\.assignments)
            .first { $0.actionID == "com.example.key" }
        #expect(keyAssignment?.stateTitle == "On")
        #expect(keyAssignment?.imagePath.map { FileManager.default.fileExists(atPath: $0) } == true)
    }
}
