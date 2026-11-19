# Architecture

Decksmith uses a layered design:

`DecksmithTransport` owns IOKit HID lifecycle and bounded packet delivery. `IOKitHIDTransport` matches one vendor/product pair, optionally filters by serial number, opens and closes the matching HID device, forwards input reports through an `AsyncStream`, and serializes output reports through the actor boundary. Transport packets use the full-report convention: the first byte is the HID report ID and remaining bytes are the report payload. `DecksmithProtocol` decodes reports and encodes device-specific output through versioned codecs. `DecksmithDevice` owns one device session, serialized writes, reconnect/cancellation, input routing, and surface revision reconciliation. `DecksmithRendering` renders logical scenes off the main actor. `DecksmithRuntime` hosts integrations and plugins. `DecksmithPersistence` owns versioned application state. `DecksmithObservability` owns structured events and forensic capture. SwiftUI observes application state and does not access IOKit directly.

The public SDK contract is an adapter at the edge, not the domain model. This allows unchanged Node.js plugins to work while native Swift integrations can use richer capabilities such as touch gestures, layered scenes, multiple pages, device telemetry, and multi-device routing.

`DecksmithPluginSwift` imports installed `.sdPlugin` metadata, `.streamDeckProfile` bundles, and multi-profile `.streamDeckProfilesBackup` archives from Stream Deck. Backup import preserves each profile, per-action plugin UUID, controller coordinates, action UUIDs, names, and settings; Decksmith does not reimplement a plugin's behavior or create a separate Volume Controller clone. External plugin process execution remains an adapter concern in `DecksmithPluginWebSocket`.
Profile state titles and referenced image assets are copied into `~/Library/Application Support/Decksmith/ProfileAssets` during import so the selected state can be rendered after the temporary backup extraction directory is removed. Assets are normalized at ingestion into deterministic PNG cache files with device-safe dimensions (120×120 for key assets); transparent source artwork preserves the composed surface background. Runtime plugin images use the corresponding key or encoder/touchscreen canvas size.
The adapter now launches installed plugin executables with the official `-port`, `-pluginUUID`, and `-registerEvent` arguments and provides a macOS Network.framework WebSocket listener for protocol envelopes.

Diagnostics are appended as JSON Lines to `~/Library/Application Support/Decksmith/Logs/decksmith.log`; the diagnostics store reads that file for snapshots instead of retaining an in-memory event buffer.

The native shell exposes an explicit control-mapping editor for all eight keys, four encoders, and four touchscreen segments. Each mapping stores the imported plugin UUID and action UUID, and imported Stream Deck profiles populate the same editor so assignments can be reviewed, reassigned, or cleared in Decksmith.
Mappings and settings are persisted in the versioned JSON envelope at `~/Library/Application Support/Decksmith/assignments.json` and restored at launch.
The SwiftUI editor keeps editable profiles and pages in the separate versioned envelope at `~/Library/Application Support/Decksmith/workspace.json`. Vendor imports are normalized into this Decksmith-owned state; vendor files are never mutated implicitly. The Profiles menu exposes explicit Decksmith backup JSON import/export and native `.streamDeckProfile` / `.streamDeckProfilesBackup` export/import paths.

The native app discovers Elgato HID devices at launch, automatically connects to the first detected device, and allows selecting another discovered device. `InMemoryTransport` exists only as a unit-test double; the application path uses `IOKitHIDTransport` and does not report simulated hardware as connected.

Stream Deck+ output uses JPEG images at the device dimensions: 120×120 for keys and one composed 800×100 window for the touchscreen and encoder labels. Encoder and touchscreen assignments are therefore rendered together instead of issuing competing full-window writes. Input decoding follows the documented button, touch, and encoder report payloads and preserves unsupported reports as protocol anomalies.

For repeatable hardware diagnostics, the app accepts `--profile-backup <path>` or `DECKSMITH_PROFILE_BACKUP=<path>`. The backup is imported before HID connection, and the selected `Default` profile is applied automatically once the device opens.
