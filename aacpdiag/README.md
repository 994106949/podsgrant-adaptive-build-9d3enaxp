# PodsGrant AACP Diagnostics 0.6.1~adts3final

RootHide-compatible diagnostic package for sending the AirPods adaptive
transparency listening-mode frame on iOS 16.2.

Open Settings, connect the AirPods, open the accessory detail page, and tap
**AACP** in the navigation bar. Choose **Apply Adaptive Transparency**.

## Safe mode

The Settings tweak writes one request plist and waits up to 8 seconds for a
result. It does not link CoreBluetooth and does not call native listening-mode
getters or setters. This avoids the crashes seen in the earlier diagnostics.

Only the injected `bluetoothd` helper installs runtime hooks. Those hooks cover
the Bluetooth socket family and record `read` and `recv`/`recvfrom` traffic.
The helper build uses `-DAACPDIAG_TRANSPORT_SAFE_MODE=1`, so class hooks for
the Bluetooth frameworks and the native companion path are disabled.

The daemon build uses `-DAACPDIAG_TRANSPORT_NO_ACTIVE_FD=1`. It can publish
readiness and coordinate requests, but it cannot open or reuse an AACP socket.
The helper polls every 250 ms; the daemon fallback waits 750 ms. The first
consumer to create `claim-<sequence>` owns the request, and the other consumer
logs a skip.

## Transport flow

When the helper finds a suitable live descriptor, it sends:

1. `0x1A:0x0F` to enable the listening-mode configuration
2. waits up to 100 ms for a matching `0x1A` configuration reply
3. sends `0x0D:4` for adaptive transparency
4. waits up to 2.2 seconds for a matching `0x0D` reply

Exact address matches are preferred. A unique recently used descriptor may be
used as a fallback. The trace records the selected descriptor, both transmits,
configuration wait, and received frames.

Transport statuses:

- `protocol_ack`: a matching `0x0D` reply echoed mode `4`
- `active_aacp_fd_tx_unconfirmed`: frames were written without a matching reply
- `active_aacp_fd_tx_failed`: a frame write failed on the active descriptor
- `protocol_reply_mismatch`: `0x0D` replied with a different mode byte
- `transport_no_reply`: no result arrived before the UI deadline
- `transport_not_loaded`: neither helper nor daemon published readiness

`protocol_ack` confirms only that the earbuds replied to the `0x0D` request. It
does not prove that adaptive transparency is audible on iOS 16.2. Listening
tests must be done on the device.

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

A healthy result should include:

```text
helper_loaded
helper_polling_started
active_fd_selected
active_fd_tx id=0x1A value=15
active_fd_config_wait ack=1
active_fd_tx id=0x0D value=4
active_fd_rx
result_written
status=protocol_ack
```

If the result is `Device Missing`, connect the AirPods, switch ANC or
Transparency once in Apple Settings, return to the accessory page, and retry.
