# PodsGrant AACP Diagnostics 0.5.7

Independent RootHide package for testing AirPods AACP listening-mode frames.

Open the Settings app, connect the AirPods, open the accessory detail page, and
tap **AACP** in the navigation bar. Test ANC and Transparency first.

The package records these separate stages:

- `local_getter`: the private BluetoothDevice property; informational only
- `socket_tx`: the actual AACP request
- `earbud_rx`: packets returned by the earbuds
- `protocol_ack`: a packet matching setting `0x0D`

Getter readback is informational only. A non-matching reply is reported as
`protocol_reply_mismatch`, not as a confirmed mode change.

An ACK is not evidence of the audible result. Adaptive mode `0x0D 04` is tested
only after the earbuds answer ANC and Transparency.

The new `bluetoothd` diagnostics also log private Bluetooth API calls and AACP
socket TX/RX around each test. Start with a fresh log, manually switch between
ANC and Transparency in Settings, then run the three AACP diagnostics.
