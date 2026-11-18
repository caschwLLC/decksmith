# Protocol

The initial codec targets the verified Stream Deck + report families from the PoC: input report `0x01`, feature reports for brightness/display configuration, and output report `0x02` for image payloads. Production codecs must be selected by device model and firmware, preserve unknown reports, and keep report framing isolated from device-session and UI code.
