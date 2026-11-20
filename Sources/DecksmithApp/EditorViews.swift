import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DecksmithPluginSwift
import DecksmithCore

struct ContentView: View {
    @ObservedObject var model: DecksmithAppModel
    @State private var showBrowser = true

    var body: some View {
        NavigationSplitView {
            ProfileSidebar(model: model)
        } detail: {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        EditorHeader(model: model, showBrowser: $showBrowser)
                        PageTabs(model: model)
                        HardwareEditorPreview(model: model)
                        AssignmentEditor(model: model)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showBrowser {
                    Divider()
                    PluginActionBrowser(model: model, showBrowser: $showBrowser)
                        .frame(width: 320)
                } else {
                    RightSidebarRail(showBrowser: $showBrowser)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1180, minHeight: 760)
    }
}

private struct RightSidebarRail: View {
    @Binding var showBrowser: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                showBrowser = true
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .help("Show actions sidebar")
            Spacer()
        }
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(width: 40)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ProfileSidebar: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        List(selection: $model.selectedProfileID) {
            Section {
                ForEach(model.editorProfiles) { profile in
                    let isSelected = profile.id == model.selectedProfileID
                    let iconName = isSelected ? "person.crop.rectangle.fill" : "person.crop.rectangle"
                    HStack(spacing: 8) {
                        Image(systemName: iconName)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(profile.name)
                        Spacer()
                        Text("\(profile.pages.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(profile.id))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectProfile(profile.id) }
                }
            } header: {
                HStack {
                    Text("Profiles")
                    Spacer()
                    HStack(spacing: 4) {
                        Button { model.addProfile() } label: {
                            Image(systemName: "plus")
                        }
                        Button { model.removeSelectedProfile() } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(model.editorProfiles.count <= 1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Section("Workspace") {
                Label("Devices", systemImage: "rectangle.connected.to.line.below")
                Label("Diagnostics", systemImage: "waveform.path.ecg")
                Label("Event history", systemImage: "list.bullet.rectangle")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Decksmith")
        .onChange(of: model.selectedProfileID) { _, value in
            if let value { model.selectProfile(value) }
        }
    }
}

private struct EditorHeader: View {
    @ObservedObject var model: DecksmithAppModel
    @Binding var showBrowser: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.currentProfile?.name ?? "Profile")
                    .font(.title2.weight(.semibold))
                Text(model.currentProfile?.deviceModel ?? "Stream Deck+")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.connected ? "Connected" : "Disconnected", systemImage: model.connected ? "checkmark.circle.fill" : "circle.slash")
                .foregroundStyle(model.connected ? .green : .secondary)
            Button {
                showBrowser.toggle()
            } label: {
                Label("Actions", systemImage: "sidebar.right")
            }
            .buttonStyle(.bordered)
            Button("Disconnect", action: model.disconnect)
                .disabled(!model.connected)
        }
    }
}

private struct PageTabs: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
                    Button {
                        model.selectPage(index)
                    } label: {
                        Text(page)
                            .font(.subheadline.weight(index == model.activePage ? .semibold : .regular))
                            .foregroundStyle(index == model.activePage ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(index == model.activePage ? Color.accentColor.opacity(0.18) : .clear)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button { model.addPage() } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 34, minHeight: 34)
                }
                .buttonStyle(.bordered)
                if model.pages.count > 1 {
                    Button { model.removeActivePage() } label: {
                        Image(systemName: "minus")
                            .frame(minWidth: 34, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(Capsule())
            Spacer()
            Text(model.lastEvent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct HardwareEditorPreview: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stream Deck+")
                    .font(.headline)
                Spacer()
                Text(model.selectedSurfaceID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(0..<8, id: \.self) { index in
                        EditorSurfaceTile(model: model, surfaceID: "key.\(index)", label: "Key \(index + 1)")
                    }
                }
                EditorTouchscreen(model: model)
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { index in
                        EditorDialTile(model: model, index: index)
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct EditorTouchscreen: View {
    @ObservedObject var model: DecksmithAppModel

    var body: some View {
        Button {
            model.selectTouchSegment(0)
        } label: {
            Group {
                if let image = model.renderedPreviewImages["touch.0"] {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(8 / 1, contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .aspectRatio(8 / 1, contentMode: .fit)
                        .overlay(Text("Touchscreen preview").foregroundStyle(.secondary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(model.selectedSurfaceID == "touch.0" ? Color.accentColor : Color.white.opacity(0.12), lineWidth: model.selectedSurfaceID == "touch.0" ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct EditorDialTile: View {
    @ObservedObject var model: DecksmithAppModel
    let index: Int

    var body: some View {
        let surfaceID = "encoder.\(index)"
        Button {
            model.selectEncoder(index)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black)
                if let assignment = model.assignment(for: surfaceID),
                   let imagePath = assignment.imagePath,
                   let image = NSImage(contentsOfFile: imagePath) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                } else {
                    Image(systemName: model.assignment(for: surfaceID) == nil ? "dial.medium" : "square.grid.2x2")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                Circle()
                    .stroke(model.selectedSurfaceID == surfaceID ? Color.accentColor : Color.white.opacity(0.16), lineWidth: model.selectedSurfaceID == surfaceID ? 2 : 1)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
    }
}

private struct EditorSurfaceTile: View {
    @ObservedObject var model: DecksmithAppModel
    let surfaceID: String
    let label: String
    var isDial = false

    private var assignment: PluginAssignment? { model.assignment(for: surfaceID) }

    var body: some View {
        Button {
            model.selectSurface(surfaceID)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: isDial ? 14 : 8)
                    .fill(Color.black.opacity(assignment == nil ? 0.22 : 0.5))
                if let path = assignment?.imagePath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(isDial ? 8 : 3)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: assignment == nil ? "rectangle.dashed" : (isDial ? "dial.medium" : "square.grid.2x2"))
                            .font(isDial ? .title2 : .headline)
                        Text(assignment?.stateTitle ?? assignment?.displayName ?? label)
                            .font(.caption2.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(assignment == nil ? .secondary : .primary)
                    .padding(4)
                }
                RoundedRectangle(cornerRadius: isDial ? 14 : 8)
                    .stroke(model.selectedSurfaceID == surfaceID ? Color.accentColor : Color.white.opacity(0.12), lineWidth: model.selectedSurfaceID == surfaceID ? 2 : 1)
            }
            .aspectRatio(isDial ? 1 : 1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let object = object as? NSString else { return }
                let payload = object as String
                guard let separator = payload.firstIndex(of: "|") else { return }
                let pluginID = PluginID(rawValue: String(payload[..<separator]))
                let actionID = String(payload[payload.index(after: separator)...])
                DispatchQueue.main.async {
                    model.assign(pluginID: pluginID, actionID: actionID, to: surfaceID)
                }
            }
            return true
        }
    }
}

private struct AssignmentEditor: View {
    @ObservedObject var model: DecksmithAppModel
    @State private var configurationText = "{}"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Assignment")
                    .font(.headline)
                Spacer()
                Text(model.surfaceLabel(model.selectedSurfaceID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let assignment = model.assignment(for: model.selectedSurfaceID) {
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(assignment.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("\(assignment.pluginID.rawValue) / \(assignment.actionID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear") { model.clearAssignment(for: model.selectedSurfaceID) }
                        .buttonStyle(.borderless)
                }
                TextEditor(text: $configurationText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 90)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                HStack {
                    Text("Plugin settings are passed through as JSON.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") {
                        model.saveConfiguration(configurationText, for: model.selectedSurfaceID)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Drop a compatible action here, or choose one from the action browser.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { configurationText = model.configurationText(for: model.selectedSurfaceID) }
        .onChange(of: model.selectedSurfaceID) { _, surfaceID in
            configurationText = model.configurationText(for: surfaceID)
        }
    }
}

private struct PluginActionBrowser: View {
    @ObservedObject var model: DecksmithAppModel
    @Binding var showBrowser: Bool
    @State private var query = ""
    @State private var tab = "Keys"
    @State private var expanded: Set<PluginID> = []

    private var control: String {
        tab == "Dials" ? "encoder" : "key"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installed actions")
                    .font(.headline)
                Spacer()
                Button {
                    showBrowser = false
                } label: {
                    Image(systemName: "sidebar.right")
                        .frame(minWidth: 30, minHeight: 30)
                }
                .buttonStyle(.borderless)
                .help("Hide actions sidebar")
            }
            TextField("Search actions", text: $query)
                .textFieldStyle(.roundedBorder)
            Picker("Action type", selection: $tab) {
                Text("Keys").tag("Keys")
                Text("Dials").tag("Dials")
                Text("Plugins").tag("Plugins")
            }
            .pickerStyle(.segmented)
            if tab == "Plugins" {
                ContentUnavailableView("Plugin tools", systemImage: "puzzlepiece.extension", description: Text("Plugin management will appear here."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.locallyInstalledPlugins) { plugin in
                            let actions = model.compatibleActions(for: plugin, surfaceID: control == "encoder" ? "encoder.0" : "key.0")
                                .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || plugin.manifest.name.localizedCaseInsensitiveContains(query) }
                            if !actions.isEmpty {
                                DisclosureGroup(isExpanded: Binding(
                                    get: { expanded.contains(plugin.id) },
                                    set: { isExpanded in
                                        if isExpanded { expanded.insert(plugin.id) } else { expanded.remove(plugin.id) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(actions) { action in
                                            ActionRow(plugin: plugin, action: action)
                                        }
                                    }
                                    .padding(.leading, 8)
                                } label: {
                                    Label(plugin.manifest.name, systemImage: "puzzlepiece.extension")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle("Actions")
    }
}

private struct ActionRow: View {
    let plugin: PluginPackage
    let action: PluginActionDefinition

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                    .font(.caption.weight(.medium))
                Text(action.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: "\(plugin.id.rawValue)|\(action.id)" as NSString)
        }
    }
}

struct DecksmithCommands: Commands {
    @ObservedObject var model: DecksmithAppModel

    var body: some Commands {
        CommandMenu("Profiles") {
            Button("Import Decksmith Backup…", action: model.importDecksmithBackupFromPanel)
            Button("Export Decksmith Backup…", action: model.exportDecksmithBackupFromPanel)
            Divider()
            Button("Import Stream Deck Profile or Backup…", action: model.importVendorProfileFromPanel)
            Button("Export Native Stream Deck Profile…", action: model.exportVendorProfileFromPanel)
            Button("Export Native Stream Deck Backup…", action: model.exportVendorBackupFromPanel)
        }
    }
}
