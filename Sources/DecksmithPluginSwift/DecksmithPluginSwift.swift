import Foundation
import DecksmithCore
import DecksmithRendering

public struct PluginManifest: Codable, Sendable, Equatable {
    public let id: PluginID
    public let name: String
    public let sdkVersion: Int
    public let version: String
    public let author: String
    public let description: String
    public init(
        id: PluginID,
        name: String,
        sdkVersion: Int = 1,
        version: String = "unknown",
        author: String = "",
        description: String = ""
    ) {
        self.id = id
        self.name = name
        self.sdkVersion = sdkVersion
        self.version = version
        self.author = author
        self.description = description
    }
}

public struct PluginActionDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let supportedControls: Set<String>

    public init(id: String, name: String, summary: String, supportedControls: Set<String> = ["key", "encoder", "touch"]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.supportedControls = supportedControls
    }
}

public struct PluginAssignment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let pluginID: PluginID
    public let actionID: String
    public let displayName: String
    public let settings: Data
    public let imagePath: String?
    public let stateTitle: String?

    public init(
        surfaceID: String,
        pluginID: PluginID,
        actionID: String,
        displayName: String,
        settings: Data = Data(),
        imagePath: String? = nil,
        stateTitle: String? = nil
    ) {
        self.id = surfaceID
        self.pluginID = pluginID
        self.actionID = actionID
        self.displayName = displayName
        self.settings = settings
        self.imagePath = imagePath
        self.stateTitle = stateTitle
    }
}

public struct PluginPackage: Codable, Sendable, Equatable, Identifiable {
    public let manifest: PluginManifest
    public let actions: [PluginActionDefinition]
    public let sourcePath: String?
    public let executablePath: String?

    public var id: PluginID { manifest.id }

    public init(manifest: PluginManifest, actions: [PluginActionDefinition], sourcePath: String? = nil, executablePath: String? = nil) {
        self.manifest = manifest
        self.actions = actions
        self.sourcePath = sourcePath
        self.executablePath = executablePath
    }
}

public struct PluginProfileAssignment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let controller: String
    public let position: String
    public let actionID: String
    public let name: String
    public let settings: Data
    public let pluginID: PluginID?
    public let pluginName: String?
    public let imagePath: String?
    public let stateTitle: String?

    public init(
        controller: String,
        position: String,
        actionID: String,
        name: String,
        settings: Data = Data(),
        pluginID: PluginID? = nil,
        pluginName: String? = nil,
        imagePath: String? = nil,
        stateTitle: String? = nil
    ) {
        self.controller = controller
        self.position = position
        self.actionID = actionID
        self.name = name
        self.settings = settings
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.imagePath = imagePath
        self.stateTitle = stateTitle
        self.id = "\(controller):\(position)"
    }
}

public struct PluginProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let profileID: String
    public let pageID: String
    public let name: String
    public let pageName: String
    public let pluginID: PluginID
    public let deviceModel: String?
    public let assignments: [PluginProfileAssignment]
    public let sourcePath: String

    public init(
        id: String,
        profileID: String = "",
        pageID: String = "",
        name: String,
        pageName: String = "Main",
        pluginID: PluginID,
        deviceModel: String?,
        assignments: [PluginProfileAssignment],
        sourcePath: String
    ) {
        self.id = id
        self.profileID = profileID.isEmpty ? id : profileID
        self.pageID = pageID.isEmpty ? id : pageID
        self.name = name
        self.pageName = pageName
        self.pluginID = pluginID
        self.deviceModel = deviceModel
        self.assignments = assignments
        self.sourcePath = sourcePath
    }
}

public enum StreamDeckPluginImportError: Error, Equatable {
    case invalidManifest
    case unreadableManifest
    case unsupportedProfile
    case profileExtractionFailed
}

