# PodsGrant AACP Diagnostics 0.5.7 diag6

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

In diag6, the root LaunchDaemon `com.lns.pogr.aacpdiagd` is the sole AACP
transport consumer. It reads requests from the shared request plists, opens the
L2CAP socket as root, records TX/RX packets, and writes results tagged with
`source=aacpdiagd`. The injected helper records runtime-hook readiness; the
Settings UI accepts success only from a daemon result with
`status=protocol_ack`.

The install script records the package file list, candidate RootHide dylib
paths, daemon bootstrap status and process restart status.

Primary log:

```text
/var/mobile/Library/Preferences/com.lns.pogr.aacpdiag.log
```

Fallback logs:

```text
/var/tmp/com.lns.pogr.aacpdiag/helper-boot.log
/tmp/com.lns.pogr.aacpdiag/helper-boot.log
```

For a useful test, wait for these daemon markers before choosing a mode:

```text
helper_loaded source=aacpdiagd
helper_watchdog source=aacpdiagd
request_received
helper_transport_start
socket_tx
earbud_rx
protocol_ack
```

Start with a fresh log, connect the AirPods, manually switch between ANC and
Transparency once, then run the three AACP diagnostics.
