# PodsGrant AACP Diagnostics 0.5.8 diag10

RootHide diagnostic package for testing AirPods AACP listening-mode frames.

Open Settings, connect the AirPods, open the accessory detail page, and tap
**AACP** in the navigation bar. The single **Adaptive Transparency Mode** action
uses the device's live AACP socket when one is available.

## Transport flow

The Settings UI writes one request plist containing the AirPods address, mode
and a unique sequence number. It then waits up to 30 seconds for a result from
one of these sources:

- `bluetoothd`: the injected helper inside the Bluetooth daemon
- `aacpdiagd`: the root LaunchDaemon fallback

The transport prefers a fresh active AACP descriptor from the injected
`bluetoothd` helper. It selects an exact address match first, otherwise a
unique recently used descriptor. The socket's hooks record both `read` and
`recv`/`recvfrom` traffic so replies can be matched to setting `0x0D`.

The helper and daemon poll every 250 ms and share a `claim-<sequence>` file under
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
/var/tmp/com.lns.pogr.aacpdiag/result-aacpdiagd.plist
```

## Active descriptor transport

When a suitable descriptor exists, the helper sends:

1. `0x1A:0x0F` to enable adaptive listening-mode configuration
2. waits 200 ms
3. `0x0D:<mode>` with mode `4`
4. listens for a matching `0x0D` reply for up to 2.2 seconds

The daemon build intentionally disables opening a second direct AACP socket:
`-DAACPDIAG_TRANSPORT_NO_ACTIVE_FD=1`. Only the injected `bluetoothd` helper
can reuse the live socket. If no suitable descriptor is available, the result
is `active_aacp_fd_tx_unconfirmed` and the trace explains why.

Transport statuses:

- `protocol_ack`: a matching `0x0D` reply echoed the requested mode
- `active_aacp_fd_tx_unconfirmed`: both frames were written, but no matching reply
- `active_aacp_fd_tx_failed`: a frame write failed on the active descriptor
- `protocol_reply_mismatch`: a `0x0D` reply arrived with a different mode byte
- `transport_no_reply`: no result arrived before the UI deadline
- `transport_not_loaded`: neither helper nor daemon published readiness

An ACK proves only that `0x0D` was exchanged with the requested mode byte. It
does not prove that adaptive transparency is audible or that iOS exposes the
same behavior as a newer firmware release.

The action also calls the native listening-mode and adaptive setters as an
informational companion path. Their getters are recorded before and after, but
they do not create a second confirmation level.

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

The request line includes `source=bluetoothd` or `source=aacpdiagd`. Active
descriptor traces include `aacp_active_fd`, `active_fd_selected`,
`aacp_socket_read`, `aacp_socket_recvfrom`, and `active_fd_tx`. Daemon
installation lines include `source_ready_file`,
`daemon_direct_fallback_begin` and `daemon_direct_fallback_status`.

If `Device Missing` appears, manually switch ANC/Transparency once in Apple
Settings, return to the accessory page and retry so the runtime path creates a
live device object.