public enum StreamDeckPluginImporter {
    public static func installedPackages(fileManager: FileManager = .default) -> [PluginPackage] {
        let roots = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.elgato.StreamDeck/Plugins"),
            URL(fileURLWithPath: "/Library/Application Support/com.elgato.StreamDeck/Plugins")
        ]
        return roots.flatMap { root -> [PluginPackage] in
            guard let directories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            return directories.compactMap { directory -> PluginPackage? in
                if let package = try? importPackage(at: directory, fileManager: fileManager) {
                    return package
                }
                return fallbackPackage(at: directory)
            }
        }
    }

    public static func installedPackage(
        withID id: PluginID,
        fileManager: FileManager = .default
    ) -> PluginPackage? {
        installedPackages(fileManager: fileManager).first { $0.id == id }
    }

    public static func importPackage(at directory: URL, fileManager: FileManager = .default) throws -> PluginPackage {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw StreamDeckPluginImportError.unreadableManifest
        }
        return try importPackage(manifestData: data, sourcePath: directory.path)
    }

    public static func importProfile(at archive: URL, fileManager: FileManager = .default) throws -> PluginProfile {
        try importProfiles(at: archive, fileManager: fileManager).first ?? {
            throw StreamDeckPluginImportError.unsupportedProfile
        }()
    }

    public static func importProfiles(at archive: URL, fileManager: FileManager = .default) throws -> [PluginProfile] {
        #if os(macOS)
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("decksmith-profile-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        guard runArchiveTool(arguments: ["-xf", archive.path, "-C", temporaryDirectory.path]) else {
            throw StreamDeckPluginImportError.profileExtractionFailed
        }

        let manifests = fileManager.enumerator(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "manifest.json" } ?? []
        let profileRoots = manifests.filter {
            $0.deletingLastPathComponent().lastPathComponent.hasSuffix(".sdProfile")
        }
        var imported: [PluginProfile] = []
        for rootManifestURL in profileRoots {
            guard let rootData = try? Data(contentsOf: rootManifestURL),
                  let root = try? JSONSerialization.jsonObject(with: rootData) as? [String: Any],
                  let profileName = root["Name"] as? String
            else { continue }
            let profileDirectory = rootManifestURL.deletingLastPathComponent()
            let pageManifests = manifests.filter {
                $0.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() == profileDirectory
            }
            let fallbackPluginID = root["InstalledByPluginUUID"] as? String
            var pages: [String: (name: String, assignments: [PluginProfileAssignment])] = [:]
            for pageManifestURL in pageManifests {
                guard let data = try? Data(contentsOf: pageManifestURL),
                      let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let controllers = page["Controllers"] as? [[String: Any]]
                else { continue }
                let pageID = pageManifestURL.deletingLastPathComponent().lastPathComponent
                let pageName = page["Name"] as? String ?? pageID
                pages[pageID] = (pageName, [])
                for controller in controllers {
                    guard let type = controller["Type"] as? String,
                          let actions = controller["Actions"] as? [String: [String: Any]]
                    else { continue }
                    for (position, action) in actions {
                        guard let actionID = action["UUID"] as? String else { continue }
                        let plugin = action["Plugin"] as? [String: Any]
                        let pluginID = (plugin?["UUID"] as? String).map(PluginID.init(rawValue:))
                            ?? fallbackPluginID.map { PluginID(rawValue: $0) }
                        guard let pluginID else { continue }
                        let name = action["Name"] as? String ?? actionID
                        let settings = (try? JSONSerialization.data(withJSONObject: action["Settings"] ?? [:])) ?? Data()
                        let states = action["States"] as? [[String: Any]] ?? []
                        let stateIndex = action["State"] as? Int ?? 0
                        let state = states.indices.contains(stateIndex) ? states[stateIndex] : states.first
                        let stateTitle = state?["Title"] as? String
                        let imagePath = (state?["Image"] as? String).flatMap {
                            copyProfileAsset(
                                relativePath: $0,
                                from: pageManifestURL.deletingLastPathComponent(),
                                actionID: actionID,
                                fileManager: fileManager
                            )
                        } ?? resolveInstalledPluginAsset(
                            pluginID: pluginID,
                            actionID: actionID,
                            stateIndex: stateIndex,
                            fileManager: fileManager
                        )
                        pages[pageID, default: (pageName, [])].assignments.append(PluginProfileAssignment(
                            controller: type,
                            position: position,
                            actionID: actionID,
                            name: name,
                            settings: settings,
                            pluginID: pluginID,
                            pluginName: plugin?["Name"] as? String,
                            imagePath: imagePath,
                            stateTitle: stateTitle
                        ))
                    }
                }
            }
            let profileID = (root["UUID"] as? String)
                ?? profileDirectory.lastPathComponent
            let deviceModel = (root["Device"] as? [String: Any])?["Model"] as? String
            if pages.isEmpty {
                imported.append(PluginProfile(
                    id: "\(profileID):main",
                    profileID: profileID,
                    pageID: "main",
                    name: profileName,
                    pageName: "Main",
                    pluginID: PluginID(rawValue: "com.decksmith.empty"),
                    deviceModel: deviceModel,
                    assignments: [],
                    sourcePath: archive.path
                ))
            } else {
                for (pageID, page) in pages {
                    let pageAssignments = page.assignments
                    imported.append(PluginProfile(
                        id: "\(profileID):\(pageID)",
                        profileID: profileID,
                        pageID: pageID,
                        name: profileName,
                        pageName: page.name,
                        pluginID: pageAssignments.first?.pluginID ?? PluginID(rawValue: "com.decksmith.empty"),
                        deviceModel: deviceModel,
                        assignments: pageAssignments,
                        sourcePath: archive.path
                    ))
                }
            }
        }
        guard !imported.isEmpty else { throw StreamDeckPluginImportError.unsupportedProfile }
        return imported
        #else
        throw StreamDeckPluginImportError.profileExtractionFailed
        #endif
    }

    private static func importPackage(manifestData data: Data, sourcePath: String) throws -> PluginPackage {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let uuid = root["UUID"] as? String,
            let name = root["Name"] as? String
        else {
            throw StreamDeckPluginImportError.invalidManifest
        }

        let version = root["Version"] as? String ?? "unknown"
        let author = root["Author"] as? String ?? ""
        let description = root["Description"] as? String ?? ""
        let executablePath = (root["CodePathMac"] as? String).map {
            URL(fileURLWithPath: sourcePath).appendingPathComponent($0).path
        }
        let actions = (root["Actions"] as? [[String: Any]] ?? []).compactMap { action -> PluginActionDefinition? in
            guard let actionID = action["UUID"] as? String else { return nil }
            let actionName = action["Name"] as? String ?? actionID
            let summary = action["Tooltip"] as? String ?? actionName
            let controllers = Set((action["Controllers"] as? [String]) ?? ["Keypad"])
                .map { controller in
                    switch controller.lowercased() {
                    case "encoder": return "encoder"
                    case "touchscreen": return "touch"
                    default: return "key"
                    }
                }
            return PluginActionDefinition(
                id: actionID,
                name: actionName,
                summary: summary,
                supportedControls: Set(controllers)
            )
        }

        return PluginPackage(
            manifest: PluginManifest(
                id: PluginID(rawValue: uuid),
                name: name,
                sdkVersion: Int(root["SDKVersion"] as? String ?? "1") ?? 1,
                version: version,
                author: author,
                description: description
            ),
            actions: actions,
            sourcePath: sourcePath,
            executablePath: executablePath
        )
    }

    private static func fallbackPackage(at directory: URL) -> PluginPackage? {
        let pluginID = directory.deletingPathExtension().lastPathComponent
        guard pluginID.contains(".") else { return nil }
        let candidates = [
            directory.appendingPathComponent("bin/plugin.js"),
            directory.appendingPathComponent("plugin.js"),
            directory.appendingPathComponent("bin/plugin")
        ]
        let executablePath = candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
        guard executablePath != nil else { return nil }
        return PluginPackage(
            manifest: PluginManifest(
                id: PluginID(rawValue: pluginID),
                name: pluginID,
                description: "Installed Stream Deck plugin"
            ),
            actions: [],
            sourcePath: directory.path,
            executablePath: executablePath
        )
    }

    #if os(macOS)
    private static func copyProfileAsset(
        relativePath: String,
        from profileDirectory: URL,
        actionID: String,
        fileManager: FileManager
    ) -> String? {
        let source = profileDirectory.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let assetRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Decksmith/ProfileAssets", isDirectory: true)
        do {
            try fileManager.createDirectory(at: assetRoot, withIntermediateDirectories: true)
            let destination = assetRoot.appendingPathComponent("\(actionID)-\(source.deletingPathExtension().lastPathComponent).png")
            try ImageAssetNormalizer.normalize(
                data: Data(contentsOf: source),
                to: destination,
                canvasSize: PixelSize(width: 120, height: 120)
            )
            return destination.path
        } catch {
            return nil
        }
    }

    public static func resolveInstalledPluginAsset(
        pluginID: PluginID,
        actionID: String,
        stateIndex: Int,
        fileManager: FileManager
    ) -> String? {
        let roots = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.elgato.StreamDeck/Plugins"),
            URL(fileURLWithPath: "/Library/Application Support/com.elgato.StreamDeck/Plugins"),
            URL(fileURLWithPath: "/Applications/Elgato Stream Deck.app/Contents/Resources/Plugins")
        ]
        guard let pluginDirectory = roots
            .map({ $0.appendingPathComponent("\(pluginID.rawValue).sdPlugin") })
            .first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return nil
        }

        var source: URL?
        if let data = try? Data(contentsOf: pluginDirectory.appendingPathComponent("manifest.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let actions = root["Actions"] as? [[String: Any]],
           let action = actions.first(where: { $0["UUID"] as? String == actionID }),
           let states = action["States"] as? [[String: Any]],
           states.indices.contains(stateIndex),
           let imageIdentifier = states[stateIndex]["Image"] as? String {
            let candidates = [
                imageIdentifier,
                "\(imageIdentifier).png",
                "\(imageIdentifier).jpg",
                "\(imageIdentifier).jpeg",
                "\(imageIdentifier).svg"
            ].map { pluginDirectory.appendingPathComponent($0) }
            source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
        }

        if source == nil, pluginID.rawValue == "com.eladavron.litra-glow-commander" {
            let filename = stateIndex == 0 ? "litra_glow_off.svg" : "litra_glow_on.svg"
            let candidates = [
                "imgs/actions/\(filename)",
                "imgs/actions/toggle_outline.svg"
            ].map { pluginDirectory.appendingPathComponent($0) }
            source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
        }

        if source == nil, pluginID.rawValue == "com.elgato.streamdeck.profile.rotate" {
            let candidates = [
                "Images/switchProfile.svg",
                "Images/btn_switchProfile.svg"
            ].map { pluginDirectory.appendingPathComponent($0) }
            source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
        }

        guard let source else {
            return nil
        }

        let assetRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Decksmith/ProfileAssets", isDirectory: true)
        do {
            try fileManager.createDirectory(at: assetRoot, withIntermediateDirectories: true)
            let destination = assetRoot.appendingPathComponent("\(actionID)-\(source.deletingPathExtension().lastPathComponent).png")
            try ImageAssetNormalizer.normalize(
                data: Data(contentsOf: source),
                to: destination,
                canvasSize: PixelSize(width: 120, height: 120)
            )
            return destination.path
        } catch {
            return nil
        }
    }
    #endif

    #if os(macOS)
    private static func runArchiveTool(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    #endif
}

public protocol DecksmithPlugin: Sendable {
    var manifest: PluginManifest { get }
    func activate() async throws
    func handle(_ event: InputEvent) async
    func deactivate() async
}

public enum PluginCommand: Codable, Sendable, Equatable {
    case setSurface(SurfaceUpdate)
    case navigate(NavigationCommand)
    case log(String)
}

public actor PluginContext {
    private var commands: [PluginCommand] = []

    public init() {}

    public func send(_ command: PluginCommand) {
        commands.append(command)
    }

    public func drainCommands() -> [PluginCommand] {
        defer { commands.removeAll(keepingCapacity: true) }
        return commands
    }
}

public struct PluginRegistration: Sendable {
    public let manifest: PluginManifest
    public let context: PluginContext

    public init(manifest: PluginManifest, context: PluginContext = PluginContext()) {
        self.manifest = manifest
        self.context = context
    }
}
