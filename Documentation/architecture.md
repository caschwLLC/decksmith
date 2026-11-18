# Architecture

Decksmith uses a layered design:

`DecksmithTransport` owns IOKit HID lifecycle and bounded packet delivery. `DecksmithProtocol` decodes reports and encodes device-specific output through versioned codecs. `DecksmithDevice` owns one device session, serialized writes, reconnect/cancellation, input routing, and surface revision reconciliation. `DecksmithRendering` renders logical scenes off the main actor. `DecksmithRuntime` hosts integrations and plugins. `DecksmithPersistence` owns versioned application state. `DecksmithObservability` owns structured events and forensic capture. SwiftUI observes application state and does not access IOKit directly.

The public SDK contract is an adapter at the edge, not the domain model. This allows unchanged Node.js plugins to work while native Swift integrations can use richer capabilities such as touch gestures, layered scenes, multiple pages, device telemetry, and multi-device routing.
