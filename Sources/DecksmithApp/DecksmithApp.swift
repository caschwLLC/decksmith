import SwiftUI
import Foundation
import AppKit
import DecksmithCore
import DecksmithDevice
import DecksmithProtocol
import DecksmithRendering
import DecksmithRuntime
import DecksmithPluginSwift
import DecksmithPluginWebSocket
import DecksmithTransport
import DecksmithObservability
import DecksmithPersistence
import UniformTypeIdentifiers

@main
struct DecksmithApp: App {
    @NSApplicationDelegateAdaptor(DecksmithAppDelegate.self) private var appDelegate
    @StateObject private var model = DecksmithAppModel()

    init() {
        let model = DecksmithAppModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.model = model
    }

    var body: some Scene {
        WindowGroup("Decksmith") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            DecksmithCommands(model: model)
        }
    }

}

@MainActor
final class DecksmithAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: DecksmithAppModel?
    private var terminationInProgress = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { [weak self, weak sender] in
            await self?.model?.shutdown()
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class DecksmithAppModel: ObservableObject {
    private struct PluginFeedback {
        var value: String?
        var indicator: Double?
        var imagePath: String?
    }

    @Published var selectedControl = 0
    @Published var activePage = 0
    @Published var selectedProfileID: String?
    @Published var selectedPageID: String?
    @Published private(set) var editorProfiles: [DecksmithEditorProfile] = []
    @Published private(set) var connected = false
    @Published private(set) var lastEvent = "Waiting for input"
    @Published private(set) var eventCount = 0
    @Published private(set) var reportCount = 0
    @Published var brightness: Double = 70
    @Published private(set) var devices: [HIDDeviceDescriptor] = []
    @Published var selectedDeviceID: String?
    @Published var selectedSurfaceID = "encoder.0"
    @Published private(set) var plugins: [PluginPackage] = []
    @Published private(set) var renderedPreviewImages: [String: NSImage] = [:]
    @Published private(set) var importedProfiles: [PluginProfile] = []
    @Published private(set) var activeImportedProfileName: String?
    @Published var selectedPluginID: PluginID?
    @Published var selectedActionID: String?
    @Published var isImportingPlugin = false
    @Published private(set) var diagnosticLogPath = FileDiagnosticLogger.defaultFileURL().path

    var pages: [String] {
        currentProfile?.pages.map(\.name) ?? ["Main"]
    }
    private let diagnostics = FileDiagnosticLogger(fileURL: FileDiagnosticLogger.defaultFileURL())
    private let pluginRuntime = PluginRuntime()
    private var transport: (any HIDTransport)?
    private var session: DeviceSession?
    private var pluginPorts: [PluginID: UInt16] = [:]
    private let pluginPortBase = UInt16.random(in: 30000...40000)
    private var startedPlugins: Set<PluginID> = []
    private var pluginMessageTasks: [PluginID: Task<Void, Never>] = [:]
    private var pluginFeedback: [String: PluginFeedback] = [:]
    private var encoderPressed: [String: Bool] = [:]
    private var pushTask: Task<Void, Never>?
    private var pushGeneration: UInt64 = 0

    private var revision: UInt64 = 0
    private var eventTask: Task<Void, Never>?

    init() {
        refreshDevices()
        loadInstalledPlugins()
        loadEditorWorkspace()
        loadAssignments()
        if let launchProfileURL {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log("plugin.profile.launch", "Injecting profile \(launchProfileURL.path)")
                self.importProfile(from: launchProfileURL)
            }

        }
    }

    private var launchProfileURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--profile-backup"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        if let path = ProcessInfo.processInfo.environment["DECKSMITH_PROFILE_BACKUP"] {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    deinit {
        eventTask?.cancel()
        let pluginRuntime = pluginRuntime
        Task {
            await pluginRuntime.stopAllExternal()
        }
    }

    func shutdown() async {
        pushTask?.cancel()
        pushTask = nil
        eventTask?.cancel()
        eventTask = nil

        for task in pluginMessageTasks.values {
            task.cancel()
        }
        pluginMessageTasks.removeAll()

        log("app.shutdown", "Closing device session and external plugin connections")
        await session?.disconnect()
        session = nil
        await pluginRuntime.stopAllExternal()
        transport = nil
        connected = false
        log("app.shutdown", "All device and plugin connections closed")
    }

    func selectControl(_ index: Int) {
        selectedControl = index
        selectSurface("key.\(index)")
    }

    func selectEncoder(_ index: Int) {
        selectSurface("encoder.\(index)")
    }

    func selectTouchSegment(_ index: Int) {
        selectSurface("touch.\(index)")
    }

    func selectSurface(_ surfaceID: String) {
        selectedSurfaceID = surfaceID
        if let action = availableActions.first {
            selectedActionID = action.id
        } else {
            selectedActionID = nil
        }
    }

    func loadInstalledPlugins() {
        Task {
            let installed = StreamDeckPluginImporter.installedPackages()
            await MainActor.run {
                self.log(
                    "plugin.discovery",
                    "Discovered \(installed.count) installed packages: " +
                        installed.map {
                            "\($0.id.rawValue)=\($0.executablePath ?? "no-executable")"
                        }.joined(separator: ",")
                )
                for package in installed where !self.plugins.contains(where: { $0.id == package.id }) {
                    self.plugins.append(package)
                }
                if self.selectedPluginID == nil {
                    self.selectedPluginID = self.plugins.first?.id
                    self.selectedActionID = self.plugins.first?.actions.first?.id
                }
                if !self.assignments.isEmpty {
                    self.startExternalPluginsForAssignments()
                }
            }
        }
    }

    func importPlugin(from url: URL) {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if ["streamDeckProfile", "streamDeckProfilesBackup"]
            .contains(where: { url.pathExtension.caseInsensitiveCompare($0) == .orderedSame }) {
            importProfile(from: url)
            return
        }
        do {
            let directory = url.lastPathComponent == "manifest.json" ? url.deletingLastPathComponent() : url
            let package: PluginPackage
            do {
                package = try StreamDeckPluginImporter.importPackage(at: directory)
            } catch StreamDeckPluginImportError.invalidManifest where directory.pathExtension == "sdPlugin" {
                let pluginID = directory.deletingPathExtension().lastPathComponent
                package = PluginPackage(
                    manifest: PluginManifest(
                        id: PluginID(rawValue: pluginID),
                        name: pluginID,
                        description: "Installed Stream Deck plugin; metadata is managed by Stream Deck"
                    ),
                    actions: [],
                    sourcePath: directory.path
                )
                persistAssignments()
            }
            if !plugins.contains(where: { $0.id == package.id }) {
                plugins.append(package)
            }
            selectedPluginID = package.id
            selectedActionID = package.actions.first(where: { $0.supportedControls.contains(controlKind(for: selectedSurfaceID)) })?.id
            lastEvent = "Imported \(package.manifest.name)"
            let actionSummary = package.actions.map {
                "\($0.id)[\($0.supportedControls.sorted().joined(separator: ","))]"
            }.joined(separator: ";")
            log("plugin.import", "Imported plugin name=\(package.manifest.name) id=\(package.id.rawValue) actions=\(package.actions.count) definitions=\(actionSummary) source=\(directory.path)")
        } catch {
            lastEvent = "Plugin import failed: \(error)"
            log("plugin.import.error", "\(error)")
        }
    }

    func reportImportFailure(_ error: Error) {
        lastEvent = "Import cancelled or failed: \(error.localizedDescription)"
        log("plugin.import.error", "\(error.localizedDescription)")
    }

    func importDecksmithBackupFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .item]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let workspace = try DecksmithWorkspaceCodec.decode(Data(contentsOf: url))
            editorProfiles = workspace.profiles
            selectedProfileID = workspace.selectedProfileID
            selectedPageID = workspace.selectedPageID
            normalizeEditorSelection()
            syncAssignmentsFromCurrentPage()
            persistEditorWorkspace()
            pushAssignmentsToDevice()
            lastEvent = "Imported Decksmith backup"
        } catch {
            lastEvent = "Decksmith backup import failed: \(error.localizedDescription)"
            log("workspace.import.error", "\(error)")
        }
    }

    func exportDecksmithBackupFromPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Decksmith.backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DecksmithWorkspaceCodec.encode(
                DecksmithEditorWorkspace(
                    profiles: editorProfiles,
                    selectedProfileID: selectedProfileID,
                    selectedPageID: selectedPageID
                )
            ).write(to: url, options: .atomic)
            lastEvent = "Exported Decksmith backup"
        } catch {
            lastEvent = "Decksmith backup export failed: \(error.localizedDescription)"
            log("workspace.export.error", "\(error)")
        }
    }

    func importVendorProfileFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importProfile(from: url)
    }

    func exportVendorProfileFromPanel() {
        guard let profile = currentProfile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile.name).streamDeckProfile"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NativeStreamDeckProfileCodec.export(profile: profile, to: url)
            lastEvent = "Exported native Stream Deck profile"
        } catch {
            lastEvent = "Native profile export failed: \(error.localizedDescription)"
            log("workspace.vendor.export.error", "\(error)")
        }
    }

    func exportVendorBackupFromPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Decksmith.streamDeckProfilesBackup"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NativeStreamDeckProfileCodec.exportBackup(profiles: editorProfiles, to: url)
            lastEvent = "Exported native Stream Deck backup"
        } catch {
            lastEvent = "Native backup export failed: \(error.localizedDescription)"
            log("workspace.vendor.backup.error", "\(error)")
        }
    }

    func importProfile(from url: URL) {
        do {
            let profiles = try StreamDeckPluginImporter.importProfiles(at: url)
            for profile in profiles {
                importedProfiles.removeAll { $0.id == profile.id }
                importedProfiles.append(profile)
                let groupedActions = Dictionary(
                    profile.assignments.compactMap { assignment -> (PluginID, PluginActionDefinition)? in
                        guard let pluginID = assignment.pluginID else { return nil }
                        return (
                            pluginID,
                            PluginActionDefinition(
                                id: assignment.actionID,
                                name: assignment.name,
                                summary: "Imported from \(profile.name)",
                                supportedControls: assignment.controller.lowercased() == "encoder" ? ["encoder", "touch"] : ["key"]
                            )
                        )
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                for (pluginID, action) in groupedActions {
                    mergeImportedPluginAction(
                        pluginID: pluginID,
                        pluginName: profile.assignments.first(where: { $0.pluginID == pluginID })?.pluginName,
                        action: action,
                        sourcePath: profile.sourcePath
                    )
                }
                log("plugin.profile.import", "Imported profile \(profile.name) plugin=\(profile.pluginID.rawValue) device=\(profile.deviceModel ?? "unknown") assignments=\(profile.assignments.count)")
            }
            let profileName = profiles.first(where: { $0.name == "Default" })?.name
                ?? profiles.first?.name
            for name in Set(profiles.map(\.name)) {
                upsertImportedEditorProfile(
                    name: name,
                    groups: importedProfiles.filter { $0.name == name }
                )
            }
            if let profileName {
                applyImportedProfile(named: profileName)
            }

            persistAssignments()
            lastEvent = "Imported \(profiles.count) profile/plugin mappings; applied \(profileName ?? "none")"
        } catch {
            lastEvent = "Profile import failed: \(error)"
            log("plugin.profile.import.error", "\(error)")
        }

    }

    private func mergeImportedPluginAction(
        pluginID: PluginID,
        pluginName: String?,
        action: PluginActionDefinition,
        sourcePath: String
    ) {
        guard let index = plugins.firstIndex(where: { $0.id == pluginID }) else {
            plugins.append(PluginPackage(
                manifest: PluginManifest(
                    id: pluginID,
                    name: pluginName ?? pluginID.rawValue,
                    description: "Imported from the existing Stream Deck profile"
                ),
                actions: [action],
                sourcePath: sourcePath
            ))
            return
        }
        let package = plugins[index]
        guard !package.actions.contains(where: { $0.id == action.id }) else { return }
        plugins[index] = PluginPackage(
            manifest: package.manifest,
            actions: (package.actions + [action]).sorted { $0.name < $1.name },
            sourcePath: package.sourcePath,
            executablePath: package.executablePath
        )
    }

    var importedProfileNames: [String] {
        Array(Set(importedProfiles.map(\.name))).sorted()
    }

    func applyImportedProfile(named name: String) {
        let profileGroups = importedProfiles.filter { $0.name == name }
        guard !profileGroups.isEmpty else {
            lastEvent = "Profile \(name) is not available"
            return
        }
        upsertImportedEditorProfile(name: name, groups: profileGroups)
        assignments = currentPageAssignments
        if assignments.isEmpty, let firstPage = profileGroups.first {
            assignments = assignmentsForImportedProfile(firstPage)
        }
        activeImportedProfileName = name
        selectedPluginID = profileGroups.first?.pluginID
        selectedActionID = availableActions.first?.id
        persistAssignments()
        lastEvent = "Applied \(name) to the connected device"
        log("plugin.profile.apply", "Applied profile=\(name) groups=\(profileGroups.count) assignments=\(assignments.count)")
        startExternalPluginsForAssignments()
        pushAssignmentsToDevice()
    }

    private func upsertImportedEditorProfile(name: String, groups: [PluginProfile]) {
        let pages = groups.sorted { $0.pageID < $1.pageID }.map { profile in
            DecksmithEditorPage(
                id: profile.pageID,
                name: profile.pageName,
                assignments: assignmentsForImportedProfile(profile)
            )
        }
        let profileID = groups.first?.profileID ?? UUID().uuidString
        let replacement = DecksmithEditorProfile(
            id: profileID,
            name: name,
            pages: pages.isEmpty ? [DecksmithEditorPage(name: "Main", assignments: assignments)] : pages,
            sourceProfileIDs: groups.map(\.id),
            deviceModel: groups.first?.deviceModel
        )
        if let index = editorProfiles.firstIndex(where: { $0.id == profileID || $0.name == name }) {
            editorProfiles[index] = replacement
        } else {
            editorProfiles.append(replacement)
        }
        selectedProfileID = replacement.id
        selectedPageID = replacement.pages.first?.id
        activePage = 0
        persistEditorWorkspace()
    }

    private func assignmentsForImportedProfile(_ profile: PluginProfile) -> [String: PluginAssignment] {
        profile.assignments.reduce(into: [String: PluginAssignment]()) { result, imported in
            let surfaceID = surfaceID(for: imported)
            result[surfaceID] = PluginAssignment(
                surfaceID: surfaceID,
                pluginID: imported.pluginID ?? profile.pluginID,
                actionID: imported.actionID,
                displayName: importedDisplayName(imported.name, profileName: profile.name),
                settings: imported.settings,
                imagePath: imported.imagePath,
                stateTitle: imported.stateTitle
            )
        }
    }

    private func importedDisplayName(_ name: String, profileName: String) -> String {
        let prefixes = ["\(profileName):", "Default:"]
        for prefix in prefixes where name.hasPrefix(prefix) {
            let stripped = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return stripped }
        }
        return name
    }

    func assignSelectedAction(to surfaceID: String? = nil) {
        if let surfaceID {
            selectedSurfaceID = surfaceID
        }
        guard let plugin = selectedPlugin, let action = selectedAction else {
            lastEvent = "Select a plugin action first"
            log("plugin.assignment.error", "No plugin action selected for \(selectedSurfaceID)")
            return
        }
        guard action.supportedControls.contains(controlKind(for: selectedSurfaceID)) else {
            let supported = action.supportedControls.sorted().joined(separator: ",")
            lastEvent = "\(action.name) cannot be assigned to \(surfaceLabel(selectedSurfaceID))"
            log("plugin.assignment.error", "plugin=\(plugin.id.rawValue) action=\(action.id) surface=\(selectedSurfaceID) required=\(controlKind(for: selectedSurfaceID)) supported=\(supported)")
            return
        }
        assignments[selectedSurfaceID] = PluginAssignment(
            surfaceID: selectedSurfaceID,
            pluginID: plugin.id,
            actionID: action.id,
            displayName: "\(plugin.manifest.name):\(action.name)"
        )
        syncCurrentPageFromAssignments()
        persistAssignments()
        lastEvent = "Assigned \(action.name) to \(selectedSurfaceID)"
        log("plugin.assignment", "Assigned \(plugin.id.rawValue):\(action.id) to \(selectedSurfaceID)")
        renderSurfacePreview(for: selectedSurfaceID)
    }

    func assign(pluginID: PluginID, actionID: String, to surfaceID: String) {
        selectedPluginID = pluginID
        selectedActionID = actionID
        assignSelectedAction(to: surfaceID)
    }

    func clearAssignment(for surfaceID: String) {
        assignments.removeValue(forKey: surfaceID)
        syncCurrentPageFromAssignments()
        persistAssignments()
        lastEvent = "Cleared mapping for \(surfaceLabel(surfaceID))"
        log("plugin.assignment.clear", "Cleared mapping for \(surfaceID)")
        renderSurfacePreview(for: surfaceID)
    }

    func configurationText(for surfaceID: String) -> String {
        guard let data = assignments[surfaceID]?.settings,
              !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    func saveConfiguration(_ text: String, for surfaceID: String) {
        guard var assignment = assignments[surfaceID] else {
            lastEvent = "Assign a plugin action before configuring it"
            return
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            lastEvent = "Configuration must be valid JSON"
            log("plugin.configuration.error", "Invalid JSON for \(surfaceID)")
            return
        }
        assignment = PluginAssignment(
            surfaceID: assignment.id,
            pluginID: assignment.pluginID,
            actionID: assignment.actionID,
            displayName: assignment.displayName,
            settings: normalized,
            imagePath: assignment.imagePath,
            stateTitle: assignment.stateTitle
        )
        assignments[surfaceID] = assignment
        syncCurrentPageFromAssignments()
        persistAssignments()
        lastEvent = "Saved configuration for \(surfaceLabel(surfaceID))"
        log("plugin.configuration", "Saved configuration for \(surfaceID)")
        renderSurfacePreview(for: surfaceID)
    }

    var selectedPlugin: PluginPackage? {
        plugins.first(where: { $0.id == selectedPluginID })
    }

    var selectedAction: PluginActionDefinition? {
        selectedPlugin?.actions.first(where: { $0.id == selectedActionID })
    }

    var availableActions: [PluginActionDefinition] {
        let kind = controlKind(for: selectedSurfaceID)
        return selectedPlugin?.actions.filter { $0.supportedControls.contains(kind) } ?? []
    }

    var controlKindLabel: String {
        switch controlKind(for: selectedSurfaceID) {
        case "encoder": return "encoder"
        case "touch": return "touchscreen"
        default: return "key"
        }
    }

    func selectedPluginChanged() {
        selectedActionID = availableActions.first?.id
        log("plugin.selection", "plugin=\(selectedPluginID?.rawValue ?? "none") surface=\(selectedSurfaceID) compatibleActions=\(availableActions.count)")
    }

    var assignedAction: String? {
        assignments[selectedSurfaceID]?.displayName
    }

    func assignment(for surfaceID: String) -> PluginAssignment? {
        assignments[surfaceID]
    }

    func assignedActionFor(_ surfaceID: String) -> String? {
        assignments[surfaceID]?.displayName
    }

    func compatibleActions(for plugin: PluginPackage, surfaceID: String) -> [PluginActionDefinition] {
        plugin.actions.filter { $0.supportedControls.contains(controlKind(for: surfaceID)) }
    }

    func isSurfaceCompatible(_ action: PluginActionDefinition, surfaceID: String) -> Bool {
        action.supportedControls.contains(controlKind(for: surfaceID))
    }

    var configurableSurfaces: [String] {
        (0..<4).map { "touch.\($0)" } +
        (0..<4).map { "encoder.\($0)" } +
        (0..<8).map { "key.\($0)" }
    }

    func surfaceLabel(_ surfaceID: String) -> String {
        let index = Int(surfaceID.split(separator: ".").last ?? "") ?? 0
        switch controlKind(for: surfaceID) {
        case "touch":
            return "Touch \(index + 1)"
        case "encoder":
            return "Encoder \(index + 1)"
        default:
            return "Key \(index + 1)"
        }
    }

    private func surfaceID(for assignment: PluginProfileAssignment) -> String {
        let components = assignment.position.split(separator: ",").compactMap { Int($0) }
        guard let first = components.first else { return assignment.id }
        switch assignment.controller.lowercased() {
        case "encoder":
            return "encoder.\(first)"
        case "touchscreen":
            return "touch.\(first)"
        default:
            let row = components.dropFirst().first ?? 0
            return "key.\(row * 4 + first)"
        }
    }

    private var assignments: [String: PluginAssignment] = [:]
    private let assignmentStore = DiskVersionedStore<[String: PluginAssignment]>(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Decksmith/assignments.json")
    )
    private let workspaceStore = DiskVersionedStore<DecksmithEditorWorkspace>(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Decksmith/workspace.json")
    )

    func refreshDevices() {
        Task {
            let discovered = IOKitHIDDiscovery.devices(vendorID: 0x0FD9)
            await MainActor.run {
                self.devices = discovered
                if let first = discovered.first {
                    if self.selectedDeviceID == nil || !discovered.contains(where: { $0.id == self.selectedDeviceID }) {
                        self.selectedDeviceID = first.id
                    }
                    if !self.connected {
                        self.connectSelectedDevice()
                    }
                } else if !self.connected {
                    self.lastEvent = "No Stream Deck detected"
                    self.log("device.discovery", "No Elgato HID device detected")
                }
            }
        }
    }

    func connectSelectedDevice() {
        guard let selectedDeviceID, let device = devices.first(where: { $0.id == selectedDeviceID }) else {
            lastEvent = "Select a Stream Deck first"
            log("device.connect.error", "No selected Stream Deck device")
            return
        }
        log("device.connect", "Opening device id=\(device.id) vendor=0x\(String(device.vendorID, radix: 16)) product=0x\(String(device.productID, radix: 16)) serial=\(device.serialNumber ?? "none")")
        let hardwareTransport = IOKitHIDTransport(
            vendorID: device.vendorID,
            productID: device.productID,
            serialNumber: device.serialNumber
        )
        let hardwareSession = DeviceSession(
            transport: hardwareTransport,
            codec: StreamDeckPlusCodec(keyCount: 8, encoderCount: 4),
            renderer: RasterSurfaceRenderer()
        )
        eventTask?.cancel()
        transport = hardwareTransport
        session = hardwareSession
        connected = false
        startSession(hardwareSession)
    }

    func renderSelectedSurface() {
        guard let session else {
            lastEvent = "Connect a Stream Deck before rendering"
            return
        }
        revision &+= 1
        let update = SurfaceUpdate(
            surfaceID: SurfaceID(rawValue: selectedSurfaceID),
            revision: SurfaceRevision(revision),
            presentation: .text(
                title: selectedSurfaceID,
                subtitle: pages[activePage]
            )
        )
        Task {
            do {
                try await session.submit(update)
                let metrics = await session.currentMetrics()
                self.reportCount = metrics.writtenReports
            } catch {
                await MainActor.run { self.lastEvent = "Render failed: \(error)" }
                log("device.render.error", "\(error)")
            }
        }
    }

    func setBrightness() {
        guard let session else {
            lastEvent = "Connect a Stream Deck before changing brightness"
            return
        }
        Task {
            do {
                try await session.setBrightness(UInt8(brightness))
                let metrics = await session.currentMetrics()
                self.reportCount = metrics.writtenReports
            } catch {
                await MainActor.run { self.lastEvent = "Brightness failed: \(error)" }
                log("device.brightness.error", "\(error)")
            }
        }
    }

    func disconnect() {
        Task {
            await session?.disconnect()
            await MainActor.run { self.connected = false }
        }
    }

    private func consume(_ event: InputEvent) {
        eventCount += 1
        switch event {
        case .lifecycle(.discovered):
            lastEvent = "Device discovered"
        case .lifecycle(.connected):
            connected = true
            lastEvent = "Device connected"
            log("device.lifecycle", "connected")
            if assignments.isEmpty {
                pushDefaultTouchscreenIfNeeded()
            } else {
                pushAssignmentsToDevice()
            }
        case .lifecycle(.disconnected):
            connected = false
            lastEvent = "Device disconnected"
            log("device.lifecycle", "disconnected")
        case .lifecycle(.failed):
            connected = false
            lastEvent = "Device session failed"
            log("device.lifecycle.error", "session failed")
        case .key(let controlID, let pressed, _):
            lastEvent = "\(controlID.rawValue) \(pressed ? "pressed" : "released")"
            log("device.input.key", "control=\(controlID.rawValue) state=\(pressed ? "pressed" : "released")")
            dispatchPluginEvent(for: assignments[controlID.rawValue], event: pressed ? "keyDown" : "keyUp", controlID: controlID.rawValue)
            if let index = Int(controlID.rawValue.split(separator: ".").last ?? "") {
                selectedControl = index
            }
        case .encoderRotation(let controlID, let delta, _):
            lastEvent = "\(controlID.rawValue) rotated \(delta > 0 ? "+" : "")\(delta)"
            log("device.input.encoder.rotation", "control=\(controlID.rawValue) delta=\(delta)")
            dispatchPluginEvent(for: assignments[controlID.rawValue], event: "dialRotate", controlID: controlID.rawValue, extra: ["ticks": .number(Double(delta))])
            selectSurface(controlID.rawValue)
        case .encoderPress(let controlID, let pressed, _):
            let controlID = controlID.rawValue
            guard encoderPressed[controlID] != pressed else { return }
            encoderPressed[controlID] = pressed
            lastEvent = "\(controlID) \(pressed ? "pressed" : "released")"
            log("device.input.encoder.press", "control=\(controlID) state=\(pressed ? "pressed" : "released")")
            dispatchPluginEvent(for: assignments[controlID], event: pressed ? "dialDown" : "dialUp", controlID: controlID)
            selectSurface(controlID)
        case .touch(_, let x, let y, let sequence):
            lastEvent = "Touch input received"
            let segment = min(3, max(0, Int(x / 200)))
            let surfaceID = "touch.\(segment)"
            log("device.input.touch", "surface=\(surfaceID) x=\(x) y=\(y) sequence=\(sequence)")
            dispatchPluginEvent(for: assignments[surfaceID], event: "touchTap", controlID: surfaceID, extra: [
                "x": .number(x),
                "y": .number(y)
            ])
        case .protocolAnomaly(let anomaly):
            lastEvent = "Protocol anomaly: \(anomaly.message)"
            log("protocol.anomaly", "report=0x\(String(anomaly.reportID, radix: 16)) bytes=\(anomaly.payload.map { String(format: "%02x", $0) }.joined()) message=\(anomaly.message)")
        }
    }

    private func log(_ category: String, _ message: String) {
        let diagnostics = diagnostics
        Task {
            await diagnostics.append(category: category, message: message)
        }
    }

    private func startSession(_ session: DeviceSession) {
        eventTask = Task { [weak self] in
            guard let self else { return }
            let events = await session.events()
            do {
                try await session.connect()
            } catch {
                await MainActor.run { self.lastEvent = "Connection failed: \(error)" }
                return
            }

            for await event in events {
                guard !Task.isCancelled else { return }
                await MainActor.run { self.consume(event) }
            }
        }
    }

    private func pushDefaultTouchscreenIfNeeded() {
        guard assignments.isEmpty, let session else { return }
        revision &+= 1
        let currentRevision = SurfaceRevision(revision)
        Task {
            do {
                try await session.submit(SurfaceUpdate(
                    surfaceID: SurfaceID(rawValue: "touch.0"),
                    revision: currentRevision,
                    presentation: .text(title: "Decksmith", subtitle: "Connect a profile")
                ))

                log("device.surface", "Pushed default Decksmith touchscreen state")
            } catch {
                log("device.surface.error", "Failed to push default touchscreen state: \(error)")
            }
        }
    }

    private func pushAssignmentsToDevice() {
        refreshRenderedPreviews()
        pushGeneration &+= 1
        guard pushTask == nil else { return }
        pushTask = Task { @MainActor [weak self] in
            while let self {
                let generation = self.pushGeneration
                do {
                    try await Task.sleep(for: .milliseconds(40))
                } catch {
                    self.pushTask = nil
                    return
                }
                guard generation == self.pushGeneration else { continue }
                await self.performPushAssignmentsToDevice()
                if generation == self.pushGeneration {
                    self.pushTask = nil
                    return
                }
            }
        }
    }

    private func performPushAssignmentsToDevice() async {
        guard connected, let session else {
            lastEvent = "Profile loaded; connect a Stream Deck to apply it"
            log(
                "device.profile.apply.defer",
                "connected=\(connected) session=\(session != nil) activeProfile=\(activeImportedProfileName ?? "none")"
            )
            return
        }

        let updates = configurableSurfaces
            .filter { !$0.hasPrefix("touch.") && !$0.hasPrefix("encoder.") }
            .map { surfaceID -> SurfaceUpdate in
            revision &+= 1
            let presentationValue: SurfacePresentation
            if let assignment = assignments[surfaceID] {
                if assignment.imagePath == nil {
                    log(
                        "device.surface.image.missing",
                        "surface=\(surfaceID) plugin=\(assignment.pluginID.rawValue) action=\(assignment.actionID)"
                    )
                }
                presentationValue = presentation(for: assignment, surfaceID: surfaceID)
            } else {
                presentationValue = .blank
            }
            return SurfaceUpdate(
                surfaceID: SurfaceID(rawValue: surfaceID),
                revision: SurfaceRevision(revision),
                presentation: presentationValue
            )
        }
        revision &+= 1
        let touchscreenUpdate = SurfaceUpdate(
            surfaceID: SurfaceID(rawValue: "touch.0"),
            revision: SurfaceRevision(revision),
            presentation: touchscreenPresentation()
        )
        do {
            for update in updates + [touchscreenUpdate] {
                let presentationDescription: String
                switch update.presentation {
                case .blank:
                    presentationDescription = "blank"
                case .text(let title, let subtitle):
                    presentationDescription = "text(title=\(title),subtitle=\(subtitle ?? ""))"
                case .image(let assetID):
                    presentationDescription = "image(path=\(assetID))"
                case .composite(let layers):
                    presentationDescription = "composite(layers=\(layers.count))"
                }
                log(
                    "device.surface.submit",
                    "surface=\(update.surfaceID.rawValue) revision=\(update.revision.value) " +
                        "presentation=\(presentationDescription)"
                )
                try await session.submit(update)
            }
            let metrics = await session.currentMetrics()
            reportCount = metrics.writtenReports
            lastEvent = "Applied \(activeImportedProfileName ?? "profile") to the device"
            log("device.profile.apply", "Applied \(updates.count + 1) surfaces (8 keys plus composed touchscreen)")
        } catch {
            lastEvent = "Profile device update failed: \(error.localizedDescription)"
            log("device.profile.apply.error", "\(error)")
        }
    }

    private func startExternalPluginsForAssignments() {
        let pluginIDs = Set(assignments.values.map(\.pluginID))
        log(
            "plugin.runtime.plan",
            "Preparing \(pluginIDs.count) plugins assignments=\(assignments.count) basePort=\(pluginPortBase)"
        )
        for pluginID in pluginIDs {
            guard !startedPlugins.contains(pluginID) else { continue }
            startedPlugins.insert(pluginID)
            let package = plugins.first(where: { $0.id == pluginID })
            Task { [weak self] in
                guard let self else { return }
                let resolvedPackage = (package?.executablePath != nil ? package : nil)
                    ?? StreamDeckPluginImporter.installedPackage(withID: pluginID)
                guard let resolvedPackage, resolvedPackage.executablePath != nil else {
                    await MainActor.run {
                        self.log(
                            "plugin.runtime.unsupported",
                            "External runtime unavailable plugin=\(pluginID.rawValue) " +
                                "packageSource=\(package?.sourcePath ?? "none") " +
                                "searchedInstalledPackages=true"
                        )
                    }
                    return
                }
                let port = await MainActor.run { self.allocatePluginPort(for: pluginID) }
                await MainActor.run {
                    self.log(
                        "plugin.runtime.launch",
                        "plugin=\(pluginID.rawValue) port=\(port) executable=\(resolvedPackage.executablePath ?? "none") " +
                            "source=\(resolvedPackage.sourcePath ?? "none")"
                    )
                }
                do {
                    let deviceID = await MainActor.run {
                        self.selectedDeviceID
                            ?? self.devices.first?.id
                            ?? "decksmith-stream-deck-plus"
                    }
                    try await self.pluginRuntime.startExternal(
                        resolvedPackage,
                        port: port,
                        deviceID: deviceID
                    )
                    if let messages = await self.pluginRuntime.externalMessages(for: pluginID) {
                        self.pluginMessageTasks[pluginID] = Task { [weak self] in
                            for await message in messages {
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    self?.consumePluginMessage(message, pluginID: pluginID)
                                }
                            }
                        }
                    }
                    await MainActor.run {
                        self.log("plugin.runtime.start", "Started plugin=\(pluginID.rawValue) port=\(port)")
                    }
                    guard await self.pluginRuntime.waitForExternalConnection(pluginID) else {
                        if let diagnostics = await self.pluginRuntime.externalDiagnostics(for: pluginID) {
                            await MainActor.run {
                                self.log(
                                    "plugin.runtime.process",
                                    "plugin=\(pluginID.rawValue) port=\(port) pid=\(diagnostics.process.pid.map(String.init) ?? "none") " +
                                        "running=\(diagnostics.process.isRunning) websocket=\(diagnostics.websocketState) " +
                                        "connected=\(diagnostics.connected) args=\(diagnostics.process.arguments.joined(separator: " "))"
                                )
                            }
                        }
                        try? await self.pluginRuntime.stopExternal(pluginID)
                        await MainActor.run {
                            self.startedPlugins.remove(pluginID)
                            self.log(
                                "plugin.runtime.error",
                                "Plugin did not connect plugin=\(pluginID.rawValue) port=\(port) " +
                                    "executable=\(resolvedPackage.executablePath ?? "none")"
                            )
                        }
                        return
                    }
                    await MainActor.run {
                        self.log("plugin.runtime.connected", "plugin=\(pluginID.rawValue) port=\(port)")
                    }
                    let assignments = await MainActor.run {
                        self.assignments.values.filter { $0.pluginID == pluginID }
                    }
                    let connectedEnvelope = self.pluginDeviceConnectedEnvelope(deviceID: deviceID)
                    try await self.pluginRuntime.sendExternal(connectedEnvelope, to: pluginID)
                    await MainActor.run {
                        self.log(
                            "plugin.runtime.send",
                            "plugin=\(pluginID.rawValue) port=\(port) event=deviceDidConnect device=\(deviceID)"
                        )
                    }
                    for assignment in assignments {
                        let envelope = self.pluginEnvelope(for: assignment, event: "willAppear", extra: [:])
                        try await self.pluginRuntime.sendExternal(envelope, to: pluginID)
                        await MainActor.run {
                            self.log(
                                "plugin.runtime.send",
                                "plugin=\(pluginID.rawValue) port=\(port) event=willAppear context=\(assignment.id) action=\(assignment.actionID)"
                            )
                        }
                    }
                } catch {
                    try? await self.pluginRuntime.stopExternal(pluginID)
                    await MainActor.run {
                        self.startedPlugins.remove(pluginID)
                        self.log(
                            "plugin.runtime.error",
                            "Failed to start plugin=\(pluginID.rawValue) port=\(port): \(error)"
                        )
                    }
                }
            }
        }
    }

    private func pluginDeviceConnectedEnvelope(deviceID: String) -> OfficialPluginEnvelope {
        OfficialPluginEnvelope(
            event: "deviceDidConnect",
            context: deviceID,
            device: deviceID,
            deviceInfo: .object([
                "id": .string(deviceID),
                "name": .string("Stream Deck +"),
                "type": .number(7),
                "size": .object([
                    "columns": .number(4),
                    "rows": .number(2)
                ])
            ])
        )
    }

    private func allocatePluginPort(for pluginID: PluginID) -> UInt16 {
        if let port = pluginPorts[pluginID] { return port }
        let port = pluginPortBase + UInt16(pluginPorts.count)
        pluginPorts[pluginID] = port
        return port
    }

    private func dispatchPluginEvent(
        for assignment: PluginAssignment?,
        event: String,
        controlID: String,
        extra: [String: PluginJSONValue] = [:]
    ) {
        guard let assignment else {
            log("plugin.dispatch.skip", "No assignment for control=\(controlID) event=\(event)")
            return
        }
        let envelope = pluginEnvelope(for: assignment, event: event, extra: extra)
        log(
            "plugin.dispatch.attempt",
            "plugin=\(assignment.pluginID.rawValue) action=\(assignment.actionID) control=\(controlID) " +
                "event=\(event) device=\(selectedDeviceID ?? "none")"
        )
        Task {
            do {
                try await pluginRuntime.sendExternal(envelope, to: assignment.pluginID)
                log("plugin.dispatch", "plugin=\(assignment.pluginID.rawValue) action=\(assignment.actionID) control=\(controlID) event=\(event)")
            } catch {
                if case ExternalPluginProcessError.notRunning = error {
                    await MainActor.run {
                        self.startedPlugins.remove(assignment.pluginID)
                        self.log(
                            "plugin.runtime.retry",
                            "Restarting unavailable plugin=\(assignment.pluginID.rawValue) after event=\(event)"
                        )
                        self.startExternalPluginsForAssignments()
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    do {
                        try await pluginRuntime.sendExternal(envelope, to: assignment.pluginID)
                        await MainActor.run {
                            self.log(
                                "plugin.dispatch",
                                "plugin=\(assignment.pluginID.rawValue) action=\(assignment.actionID) " +
                                    "control=\(controlID) event=\(event) retry=true"
                            )
                        }
                        return
                    } catch {
                        // Preserve the detailed diagnostics below for the failed retry.
                    }
                }
                let diagnostics = await pluginRuntime.externalDiagnostics(for: assignment.pluginID)
                let processDetails = diagnostics.map {
                    "pid=\($0.process.pid.map(String.init) ?? "none") running=\($0.process.isRunning) " +
                        "status=\($0.process.terminationStatus.map(String.init) ?? "none") " +
                        "websocket=\($0.websocketState) connected=\($0.connected) " +
                        "stderr=\($0.process.standardError.replacingOccurrences(of: "\n", with: "\\n"))"
                } ?? "no-runtime-record"
                log(
                    "plugin.dispatch.error",
                    "plugin=\(assignment.pluginID.rawValue) control=\(controlID) event=\(event) " +
                        "port=\(pluginPorts[assignment.pluginID].map(String.init) ?? "none") error=\(error) \(processDetails)"
                )
            }
        }
    }

    private func consumePluginMessage(_ message: OfficialPluginEnvelope, pluginID: PluginID) {
            guard let context = message.context,
                  var assignment = assignments[context] else {
                log("plugin.message.skip", "plugin=\(pluginID.rawValue) event=\(message.event) context=\(message.context ?? "none")")
                return
            }

            switch message.event {
            case "setTitle":
                guard case let .string(title)? = message.payload["title"] else {
                    log("plugin.message.error", "plugin=\(pluginID.rawValue) setTitle missing title context=\(context)")
                    return
                }
                assignment = PluginAssignment(
                    surfaceID: assignment.id,
                    pluginID: assignment.pluginID,
                    actionID: assignment.actionID,
                    displayName: assignment.displayName,
                    settings: assignment.settings,
                    imagePath: assignment.imagePath,
                    stateTitle: title
                )
                assignments[context] = assignment
                persistAssignments()
                log("plugin.message.setTitle", "plugin=\(pluginID.rawValue) context=\(context) title=\(title)")
                pushAssignmentsToDevice()

            case "setImage":
                guard case let .string(encodedImage)? = message.payload["image"],
                      let imageURL = persistPluginImage(encodedImage, context: context, pluginID: pluginID) else {
                    log("plugin.message.error", "plugin=\(pluginID.rawValue) setImage missing or invalid image context=\(context)")
                    return
                }
                assignment = PluginAssignment(
                    surfaceID: assignment.id,
                    pluginID: assignment.pluginID,
                    actionID: assignment.actionID,
                    displayName: assignment.displayName,
                    settings: assignment.settings,
                    imagePath: imageURL,
                    stateTitle: assignment.stateTitle
                )
                assignments[context] = assignment
                persistAssignments()
                log("plugin.message.setImage", "plugin=\(pluginID.rawValue) context=\(context)")
                pushAssignmentsToDevice()

            case "setState":
                log("plugin.message.setState", "plugin=\(pluginID.rawValue) context=\(context) state=\(message.payload["state"] ?? .null)")
                if pluginID.rawValue == "com.eladavron.litra-glow-commander",
                   case let .number(rawState)? = message.payload["state"],
                   let stateIndex = Int(exactly: rawState),
                   let imagePath = StreamDeckPluginImporter.resolveInstalledPluginAsset(
                       pluginID: pluginID,
                       actionID: assignment.actionID,
                       stateIndex: stateIndex,
                       fileManager: .default
                   ) {
                    assignments[context] = PluginAssignment(
                        surfaceID: assignment.id,
                        pluginID: assignment.pluginID,
                        actionID: assignment.actionID,
                        displayName: assignment.displayName,
                        settings: assignment.settings,
                        imagePath: imagePath,
                        stateTitle: assignment.stateTitle
                    )
                    persistAssignments()
                    pushAssignmentsToDevice()
                }

            case "setFeedback":
                var feedback = pluginFeedback[context] ?? PluginFeedback(value: nil, indicator: nil, imagePath: nil)
                if case let .string(value)? = message.payload["value"] {
                    feedback.value = value
                } else if case let .object(value)? = message.payload["value"],
                          case let .string(valueText)? = value["value"] {
                    feedback.value = valueText
                }
                if case let .object(indicator)? = message.payload["indicator"],
                   case let .number(value)? = indicator["value"] {
                    feedback.indicator = value
                }
                if case let .string(icon)? = message.payload["icon"] {
                    feedback.imagePath = persistPluginImage(icon, context: context, pluginID: pluginID)
                }
                pluginFeedback[context] = feedback
                log("plugin.message.setFeedback", "plugin=\(pluginID.rawValue) context=\(context) value=\(feedback.value ?? "") indicator=\(feedback.indicator.map { String($0) } ?? "")")
                pushAssignmentsToDevice()

            case "decksmithError":
                log("plugin.message.error", "plugin=\(pluginID.rawValue) \(message.payload["message"] ?? .null)")

            default:
                log("plugin.message.unsupported", "plugin=\(pluginID.rawValue) event=\(message.event)")
            }
        }

    private func persistPluginImage(_ value: String, context: String, pluginID: PluginID) -> String? {
            let encoded = value.split(separator: ",", maxSplits: 1).last.map(String.init) ?? value
            guard let data = Data(base64Encoded: encoded) else { return nil }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Decksmith/ProfileAssets", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("runtime-\(context).png")
                let canvasSize = context.hasPrefix("key.")
                    ? PixelSize(width: 120, height: 120)
                    : PixelSize(width: 200, height: 100)
                try ImageAssetNormalizer.normalize(
                    data: data,
                    to: url,
                    canvasSize: canvasSize,
                    removingNeutralBackground: pluginID.rawValue == "com.elgato.volume-controller"
                )
                return url.path
            } catch {
                log("plugin.message.error", "Failed to persist image context=\(context): \(error.localizedDescription)")
                return nil
        }
    }

    private func pluginEnvelope(
        for assignment: PluginAssignment,
        event: String,
        extra: [String: PluginJSONValue]
    ) -> OfficialPluginEnvelope {
        var payload: [String: PluginJSONValue] = [
            "settings": pluginJSONValue(from: assignment.settings),
            "controller": .string(controllerName(for: assignment.id))
        ]
        payload.merge(extra) { _, new in new }
        return OfficialPluginEnvelope(
            event: event,
            context: assignment.id,
            device: selectedDeviceID ?? "",
            action: assignment.actionID,
            payload: payload
        )
    }

    private func controllerName(for surfaceID: String) -> String {
        switch controlKind(for: surfaceID) {
        case "encoder": return "Encoder"
        case "touch": return "Touchscreen"
        default: return "Keypad"
        }
    }

    private func pluginJSONValue(from data: Data) -> PluginJSONValue {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .object([:])
        }
        return pluginJSONValue(from: object)
    }

    private func pluginJSONValue(from object: Any) -> PluginJSONValue {
        switch object {
        case let value as String: return .string(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as [String: Any]:
            return .object(value.mapValues { pluginJSONValue(from: $0) })
        case let value as [Any]:
            return .array(value.map { pluginJSONValue(from: $0) })
        default:
            return .null
        }
    }

    private func renderSurfacePreview(for surfaceID: String) {
        refreshRenderedPreviews()
        guard let session else { return }
        revision &+= 1
        let update = SurfaceUpdate(
            surfaceID: SurfaceID(rawValue: surfaceID),
            revision: SurfaceRevision(revision),
            presentation: devicePresentation(for: surfaceID)
        )
        Task {
            do {
                try await session.submit(update)
            } catch {
                log("device.surface.error", "Failed to update \(surfaceID): \(error)")
            }

        }
    }

    func refreshRenderedPreviews() {
        let surfaceIDs = (0..<8).map { "key.\($0)" } + ["touch.0"]
        let renderer = RasterSurfaceRenderer()
        for surfaceID in surfaceIDs {
            revision &+= 1
            let update = SurfaceUpdate(
                surfaceID: SurfaceID(rawValue: surfaceID),
                revision: SurfaceRevision(revision),
                presentation: devicePresentation(for: surfaceID)
            )
            Task { [weak self] in
                do {
                    let rendered = try await renderer.render(update)
                    await MainActor.run {
                        guard let self, let image = NSImage(data: rendered.pixels) else { return }
                        self.renderedPreviewImages[surfaceID] = image
                    }
                } catch {
                    await MainActor.run {
                        self?.log("ui.preview.error", "surface=\(surfaceID) error=\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func devicePresentation(for surfaceID: String) -> SurfacePresentation {
        if surfaceID == "touch.0" {
            return touchscreenPresentation()
        }
        guard let assignment = assignments[surfaceID] else { return .blank }
        return presentation(for: assignment, surfaceID: surfaceID)
    }

    private func touchscreenPresentation() -> SurfacePresentation {
        let touchscreenLayers = ((0..<4).map { index -> [RenderLayer] in
            let surfaceID = "encoder.\(index)"
            let x = Double(index * 200)
            guard let assignment = assignments[surfaceID] else { return [] }
            let feedback = pluginFeedback[surfaceID]
            var layers: [RenderLayer] = []
            if let imagePath = feedback?.imagePath ?? assignment.imagePath {
                layers.append(.image(assetID: imagePath, x: x + 12, y: 28, width: 52, height: 52))
            }
            if let title = displayTitle(for: assignment) {
                layers.append(.text(value: title, x: x + 72, y: 66, width: 116, height: 18))
            }
            if let percentage = percentage(for: assignment, feedback: feedback) {
                layers.append(.text(value: "\(Int((percentage * 100).rounded()))%", x: x + 72, y: 40, width: 116, height: 20))
                if supportsProgressBar(assignment) {
                    layers.append(.progress(value: percentage, x: x + 72, y: 88, width: 116, height: 8))
                }
            }
            return layers
        } + (0..<4).map { index -> [RenderLayer] in
            let surfaceID = "touch.\(index)"
            guard let assignment = assignments[surfaceID] else { return [] }
            let x = Double(index * 200)
            var layers: [RenderLayer] = []
            if let imagePath = assignment.imagePath {
                layers.append(.image(assetID: imagePath, x: x + 12, y: 28, width: 52, height: 52))
            }
            if let title = displayTitle(for: assignment) {
                layers.append(.text(value: title, x: x + 72, y: 66, width: 116, height: 18))
            }
            return layers
        }).flatMap { $0 }
        return .composite(layers: touchscreenLayers)
    }

    private func presentation(for assignment: PluginAssignment, surfaceID: String) -> SurfacePresentation {
        guard let imagePath = assignment.imagePath else {
            if let title = displayTitle(for: assignment) {
                return .text(title: title, subtitle: nil)
            }
            return .blank
        }
        var layers: [RenderLayer] = [
            .image(assetID: imagePath, x: 0, y: 0, width: 120, height: 120)
        ]
        if let title = displayTitle(for: assignment) {
            layers.append(.text(value: title, x: 8, y: 94, width: 104, height: 20))
        }
        return .composite(layers: layers)
    }

    private func displayTitle(for assignment: PluginAssignment) -> String? {
        let title = assignment.stateTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty == false { return title }
        if let configured = configuredLabel(for: assignment) {
            return configured
        }
        switch assignment.pluginID.rawValue {
        case "com.eladavron.litra-glow-commander":
            return "Litra Glow"
        case "com.elgato.streamdeck.profile.rotate":
            return "Profile"
        default:
            return nil
        }
    }

    private func supportsProgressBar(_ assignment: PluginAssignment) -> Bool {
        assignment.pluginID.rawValue == "com.elgato.volume-controller"
    }

    private func percentage(
        for assignment: PluginAssignment,
        feedback: PluginFeedback?
    ) -> Double? {
        if let indicator = feedback?.indicator {
            return min(max(indicator / 100, 0), 1)
        }
        if let value = feedback?.value,
           let number = Double(value.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
            return min(max(number / 100, 0), 1)
        }
        guard let object = try? JSONSerialization.jsonObject(with: assignment.settings) as? [String: Any],
              let volume = object["volume"] as? String ?? (object["volume"] as? NSNumber)?.stringValue,
              let number = Double(volume) else {
            return nil
        }
        return min(max(number / 100, 0), 1)
    }

    private func configuredLabel(for assignment: PluginAssignment) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: assignment.settings) as? [String: Any] else {
            return nil
        }
        for key in ["friendlyName", "deviceLabel", "primaryLabel", "secondaryLabel", "displayName", "title"] {
            if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private func controlKind(for surfaceID: String) -> String {
        if surfaceID.hasPrefix("encoder.") { return "encoder" }
        if surfaceID.hasPrefix("touch.") { return "touch" }
        return "key"
    }

    private func persistAssignments() {
        let snapshot = assignments
        Task {
            do {
                try await assignmentStore.save(snapshot, kind: "pluginAssignments", schemaVersion: 1)
            } catch {
                log("persistence.error", "Failed to save assignments: \(error.localizedDescription)")
            }
        }
    }

    private func loadAssignments() {
        Task {
            do {
                guard let envelope = try await assignmentStore.load() else { return }
                let shouldPersist = await MainActor.run {
                    guard self.assignments.isEmpty else { return false }
                    let normalized = self.normalizeLoadedAssignments(envelope.value)
                    self.assignments = normalized
                    self.syncCurrentPageFromAssignments()
                    self.lastEvent = "Loaded \(envelope.value.count) saved assignments"
                    return normalized != envelope.value
                }
                if shouldPersist {
                    persistAssignments()
                }
            } catch {
                log("persistence.error", "Failed to load assignments: \(error.localizedDescription)")
            }
        }
    }

    private func normalizeLoadedAssignments(
        _ loaded: [String: PluginAssignment]
    ) -> [String: PluginAssignment] {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Decksmith/ProfileAssets", isDirectory: true)
        var normalized = loaded
        for (surfaceID, assignment) in loaded {
            let shouldRefreshInstalledAsset = [
                "com.eladavron.litra-glow-commander",
                "com.elgato.streamdeck.profile.rotate"
            ].contains(assignment.pluginID.rawValue)
            if (assignment.imagePath == nil || shouldRefreshInstalledAsset),
               let resolved = StreamDeckPluginImporter.resolveInstalledPluginAsset(
                   pluginID: assignment.pluginID,
                   actionID: assignment.actionID,
                   stateIndex: 0,
                   fileManager: .default
               ) {
                normalized[surfaceID] = PluginAssignment(
                    surfaceID: assignment.id,
                    pluginID: assignment.pluginID,
                    actionID: assignment.actionID,
                    displayName: assignment.displayName,
                    settings: assignment.settings,
                    imagePath: resolved,
                    stateTitle: assignment.stateTitle
                )
                log("plugin.image.resolve", "Resolved installed asset surface=\(surfaceID)")
                continue
            }
            guard let imagePath = assignment.imagePath else { continue }
            let source = URL(fileURLWithPath: imagePath)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let canvasSize = surfaceID.hasPrefix("key.")
                ? PixelSize(width: 120, height: 120)
                : PixelSize(width: 200, height: 100)
            let destination = directory.appendingPathComponent("runtime-\(surfaceID).png")
            do {
                try ImageAssetNormalizer.normalize(
                    data: Data(contentsOf: source),
                    to: destination,
                    canvasSize: canvasSize
                )
                normalized[surfaceID] = PluginAssignment(
                    surfaceID: assignment.id,
                    pluginID: assignment.pluginID,
                    actionID: assignment.actionID,
                    displayName: assignment.displayName,
                    settings: assignment.settings,
                    imagePath: destination.path,
                    stateTitle: assignment.stateTitle
                )
                log("plugin.image.normalize", "Normalized persisted image surface=\(surfaceID)")
            } catch {
                log("plugin.image.normalize.error", "surface=\(surfaceID) error=\(error.localizedDescription)")
            }
        }
        return normalized
    }
}

extension DecksmithAppModel {
   var currentProfile: DecksmithEditorProfile? {
       editorProfiles.first { $0.id == selectedProfileID } ?? editorProfiles.first
   }

   var currentPage: DecksmithEditorPage? {
       currentProfile?.pages.first { $0.id == selectedPageID }
           ?? currentProfile?.pages[safe: activePage]
           ?? currentProfile?.pages.first
   }

   var currentPageAssignments: [String: PluginAssignment] {
       currentPage?.assignments ?? [:]
   }

   func loadEditorWorkspace() {
       Task {
           let loaded = try? await workspaceStore.load()?.value
           await MainActor.run {
               let workspace = loaded ?? DecksmithEditorWorkspace.initial
               self.editorProfiles = workspace.profiles.isEmpty ? DecksmithEditorWorkspace.initial.profiles : workspace.profiles
               self.selectedProfileID = workspace.selectedProfileID ?? self.editorProfiles.first?.id
               self.selectedPageID = workspace.selectedPageID
               self.normalizeEditorSelection()
               self.syncAssignmentsFromCurrentPage()
           }
       }
   }

   func persistEditorWorkspace() {
       let workspace = DecksmithEditorWorkspace(
           profiles: editorProfiles,
           selectedProfileID: selectedProfileID,
           selectedPageID: selectedPageID
       )
       Task {
           do {
               try await workspaceStore.save(
                   workspace,
                   kind: DecksmithWorkspaceCodec.kind,
                   schemaVersion: DecksmithEditorWorkspace.schemaVersion
               )
           } catch {
               await MainActor.run {
                   self.lastEvent = "Workspace save failed: \(error.localizedDescription)"
                   self.log("workspace.save.error", "\(error)")
               }
           }
       }
   }

   private func normalizeEditorSelection() {
       guard !editorProfiles.isEmpty else { return }
       if selectedProfileID == nil || !editorProfiles.contains(where: { $0.id == selectedProfileID }) {
           selectedProfileID = editorProfiles[0].id
       }
       guard let profile = currentProfile, !profile.pages.isEmpty else {
           selectedPageID = nil
           activePage = 0
           return
       }
       if let pageIndex = profile.pages.firstIndex(where: { $0.id == selectedPageID }) {
           activePage = pageIndex
       } else {
           activePage = min(activePage, profile.pages.count - 1)
           selectedPageID = profile.pages[activePage].id
       }
   }

   func selectProfile(_ profileID: String) {
       guard editorProfiles.contains(where: { $0.id == profileID }) else { return }
       selectedProfileID = profileID
       activePage = 0
       selectedPageID = currentProfile?.pages.first?.id
       syncAssignmentsFromCurrentPage()
       persistEditorWorkspace()
       pushAssignmentsToDevice()
   }

   func addProfile() {
       let profile = DecksmithEditorProfile(name: "Profile \(editorProfiles.count + 1)", pages: [DecksmithEditorPage(name: "Main")])
       editorProfiles.append(profile)
       selectedProfileID = profile.id
       selectedPageID = profile.pages[0].id
       activePage = 0
       assignments.removeAll()
       persistEditorWorkspace()
   }

   func removeSelectedProfile() {
       guard editorProfiles.count > 1, let selectedProfileID else { return }
       editorProfiles.removeAll { $0.id == selectedProfileID }
       self.selectedProfileID = editorProfiles.first?.id
       activePage = 0
       selectedPageID = editorProfiles.first?.pages.first?.id
       syncAssignmentsFromCurrentPage()
       persistEditorWorkspace()
       pushAssignmentsToDevice()
   }

   func selectPage(_ index: Int) {
       guard let profile = currentProfile, profile.pages.indices.contains(index) else { return }
       activePage = index
       selectedPageID = profile.pages[index].id
       syncAssignmentsFromCurrentPage()
       persistEditorWorkspace()
       pushAssignmentsToDevice()
   }

   func addPage() {
       guard let profileIndex = editorProfiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
       let page = DecksmithEditorPage(name: "Page \(editorProfiles[profileIndex].pages.count + 1)")
       editorProfiles[profileIndex].pages.append(page)
       activePage = editorProfiles[profileIndex].pages.count - 1
       selectedPageID = page.id
       assignments.removeAll()
       persistEditorWorkspace()
   }

   func removeActivePage() {
       guard let profileIndex = editorProfiles.firstIndex(where: { $0.id == selectedProfileID }),
             editorProfiles[profileIndex].pages.count > 1 else { return }
       editorProfiles[profileIndex].pages.remove(at: activePage)
       activePage = min(activePage, editorProfiles[profileIndex].pages.count - 1)
       selectedPageID = editorProfiles[profileIndex].pages[activePage].id
       syncAssignmentsFromCurrentPage()
       persistEditorWorkspace()
       pushAssignmentsToDevice()
   }

   private func syncAssignmentsFromCurrentPage() {
       assignments = currentPageAssignments
       selectedPluginID = plugins.first?.id
       selectedActionID = availableActions.first?.id
       refreshRenderedPreviews()
   }

   private func syncCurrentPageFromAssignments() {
       guard let profileIndex = editorProfiles.firstIndex(where: { $0.id == selectedProfileID }),
             let pageIndex = editorProfiles[profileIndex].pages.firstIndex(where: { $0.id == selectedPageID }) else { return }
       editorProfiles[profileIndex].pages[pageIndex].assignments = assignments
       persistEditorWorkspace()
   }
}

private struct LegacyContentView: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Header(model: model)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        DeviceOverview(model: model)
                        DevicePreview(model: model)
                        PluginPanel(model: model)
                        Inspector(model: model)
                    }
                    .padding(28)
                    .frame(maxWidth: 980, alignment: .leading)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 980, minHeight: 700)
    }
}

private struct Sidebar: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        List {
            Section("Workspace") {
                Label("Devices", systemImage: "rectangle.connected.to.line.below")
                Label("Surfaces", systemImage: "square.grid.3x3")
                Label("Bindings", systemImage: "link")
            }
            Section("Runtime") {
                Label("Plugins", systemImage: "puzzlepiece.extension")
                Label("Diagnostics", systemImage: "waveform.path.ecg")
                Label("Event history", systemImage: "list.bullet.rectangle")
            }
            Section("Pages") {
                ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
                    Button {
                        model.activePage = index
                    } label: {
                        Label(page, systemImage: index == model.activePage ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Decksmith")
    }
}

private struct Header: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Surface workspace")
                    .font(.title2.weight(.semibold))
                Text(model.pages[model.activePage])
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.connected ? "Connected" : "Disconnected", systemImage: model.connected ? "checkmark.circle.fill" : "circle.slash")
                .foregroundStyle(model.connected ? .green : .secondary)
            Button("Disconnect", action: model.disconnect)
                .disabled(!model.connected)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }
}

