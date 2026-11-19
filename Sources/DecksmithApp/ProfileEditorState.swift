import Foundation
import AppKit
import DecksmithCore
import DecksmithPluginSwift
import DecksmithPersistence

struct DecksmithEditorPage: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var assignments: [String: PluginAssignment]

    init(id: String = UUID().uuidString, name: String, assignments: [String: PluginAssignment] = [:]) {
        self.id = id
        self.name = name
        self.assignments = assignments
    }
}

struct DecksmithEditorProfile: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var pages: [DecksmithEditorPage]
    var sourceProfileIDs: [String]
    var deviceModel: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        pages: [DecksmithEditorPage],
        sourceProfileIDs: [String] = [],
        deviceModel: String? = "Stream Deck+"
    ) {
        self.id = id
        self.name = name
        self.pages = pages
        self.sourceProfileIDs = sourceProfileIDs
        self.deviceModel = deviceModel
    }
}

struct DecksmithEditorWorkspace: Codable, Sendable, Equatable {
    static let schemaVersion = 2

    var profiles: [DecksmithEditorProfile]
    var selectedProfileID: String?
    var selectedPageID: String?

    static let initial = DecksmithEditorWorkspace(
        profiles: [
            DecksmithEditorProfile(
                name: "Studio",
                pages: [
                    DecksmithEditorPage(name: "Main"),
                    DecksmithEditorPage(name: "Streaming")
                ]
            )
        ],
        selectedProfileID: nil,
        selectedPageID: nil
    )
}

enum DecksmithWorkspaceCodec {
    static let kind = "decksmith.editor.workspace"

    static func encode(_ workspace: DecksmithEditorWorkspace) throws -> Data {
        let envelope = SchemaEnvelope(
            schemaVersion: DecksmithEditorWorkspace.schemaVersion,
            kind: kind,
            value: workspace
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> DecksmithEditorWorkspace {
        let envelope = try JSONDecoder().decode(SchemaEnvelope<DecksmithEditorWorkspace>.self, from: data)
        guard envelope.kind == kind else { throw WorkspaceCodecError.invalidKind }
        return envelope.value
    }
}

enum WorkspaceCodecError: Error, Equatable {
    case invalidKind
    case invalidVendorProfile
}

enum NativeStreamDeckProfileCodec {
    static func export(profile: DecksmithEditorProfile, to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let profileManifest: [String: Any] = [
            "Name": profile.name,
            "UUID": profile.id,
            "Device": profile.deviceModel ?? "Stream Deck+",
            "Pages": profile.pages.map { $0.id }
        ]
        try writeJSON(profileManifest, to: directory.appendingPathComponent("manifest.json"))

        let pagesRoot = directory.appendingPathComponent("Profiles", isDirectory: true)
        for page in profile.pages {
            let pageDirectory = pagesRoot.appendingPathComponent(page.id, isDirectory: true)
            try fileManager.createDirectory(at: pageDirectory, withIntermediateDirectories: true)
            let controllers = page.assignments.reduce(into: [String: Any]()) { result, item in
                let (surfaceID, assignment) = item
                let controller: String
                let position: String
                switch surfaceID.split(separator: ".").first.map(String.init) {
                case "encoder":
                    controller = "Encoder"
                    position = surfaceID.split(separator: ".").last.map(String.init) ?? "0"
                case "touch":
                    controller = "Touchscreen"
                    position = surfaceID.split(separator: ".").last.map(String.init) ?? "0"
                default:
                    controller = "Keypad"
                    let index = Int(surfaceID.split(separator: ".").last ?? "0") ?? 0
                    position = "\(index % 4),\(index / 4)"
                }

                result["\(controller):\(position)"] = [
                    "UUID": assignment.actionID,
                    "Name": assignment.displayName,
                    "Plugin": assignment.pluginID.rawValue,
                    "Settings": decodeSettings(assignment.settings),
                    "State": 0,
                    "States": [["Title": assignment.stateTitle ?? ""]]
                ]
            }
            try writeJSON(
                [
                    "Name": page.name,
                    "UUID": page.id,
                    "Controllers": controllers
                ],
                to: pageDirectory.appendingPathComponent("manifest.json")
            )
        }
    }

    static func exportBackup(profiles: [DecksmithEditorProfile], to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let profilesRoot = directory.appendingPathComponent("Profiles", isDirectory: true)
        for profile in profiles {
            let profileDirectory = profilesRoot.appendingPathComponent("\(profile.id).sdProfile", isDirectory: true)
            try export(profile: profile, to: profileDirectory)
        }
        try writeJSON(
            [
                "Name": "Decksmith export",
                "Profiles": profiles.map { $0.id }
            ],
            to: directory.appendingPathComponent("manifest.json")
        )
    }

    static func writeJSON(_ value: Any, to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw WorkspaceCodecError.invalidVendorProfile
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func decodeSettings(_ data: Data) -> Any {
        guard !data.isEmpty, let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
