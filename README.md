# Decksmith

Decksmith is a native macOS Swift/SwiftUI Stream Deck client. It is designed to own direct HID communication while supporting official Node.js Stream Deck plugins and richer Swift-native integrations.

## Status

This repository begins with the production architecture shell: stable domain identifiers, versioned protocol boundaries, actor-isolated transport/session abstractions, rendering and plugin boundaries, persistence/observability placeholders, tests, and an Xcode app project.

The root `Decksmith.xcodeproj` is the primary native app project. `Package.swift` provides package-level builds and tests for the modular backend.

## Development

```sh
swift test
swift build
open Decksmith.xcodeproj
```

Hardware integration tests will be opt-in and require a connected device. They must never claim hardware success from mocks.

## Architecture

See:

- `Documentation/architecture.md`
- `Documentation/data-model.md`
- `Documentation/plugin-compatibility.md`
- `Documentation/protocol.md`
- `AGENTS.md`

## License

License selection will be finalized before the first public release.