private struct DeviceOverview: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        HStack(spacing: 16) {
            Stat(label: "Device", value: "Stream Deck +")
            Stat(label: "Transport", value: model.connected ? "Open" : "Closed")
            Stat(label: "Events", value: "\(model.eventCount)")
            Stat(label: "Reports", value: "\(model.reportCount)")
            Spacer()
        }
        HStack(spacing: 10) {
            Picker("Physical device", selection: $model.selectedDeviceID) {
                Text("Select a Stream Deck").tag(String?.none)
                ForEach(model.devices) { device in
                    Text("\(device.name) (\(String(format: "%04X:%04X", device.vendorID, device.productID)))")
                        .tag(Optional(device.id))
                }
            }
            .frame(maxWidth: 420)
            Button("Refresh", action: model.refreshDevices)
            Button("Connect", action: model.connectSelectedDevice)
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedDeviceID == nil)
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(width: 130, alignment: .leading)
    }
}

private struct DevicePreview: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stream Deck+ layout")
                    .font(.headline)
                Spacer()
                Text(model.selectedSurfaceID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { index in
                        Button {
                            model.selectTouchSegment(index)
                        } label: {
                            VStack(spacing: 4) {
                                Text("Touch \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                Text(model.assignedActionFor("touch.\(index)") ?? "Display")
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(model.selectedSurfaceID == "touch.\(index)" ? Color.accentColor.opacity(0.22) : Color.black.opacity(0.25))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { index in
                        Button {
                            model.selectEncoder(index)
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .strokeBorder(model.selectedSurfaceID == "encoder.\(index)" ? Color.accentColor : Color.white.opacity(0.35), lineWidth: 3)
                                    .background(Circle().fill(Color.black.opacity(0.35)))
                                    .overlay {
                                        Text("\(index + 1)")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 42, height: 42)
                                Text(model.assignedActionFor("encoder.\(index)") ?? "Unassigned")
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 74)
                        }
                        .buttonStyle(.plain)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(0..<8, id: \.self) { index in
                        Button {
                            model.selectControl(index)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: model.selectedSurfaceID == "key.\(index)" ? "square.fill" : "square")
                                Text("Key \(index + 1)")
                                    .font(.caption.weight(.medium))
                                Text(model.assignedActionFor("key.\(index)") ?? "Unassigned")
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .background(model.selectedSurfaceID == "key.\(index)" ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.selectedSurfaceID == "key.\(index)" ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: model.selectedSurfaceID == "key.\(index)" ? 2 : 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct PluginPanel: View {
    @ObservedObject var model: DecksmithAppModel
    @State private var showImporter = false
    @State private var configurationText = "{}"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plugins")
                    .font(.headline)
                Spacer()
                Button("Import installed plugin or profile") {
                    showImporter = true
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
                    if case let .success(url) = result {
                        model.importPlugin(from: url)
                    } else if case let .failure(error) = result {
                        model.reportImportFailure(error)
                    }
                }
            }
            Text(model.lastEvent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !model.importedProfiles.isEmpty {
                Text("Imported profiles")
                    .font(.subheadline.weight(.semibold))
                ForEach(model.importedProfileNames, id: \.self) { profileName in
                    HStack {
                        Label(
                            profileName,
                            systemImage: (model.activeImportedProfileName ?? "") == profileName ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.caption)
                        Spacer()
                        Text("\(model.importedProfiles.filter { $0.name == profileName }.reduce(0) { $0 + $1.assignments.count }) assignments")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("Apply") {
                            model.applyImportedProfile(named: profileName)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            if model.plugins.isEmpty {
                Text("No Stream Deck plugins found. Install the plugin in Stream Deck, then refresh or import its .sdPlugin folder or .streamDeckProfile.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Picker("Installed plugin", selection: $model.selectedPluginID) {
                        ForEach(model.plugins) { plugin in
                            Text(plugin.manifest.name).tag(Optional(plugin.id))
                        }
                    }
                    .onChange(of: model.selectedPluginID) { _, _ in
                        model.selectedPluginChanged()
                    }
                    .frame(maxWidth: 250)
                    if model.selectedPlugin != nil {
                        Text("\(model.availableActions.count) compatible actions")
                            .foregroundStyle(.secondary)
                    }
                }
                if model.selectedPlugin != nil {
                    if model.availableActions.isEmpty {
                        Text("No \(model.controlKindLabel) actions are available for \(model.surfaceLabel(model.selectedSurfaceID)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Action for \(model.surfaceLabel(model.selectedSurfaceID))", selection: $model.selectedActionID) {
                            ForEach(model.availableActions) { action in
                                Text(action.name).tag(Optional(action.id))
                            }
                        }
                        Text(model.selectedAction?.summary ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Assign to \(model.selectedSurfaceID)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Assign") {
                            model.assignSelectedAction()
                        }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            Divider()
            Text("Control mappings")
                .font(.subheadline.weight(.semibold))
            Text("Choose a plugin action above, then assign it to any key, encoder, or touchscreen segment.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.configurableSurfaces, id: \.self) { surfaceID in
                HStack(spacing: 10) {
                    Button {
                        model.selectSurface(surfaceID)
                    } label: {
                        Text(model.surfaceLabel(surfaceID))
                            .frame(width: 82, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.selectedSurfaceID == surfaceID ? Color.accentColor : .primary)
                    Text(model.assignedActionFor(surfaceID) ?? "Unassigned")
                        .font(.caption)
                        .foregroundStyle(model.assignedActionFor(surfaceID) == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Button("Assign") {
                        model.assignSelectedAction(to: surfaceID)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.selectedPlugin == nil || model.selectedAction == nil)
                    if model.assignedActionFor(surfaceID) != nil {
                        Button("Clear") {
                            model.clearAssignment(for: surfaceID)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if model.assignedActionFor(model.selectedSurfaceID) != nil {
                Divider()
                Text("Configure \(model.surfaceLabel(model.selectedSurfaceID))")
                    .font(.subheadline.weight(.semibold))
                Text("Plugin settings are passed through unchanged. Use the plugin's setting keys and values; `{}` means default settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $configurationText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 90)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                Button("Save configuration") {
                    model.saveConfiguration(configurationText, for: model.selectedSurfaceID)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            configurationText = model.configurationText(for: model.selectedSurfaceID)
        }
        .onChange(of: model.selectedSurfaceID) { _, surfaceID in
            configurationText = model.configurationText(for: surfaceID)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct Inspector: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Selected surface")
                    .font(.headline)
                Spacer()
                Text("key.\(model.selectedControl)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [.indigo, .purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.largeTitle)
                                Text("Key \(model.selectedControl + 1)")
                                    .font(.headline)
                                Text(model.pages[model.activePage])
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .foregroundStyle(.white)
                        }
                        .frame(width: 180, height: 180)
                    Text(model.lastEvent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Surface output")
                        .font(.subheadline.weight(.semibold))
                    Button("Render selected surface", action: model.renderSelectedSurface)
                        .buttonStyle(.borderedProminent)
                    HStack {
                        Text("Brightness")
                        Slider(value: $model.brightness, in: 0...100, step: 1)
                        Text("\(Int(model.brightness))%")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                    Button("Send brightness", action: model.setBrightness)
                        .buttonStyle(.bordered)
                    Text("Diagnostics: \(model.diagnosticLogPath)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
