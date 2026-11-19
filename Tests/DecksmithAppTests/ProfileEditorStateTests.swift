import XCTest
@testable import DecksmithApp
import DecksmithPluginSwift
import DecksmithCore

final class ProfileEditorStateTests: XCTestCase {
    func testWorkspaceCodecRoundTripsProfilesAndPages() throws {
        let assignment = PluginAssignment(
            surfaceID: "key.0",
            pluginID: PluginID(rawValue: "example.plugin"),
            actionID: "com.example.action",
            displayName: "Example Action"
        )
        let profile = DecksmithEditorProfile(
            name: "Studio",
            pages: [DecksmithEditorPage(name: "Main", assignments: ["key.0": assignment])]
        )
        let workspace = DecksmithEditorWorkspace(
            profiles: [profile],
            selectedProfileID: profile.id,
            selectedPageID: profile.pages[0].id
        )

        let data = try DecksmithWorkspaceCodec.encode(workspace)
        XCTAssertEqual(try DecksmithWorkspaceCodec.decode(data), workspace)
    }

    func testNativeExportWritesPageManifestWithControllerMapping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("decksmith-profile-\(UUID().uuidString).streamDeckProfile")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = DecksmithEditorProfile(
            name: "Studio",
            pages: [
                DecksmithEditorPage(
                    id: "page-1",
                    name: "Main",
                    assignments: [
                        "key.0": PluginAssignment(
                            surfaceID: "key.0",
                            pluginID: PluginID(rawValue: "example.plugin"),
                            actionID: "action",
                            displayName: "Action"
                        )
                    ]
                )
            ]
        )

        try NativeStreamDeckProfileCodec.export(profile: profile, to: root)
        let manifestURL = root.appendingPathComponent("Profiles/page-1/manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        let controllers = manifest?["Controllers"] as? [String: Any]
        XCTAssertEqual(manifest?["Name"] as? String, "Main")
        XCTAssertNotNil(controllers?["Keypad:0,0"])
    }

    func testNativeBackupExportWrapsProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("decksmith-backup-\(UUID().uuidString).streamDeckProfilesBackup")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = DecksmithEditorProfile(name: "Studio", pages: [DecksmithEditorPage(name: "Main")])

        try NativeStreamDeckProfileCodec.exportBackup(profiles: [profile], to: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Profiles/\(profile.id).sdProfile/manifest.json").path))
    }
}
