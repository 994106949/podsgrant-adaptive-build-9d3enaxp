# PodsGrant AACP Diagnostics 0.5.7 diag7

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

In diag7, the UI discovers live Bluetooth device candidates by the exact
AirPods MAC address before invoking the private setters. Each diagnostic invokes
only the selected listening mode. Adaptive diagnostics also try
`setAdaptiveTransparencyEnabled:YES` when that selector exists. A per-candidate
class, pointer, address, selector signature, return value and exception log is
written for every attempt.

diag7 separates these confirmation levels in the Settings alert:

- `Protocol ACK`: the daemon decoded a matching AACP reply
- `Native Setter Invoked / Unconfirmed`: a private setter ran, but no AACP ACK
- `Local Getter Only`: the local property was read back; not a device confirmation
- `Device Missing`: no live object matched the AirPods MAC
- `Setter Missing`: no supported listening-mode setter was found

If `Device Missing` appears, manually switch ANC/Transparency once in Apple
Settings, return to the accessory page, and retry so the runtime code path
creates the live device object.

The root LaunchDaemon `com.lns.pogr.aacpdiagd` is the sole AACP
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
