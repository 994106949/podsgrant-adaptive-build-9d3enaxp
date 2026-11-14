# PodsGrant AACP Diagnostics 0.5.8 diag8

RootHide diagnostic package for testing AirPods AACP listening-mode frames.

Open Settings, connect the AirPods, open the accessory detail page, and tap
**AACP** in the navigation bar. Test ANC and Transparency before Adaptive.

## Transport flow

The Settings UI writes one request plist containing the AirPods address, mode
and a unique sequence number. It then waits up to 30 seconds for a result from
one of these sources:

- `bluetoothd`: the injected helper inside the Bluetooth daemon
- `heard`: the injected helper inside Apple's hearing process
- `aacpdiagd`: the root LaunchDaemon fallback

The helpers poll every 250 ms and share a `claim-<sequence>` file under
`/var/tmp/com.lns.pogr.aacpdiag`. The first consumer to create the claim file
owns that request; other consumers log `helper_request_skip` or
`fallback_skipped reason=helper_claimed` and do not send duplicate frames.

The root daemon observes each request and waits 750 ms before its fallback. If
an injected helper has already claimed or completed the request, the daemon
stops. Otherwise the daemon claims it and performs the L2CAP transport itself.
This keeps the helper path primary while preserving a usable fallback when
injection is unavailable.

Results are tagged by producer:

```text
/var/tmp/com.lns.pogr.aacpdiag/result-bluetoothd.plist
/var/tmp/com.lns.pogr.aacpdiag/result-heard.plist
/var/tmp/com.lns.pogr.aacpdiag/result-aacpdiagd.plist
```

## Confirmation levels

The diagnostic records these separate stages:

- `local_getter`: private BluetoothDevice property; informational only
- `socket_tx`: the actual AACP request
- `earbud_rx`: packets returned by the earbuds
- `protocol_ack`: a reply matching setting `0x0D` and the requested mode

The Settings alert uses these result levels:

- `Protocol ACK`: a matching AACP reply was decoded
- `Native Setter Invoked / Unconfirmed`: a private setter ran, but no ACK
- `Local Getter Only`: a local property was read back, not device confirmation
- `Device Missing`: no live object matched the AirPods address
- `Setter Missing`: no supported listening-mode setter was found

Mismatched mode bytes are reported as `protocol_reply_mismatch`.
`transport_no_reply` means a transport was loaded but no result arrived within
the 30-second UI deadline. `transport_not_loaded` means no helper or daemon
published readiness.

Adaptive mode `0x0D 04` is tested only after ANC and Transparency answer. A
protocol ACK confirms matching bytes, not an audible result.

## Logs

Primary log:

```text
/var/mobile/Library/Preferences/com.lns.pogr.aacpdiag.log
```

Fallback logs:

```text
/var/tmp/com.lns.pogr.aacpdiag/helper-boot.log
/tmp/com.lns.pogr.aacpdiag/helper-boot.log
```

Marker names are source-specific. A healthy result should include:

```text
helper_loaded
helper_polling_started
helper_request_poll
helper_transport_start
socket_tx
earbud_rx
result_written
status=protocol_ack
```

The request line includes `source=bluetoothd`, `source=heard` or
`source=aacpdiagd`. Use the same source to follow `claim-*`, transport and
result output. Daemon installation lines include `source_ready_file`,
`daemon_direct_fallback_begin` and `daemon_direct_fallback_status`.

If `Device Missing` appears, manually switch ANC/Transparency once in Apple
Settings, return to the accessory page and retry so the runtime path creates a
live device object.
