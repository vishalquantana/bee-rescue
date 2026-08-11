# bee-rescue

A tiny **macOS** command-line tool to scan for, connect to, and read the battery of a
[Bee](https://bee.computer) wearable (the Omi-compatible always-on recorder) directly over
Bluetooth Low Energy — no phone app required.

It exists because of a very common failure mode:

> **"My Bee shows up / blinks blue, but the phone app says it won't connect."**

Nine times out of ten this is **not** a pairing problem — it's a **dead battery**. A Bee with a
near-flat cell has just enough power to *advertise* (blink) but not enough to hold a stable BLE
connection, so the phone gives up mid-handshake. This tool lets you connect straight from a Mac,
read the actual battery level the device reports, and confirm that's what's going on.

---

## What it does

- **`scan`** — list every nearby BLE device so you can confirm your Bee is advertising.
- **`battery`** — connect and print the real battery `%` and charging state, then exit. *(default)*
- **`connect`** — connect and dump all GATT services/characteristics (for debugging).
- **`monitor <seconds>`** — print the battery level on an interval while it charges.

---

## Requirements

- A **Mac** (uses Apple's CoreBluetooth — this is macOS-only).
- **Xcode command-line tools**: `xcode-select --install`
- Bluetooth turned on, and Terminal allowed under
  **System Settings → Privacy & Security → Bluetooth**.

No other dependencies. The tool is a single Swift file.

---

## Quick start

```bash
git clone https://github.com/<you>/bee-rescue.git
cd bee-rescue

./bee.sh battery      # build + read the battery once
```

Example output:

```
Bluetooth on — scanning for 'Bee'...
Found 'Bee' rssi=-52dBm — connecting...
Connected ✓  discovering services...
[04:36:27] battery=35%  charging=true   raw=00 80 0F C0 23 01
```

The `raw=` bytes are the decoded control frame. A Bee battery reply is
`00 80 0F C0 <level> <charging>`: `00 80` = echo marker (`0x8000`), `0F C0` =
the battery command (`0xC00F`) echoed back, then the **level** byte (`0x23` = 35)
and the **charging** flag. The level lives in the *payload*, after the 4-byte
header — read `raw[0]` by mistake and every reading looks like `0%`.

Other modes:

```bash
./bee.sh scan            # list nearby BLE devices
./bee.sh connect         # dump services + characteristics, stream 60s
./bee.sh monitor 180     # battery reading every 180 seconds
```

`bee.sh` compiles `bee_tool.swift` the first time (and whenever you edit it), then runs it.

---

## How to un-brick a "won't connect" Bee

Follow this in order — the first two steps fix the overwhelming majority of cases.

### 1. Charge it — properly, and for real

- Put it on a **known-good cable and adapter** (try a different cable — flaky cables are common).
- Leave it **at least 30–60 minutes** before judging anything.
- Run `./bee.sh battery` (or `./bee.sh monitor 180`) and watch the number.
  - If it **climbs** (0% → 5% → 12% …), it was simply flat. Let it reach a healthy level and it
    will connect to your phone normally again.
  - A device reporting `battery=0% charging=true` with a **code 7 disconnect** is the classic
    dead-battery signature.

### 2. Get close & kill other connections

- BLE peripherals accept **one** central at a time. Force-quit the Bee app on any phone that may
  still be holding the link, then retry.
- Put the Bee **right next to the Mac**. If `scan`/`battery` reports `rssi` worse than about
  **-70 dBm** while it's inches away, that weak signal is itself a symptom of low power.

### 3. Confirm it's actually alive

```bash
./bee.sh scan
```

If you see a line named **`Bee`**, the device's radio and firmware are fine — it's advertising.
That rules out a totally dead device and points at battery/charging.

### 4. Reset (if charging genuinely does nothing)

If, after a solid hour on a good charger, the level never moves off 0%:

- Try a **long button hold** (~10–15 s) to force a reset, then re-run `./bee.sh scan`.
- If it still won't take a charge, the **battery or charging circuit is likely faulty**.

### 5. Contact support

Email **hi@bee.computer** with what you saw (battery %, whether `scan` finds it, disconnect
codes). Paste the tool output — it's exactly the diagnostic info they need.

---

## Reading the output

| Symptom | Almost always means |
|---|---|
| `scan` finds `Bee`, but `battery`/phone won't hold a connection | **Dead/low battery** — charge it |
| `battery=0% charging=true` then `code 7` disconnect | Classic flat-cell brownout |
| `rssi` worse than -70 dBm with the device inches away | Low power reducing transmit strength |
| `Connect FAILED code=14` | Device rejected pairing (stale bond) — reset the device |
| `scan` never shows `Bee` at all | Device is off / not advertising — charge or reset it |
| `ERROR: Bluetooth permission denied` | Allow Terminal under Privacy & Security → Bluetooth |

---

## Bee BLE reference

Sourced from the open-source [`BasedHardware/omi`](https://github.com/BasedHardware/omi)
device connection code:

| Role | UUID |
|---|---|
| Bee service | `03D5D5C4-A86C-11EE-9D89-8F2089A49E7E` |
| Control characteristic (write + notify) | `05E1F93C-D8D0-5ED8-DD88-379E4C1A3E3E` |
| Audio characteristic (notify, AAC/ADTS) | `B189A505-A86C-11EE-A5FB-8F2089A49E7E` |
| Battery command (write to control char) | `0xC00F` |

**Decoding a control response.** A notification is `[respCode_lo, respCode_hi,
…payload]`. If `respCode == 0x8000` it's an *echo* frame and the payload itself
starts with the echoed command: `[cmd_lo, cmd_hi, …actualPayload]`. So a battery
reply `00 80 0F C0 23 01` decodes to command `0xC00F`, payload `[0x23, 0x01]` →
**level 35 %, charging**. Read the raw header bytes as the level and you'll wrongly
report `0%`.

The Bee advertises a **short 16-bit** service UUID (`D5C4`), so this tool scans all devices and
matches on the name `Bee` rather than filtering on the full 128-bit UUID.

---

## Files

- `bee_tool.swift` — the whole tool (scan / battery / connect / monitor).
- `bee.sh` — build-and-run wrapper.

---

## Disclaimer

Community tool, not affiliated with bee.computer or BasedHardware. Provided as-is. It only reads
the battery and enumerates GATT services — it does not modify the device.
