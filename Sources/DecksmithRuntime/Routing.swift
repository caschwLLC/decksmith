import Foundation
import DecksmithCore

public actor PageRouter {
    private var pages: [PageID: PageDefinition] = [:]
    private var order: [PageID] = []
    private var currentPageID: PageID?

    public init(pages: [PageDefinition] = []) {
        for page in pages {
            self.pages[page.id] = page
            order.append(page.id)
        }
        currentPageID = order.first
    }

    public func replacePages(_ pages: [PageDefinition]) {
        self.pages = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        order = pages.map(\.id)
        currentPageID = order.first
    }

    public func currentPage() -> PageDefinition? {
        guard let currentPageID else { return nil }
        return pages[currentPageID]
    }

    public func navigate(_ command: NavigationCommand) -> PageDefinition? {
        guard !order.isEmpty else { return nil }
        switch command {
        case .select(let pageID):
            currentPageID = pages[pageID] == nil ? currentPageID : pageID
        case .next:
            guard let currentPageID, let index = order.firstIndex(of: currentPageID) else { return currentPage() }
            self.currentPageID = order[(index + 1) % order.count]
        case .previous:
            guard let currentPageID, let index = order.firstIndex(of: currentPageID) else { return currentPage() }
            self.currentPageID = order[(index + order.count - 1) % order.count]
        }
        return currentPage()
    }

    public func route(_ event: InputEvent) -> ActionInstanceID? {
        guard let page = currentPage() else { return nil }
        return page.bindings.first { binding in
            switch (binding.value.trigger, event) {
            case let (.key(controlID), .key(eventID, _, _)): return controlID == eventID
            case let (.encoderRotation(controlID), .encoderRotation(eventID, _, _)): return controlID == eventID
            case let (.encoderPress(controlID), .encoderPress(eventID, _, _)): return controlID == eventID
            case let (.touch(surfaceID), .touch(eventID, _, _, _)): return surfaceID == eventID
            default: return false
            }
        }?.value.actionInstanceID
    }
}

public actor IntegrationRegistry {
    private var integrations: [PluginID: IntegrationDescriptor] = [:]

    public init() {}

    public func register(_ descriptor: IntegrationDescriptor) {
        integrations[descriptor.id] = descriptor
    }

    public func remove(_ id: PluginID) {
        integrations.removeValue(forKey: id)
    }

    public func snapshot() -> [IntegrationDescriptor] {
        integrations.values.sorted { $0.name < $1.name }
    }
}
