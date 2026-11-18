import SwiftUI

@main
struct DecksmithApp: App {
    var body: some Scene {
        WindowGroup("Decksmith") {
            ContentView()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Decksmith").font(.largeTitle)
            Text("Native Stream Deck architecture shell")
                .foregroundStyle(.secondary)
            Label("Hardware session backend is modular and ready for device integration.", systemImage: "rectangle.connected.to.line.below")
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 220)
    }
}
