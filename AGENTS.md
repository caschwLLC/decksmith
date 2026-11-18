# Decksmith agent instructions

## Project goals

Decksmith is a native macOS Swift/SwiftUI client for Stream Deck hardware. It must provide a high-performance, extensible backend for HID input, device output, pages/surfaces, integrations, and both Swift-native and official Node.js plugin compatibility.

## Engineering rules

- Keep SwiftUI presentation separate from transport, protocol, device-session, rendering, plugin, persistence, and observability layers.
- Use Swift Concurrency deliberately: actors own mutable hardware/runtime state; values crossing boundaries are `Sendable`.
- Prefer stable typed IDs and versioned Codable envelopes over array indexes or ad-hoc dictionaries.
- Preserve unknown protocol fields/reports where safe and surface malformed input explicitly.
- Follow DRY, SOLID, defensive parsing, explicit error handling, and narrow module responsibilities.
- Never add fake success behavior to real hardware paths. Hardware tests are opt-in and must clearly distinguish fixtures from device validation.
- Every behavior change needs focused unit tests. Add contract fixtures for official plugin compatibility and concurrency tests for cancellation/reconnect/revision ordering.
- Keep schema migrations explicit and backward-compatible where possible.

## Review gates

Before creating a pull request, run package tests/build and review:

1. architecture boundaries and dependency direction;
2. data-model stability, schema versioning, and unknown-field behavior;
3. Swift 6 concurrency and `Sendable` correctness;
4. plugin compatibility and unsupported-command reporting;
5. error surfacing, observability, and test coverage;
6. API documentation and user-facing behavior.

Do not create a PR until the architecture/data-model review and code review checklists are complete.
