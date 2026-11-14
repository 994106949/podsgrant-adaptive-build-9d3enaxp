# PodsGrant AACP Diagnostics 0.5.7 diag5

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

Both `bluetoothd` and `heard` run the AACP request poller in diag5. Each result
records which process handled the request, the socket layout, TX bytes and RX
bytes. The install script also records the package file list, candidate
RootHide dylib paths and process restart status.

Start with a fresh log, connect the AirPods, manually switch between ANC and
Transparency once, then run the three AACP diagnostics.
