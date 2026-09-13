# wifi-watch

> **A tiny desktop notification monitor that tells you when your WiFi dies — and why.**

No more generic "ping timed out". When the network drops, `wifi-watch` shows a toast that diagnoses the cut with the actual numbers: signal, latency, packet loss, and whether the problem is your router or your internet. When it comes back it replaces that toast, tells you it's working, and ~10 s later reports the download speed.

The clever bit: it **learns your network's own normal** — the `(normal …)` in brackets is measured from your link while you use it, so it follows you from hotspot to home WiFi.

```
WiFi timeout
signal weak -70 dBm (normal -53)
```

```
WiFi timeout
internet unreachable
```

## Features

- **Root-cause diagnosis** — 9 scenarios (7 metric combinations + router vs internet clean cuts), each offending number shown next to its normal value in brackets
- **Learns your "normal"** — no fake defaults: it averages your own typical signal/latency/loss and shows it in the brackets, so a slow line isn't judged by fast-line standards
- **Relative thresholds** — a metric only flags when it deviates from *your* baseline (signal −10 dBm, latency 4×, loss 3×), with absolute floors as a safety net
- **Smart packet loss** — a clean cut can't fake a loss figure: trailing failures are excluded, so loss only ever reflects intermittent drops
- **Privacy-clean** — no SSIDs, gateway IPs, usernames, or hostnames are ever stored or logged; only ephemeral machine-local state in `/tmp`
- **In-place notifications** — all toasts reuse IDs and replace each other; nothing stacks, even during flapping
- **Last-known-good analysis** — evaluates measurements captured *before* the cut, when the link dies measurement is pointless
- **Two-probe tracking** — pings the internet (`1.1.1.1`) for state and the auto-detected router to tell `internet unreachable` from `router unreachable`
- **Automatic speed test** — on reconnect a separate toast reports the download speed, auto-expiring after a few seconds; killed instantly if the network dies again
- **Tiny footprint** — one process, ~6 MB RAM, ~0% CPU
- **Zero disk writes** — the monitoring loop keeps everything in memory; nothing is logged during normal operation
- **Death-while-missing** — the timeout toast is critical and stays on screen until you hover or click it, so you don't miss it
- **Quiet when you're not connected** — the moment the WiFi is turned off or leaves a network, the timeout toast dismisses itself immediately; no notification while you have nothing to be notified about
- **Tested, not just written** — all 9 diagnosis cases validated with live toasts, plus a real wifi toggle proving auto-detection (see wifi-watch.md → Testing)
- **Fully documented, every mechanism** — each variable, guard, formula, subprocess and systemd directive is explained line-by-line in [wifi-watch.md](wifi-watch.md) (lifecycle, state machine, sampling, notification mechanics, speed-test internals, failure modes)

## How it works

A systemd **user service** runs a bash loop every second:

1. Pings `1.1.1.1` → decides up/down
2. Pings the default gateway → router-vs-internet diagnosis
3. Reads WiFi signal from `iw` → weak-signal diagnosis
4. Keeps a rolling window of the last 10 pings for packet-loss %

A state flip happens only after **3 steady seconds** (so a single missed ping won't tickle you). On timeout it sends a persistent critical toast with the diagnosis; on recovery it sends a brief "working" toast and, ~10 s later, a download-speed toast. One exception: if the WiFi is **disconnected entirely** (radio off / no network), the timeout toast is dismissed immediately — there's no point notifying you about a network you can see is off in your tray.

While connected it also learns your link's **baseline** (typical signal, latency, loss) via an exponential moving average — each healthy ping moves it only 5% toward the new reading, so spikes can't fake your "normal":

```
baseline = 0.95 × baseline + 0.05 × sample
```

The `(normal …)` in diagnosis brackets comes from that baseline, and problems are flagged *relative* to it (see wifi-watch.md → The diagnosis for the full math).

## Requirements

- Linux with `ip`, `ping`, `iw`, `awk`, `grep`
- Omarchy (uses `omarchy notification send` and `omarchy network speedtest`)
- A wifi interface — auto-detected; override with `install.sh --iface <name>`

> Not on Omarchy? See **[wifi-watch.md → Porting](wifi-watch.md)** for the `notify-send` / `speedtest-cli` swaps.

## Install

```bash
git clone https://github.com/matan-workneh7/wifi-watch.git
cd wifi-watch
./install.sh
```

Or without cloning — the installer is self-contained:

```bash
curl -fsSL https://raw.githubusercontent.com/matan-workneh7/wifi-watch/main/install.sh | bash
```

The installer auto-detects your WiFi interface (or use `./install.sh --iface wlp2s0`), backs up anything it overwrites, and enables the service.

## Remove

```bash
./install.sh --uninstall
# or, from the raw URL:
curl -fsSL https://raw.githubusercontent.com/matan-workneh7/wifi-watch/main/install.sh | bash -s -- --uninstall
```

## Package layout

| File | Purpose |
|------|---------|
| `install.sh` | Self-contained one-command installer (works standalone via curl) |
| `wifi-watch.sh` | The monitor script |
| `wifi-watch.service` | systemd user unit, `%h`-based, no editing |
| `wifi-watch.md` | Full technical docs + manual install |
| `README.md` | This file |

Full copy-paste manual setup lives in **[wifi-watch.md → Install](wifi-watch.md)**.

## Usage

Just run it. Flip your WiFi off → the timeout toast appears with a diagnosis (stays until hovered/clicked). Flip it back on → "working" toast, then the speed toast ~10 s later.

```bash
systemctl --user status wifi-watch.service   # check it's running
systemctl --user stop wifi-watch.service     # turn it off
```

## Configuration

| Thing | Where |
|-------|-------|
| Ping target | arg to `ExecStart` in `wifi-watch.service` |
| Signal floor | `sig_lim` in `wifi-watch.sh` (default `-75`) |
| Latency floor | `lat_lim` (default `150 ms`) |
| Packet-loss floor | `loss_lim` (default `10%`) |
| Stability window | `min_stable` (default `3`s) |
| Interface | `install.sh --iface <name>` (or `wlo1` in the script) |
| Notification text | `notify_main()` in the script |

> Thresholds are *floors*: beyond them the diagnosis goes relative to your learned normal (see wifi-watch.md → The diagnosis).

## License

MIT — do whatever you want; the diagnostics threshold numbers are not medical advice.

See [wifi-watch.md](wifi-watch.md) for the full technical documentation.