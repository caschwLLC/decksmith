# Plugin compatibility

Decksmith supports two plugin paths:

1. Swift-native plugins with typed async events and Decksmith surface capabilities.
2. Official Node.js plugins using the documented registration arguments and WebSocket JSON envelopes.

The compatibility layer translates official action/context/settings semantics to stable Decksmith IDs and logical surface scenes. Unsupported commands are explicit errors/events, not silent no-ops.
