# Data model

Stable `DeviceID`, `ControlID`, `SurfaceID`, `PageID`, `PluginID`, and `ActionInstanceID` values are the integration boundary. Hardware indexes are adapter metadata only.

Persisted values use `SchemaEnvelope` with `schemaVersion` and `kind`. Surface updates carry a monotonic `SurfaceRevision`; device sessions ignore stale updates. Input and protocol anomalies preserve sequence and raw payload information so diagnostics remain useful across firmware changes.
