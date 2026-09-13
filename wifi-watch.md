# wifi-watch

A tiny notification monitor that lives in your session tray of your mind — it tells you **when** your WiFi dies, **why** it died, and whether it actually got back to full speed. Not a ping in a terminal, not a log file you never read: one on-screen card that replaces itself as things change. Built for Omarchy (Arch + Hyprland + Quickshell), portable to any Linux desktop.

**In one glance:** your network drops → a notification stays on screen: "WiFi timeout — signal weak -70 dBm (normal -53)". It reappears: "WiFi working". Ten seconds later: "download: 42 Mbps". That's the whole show — nothing to open, nothing to configure once installed.

**The part people find fun:** it *learns your own network*. The `(normal …)` in brackets isn't a hardcoded number — it's your link's real typical value, measured while you use it. Switch from home WiFi to a hotspot and the brackets follow you; when something's wrong, the diagnosis is relative to *your* normal, not an arbitrary textbook value.

When the network drops, instead of a generic "ping timed out", you get a diagnosis with real measurements:

```
WiFi timeout
signal weak -70 dBm (normal -53)
```

```
WiFi timeout
internet unreachable
```

## What it does

One background loop runs every second and:

1. **Pings the internet** (default `1.1.1.1`) — this decides the up/down state.
2. **Pings the router** (auto-detected gateway) — feeds the router-vs-internet diagnosis.
3. **Reads the WiFi signal** from the interface (`iw`) — feeds the weak-signal diagnosis.

It keeps a small **rolling window of the last 10 pings** in memory (packet-loss %, latest latency, latest signal). Nothing is written to disk during normal operation.

### On state flips

| Event | What happens |
|-------|--------------|
| Network down, still connected to WiFi (3 steady seconds) | A **critical** "WiFi timeout" toast appears and **stays on screen** until you hover it or right-click it. Its body is a diagnosis (below). |
| Network back (3 steady seconds) | A "WiFi working" toast replaces the timeout one and disappears after ~3 s. |
| ~10 s after network back | A separate **speed toast** fires with the download speed. It auto-expires after ~5 s. |
| Network dies while speed-testing | The speed test subprocess is killed so its toast can't fire during the outage. |
| **WiFi off / not connected to anything** | The timeout toast is **dismissed immediately** — if your laptop isn't on any network, a "no internet" notification is pointless noise, so it vanishes the instant association is lost. |

**No notification stacking, ever.** All toasts reuse notification IDs (`-r`) so they replace each other in place instead of piling up — even when the network is flapping.

## Lifecycle: one outage, second by second

The whole monitor is **one `while true` loop that wakes every second**. Each wake does four things, in order:

1. **Probe** — ping the internet target (`1.1.1.1`) and check whether WiFi is still associated. Together they pick one of **three states**: `ok`, `timeout` (on a network, link unreachable), or `disconnected` (not on any network).
2. **Sample** — record what just happened (signal, latency, loss, gateway reachability) into the rolling window and baselines.
3. **Arm** — update the stability counter so a single blip can never fire a toast.
4. **Act** — if the state *really* flipped and the user hasn't been told yet, send the notification (and manage the speed test).

Here is one full outage cycle, tick by tick (t = seconds):

| t | WiFi | ping | state | `stable` | what happens at "Act" |
|---|------|------|-------|----------|------------------------|
| 0–9 | up | ok | ok | 10 | nothing; baselines are learning your normal |
| 10 | **dies** | timeout | ok → timeout | reset to 1 | "one failure — probably nothing" |
| 11 | dead | timeout | timeout | 2 | "still failing…" |
| 12 | dead | timeout | timeout | **3** | **timeout toast** (critical) + kill any running speed test |
| 13–… | dead | timeout | timeout | 4, 5, 6… | **nothing** — the `last_sent` guard means one toast per outage, not one per second |
| … | **back** | ok | timeout → ok | reset to 1 | "is it stable? wait…" |
| +1 | up | ok | ok | 2 | "still good…" |
| +2 | up | ok | ok | **3** | **working toast** (replaces the timeout in place) + start speed test |
| +12 | up | speed test done | ok | — | **speed toast** with the download figure |

The 3-second confirmation on both sides is deliberate: a single missed ping (route repicking, a busy moment, a quick reassociate) is **not** an outage, and a single lucky ping is not a recovery.

**The third state — the exception to the 3-second rule.** If instead the WiFi **disappears entirely** (radio off, out of range, no network selected), the state becomes `disconnected`, and the timeout toast is dismissed **immediately — no 3-second wait**. There is no debouncing needed, because "not associated with a network" is a fact you can't argue with, and the moment it's gone the exact condition the user cares about ("am I connected yet?") is already visible in the system tray. A transient one-tick flicker can't cause a problem: if the link comes back and still fails, the timeout toast returns after its normal 3 steady seconds. Leaving `disconnected` (staying unassociated for hours) produces exactly **one** dismiss, never a repeating one.

## The state machine (two guards)

Two independent counters together guarantee exactly one toast per real event — no more, no less.

**Guard 1 — the `stable` counter (debounce).** Incremented by 1 on every tick where the state matches the previous tick; reset to `1` the moment the state changes. An action fires only when `stable >= min_stable` (3) — **with one exception**: the `disconnected` state fires immediately (see Lifecycle). This is why a lone blip is ignored. The counter is capped at `999999` so a monitor that runs for weeks can never hit bash integer overflow.

**Guard 2 — the `last_sent` guard (dedup).** `state` mirrors reality; `last_sent` remembers the last thing the user was *told*. The toast fires only when:

```bash
now != last_sent   &&   ( now == "disconnected" || stable >= min_stable )
```

After the one timeout toast, `last_sent` becomes `timeout`, so the remaining 3599 failed seconds of a one-hour outage send **zero** additional toasts. On recovery, `now` becomes `ok`, `last_sent` is still `timeout`, so the "working" toast fires exactly once. When the network vanishes entirely, `now` becomes `disconnected`, which bypasses the STABLE wait and dismisses immediately — but `last_sent` still dedupes it: one dismiss per disconnect, no matter how long you stay offline. Flipping the same flag twice? Not possible — both conditions must be true simultaneously.

## Sampling: what each tick records

`record_sample` runs every second and maintains everything the diagnosis might need:

| Variable | What it holds | When updated |
|----------|---------------|--------------|
| `gw_ok` | router reachable (`yes`/`no`) — pings the default gateway | every tick |
| `sig` | last-known-good signal, dBm | only on `ok` ticks |
| `lat` | last-known-good latency, ms | only on `ok` ticks |
| `loss` | packet-loss % over the rolling window | every tick |
| `history` | the last 10 samples (`ok`/`fail`) | every tick |
| `bsig`/`blat`/`bloss` | EWMA baselines (your "normal") | only on `ok` ticks |

**The rolling window.** The last 10 samples are kept in memory as an array. A new sample is appended; once the window is full the oldest is dropped (FIFO). Packet loss % is `failed ÷ window × 100`.

**The trailing-cut trim.** Before loss is computed, any **consecutive `fail` run at the end** of the window is stripped. This is the fix that made a clean cut honest:

```
clean-cut window:  ok ok ok ok ok ok ok fail fail fail
trailing fails removed → 7 samples, 0 fails → loss = 0%
```

A dead hotspot is not "packet loss" — it's just *down*, and the diagnosis should say so (`router unreachable`). Intermittent drops before the cut still count:

```
flaky window:  ok fail ok ok fail ok fail ok fail fail
trailing fails removed → 8 samples, 3 fails → loss = 37%
```

Only real, pre-cut flakiness can push loss over a threshold — a clean link death never can.

## Notification mechanics

Everything the user sees comes from Omarchy's notification daemon, driven by `omarchy notification send`. Three toasts exist, and they never pile up.

| Toast | When | Urgency | Auto-expire | Replaces |
|-------|------|---------|-------------|----------|
| `WiFi timeout` | confirmed outage (still on a network) | **critical** | **never** — stays until hovered/right-clicked | prior toast |
| `WiFi working` | confirmed recovery | low | ~5 s (`-t 1000`, daemon floors to 5 s) | the timeout toast |
| `WiFi speed` | ~10 s after recovery | low | ~5 s (`-t 5000`) | previous speed toast only |
| *(none — dismiss)* | WiFi fully disconnected | — | the timeout toast is **closed immediately** via `omarchy notification dismiss` | — |

**Replace-in-place is guaranteed by *both* IDs.** The main `id` variable starts at `0` (`-r 0` = "create anew"), and every send re-captures the daemon's returned ID so the *next* send can replace the exact same slot. The speed toast does the same via its own little file (`/tmp/wifi-speed-id.txt`) so the three toasts each own a slot and never collide. Dismissals target the timeout toast's summary (`WiFi timeout`); if none is showing, the dismiss is a harmless no-op.

**Why `critical` for the outage?** The daemon's `durationFor` gives critical a zero expiry — the toast simply never goes away on its own. That's exactly the property a "your network is dead" notification needs: it's there when you get back to the desk, hover, and click. The working/speed toasts are low (transient); the daemon floors their 1 s/5 s requests to a readable minimum so they never flash and vanish.

**Flapping is safe by construction.** Same slot, replaced each flip — a network bouncing every 15 s produces two toasts per cycle, not a growing pile.

## The speed test subsystem

On recovery, `start_speedtest` runs, in one go:

1. **Kill** any previous speed test still running (there shouldn't be one, but there may be if the network died mid-test and the kill raced recovery).
2. **Launch** `setsid bash -c '…' &` in the background — `setsid` puts it in its **own process group**, which is what lets the monitor kill the *whole* test later with one signal.
3. Inside, run: `timeout 30 omarchy network speedtest down`, then pipe everything through `sort -g | tail -1` — `omarchy network speedtest` streams one **Mbps sample per second**, so sorting numerically and taking the last line yields the **peak download speed**.
4. Post the result as the `WiFi speed` toast; store its returned ID in `/tmp/wifi-speed-id.txt` so the next speed toast replaces it in place.
5. Guard rails: `timeout 30` caps even the slowest test at 30 s; an empty result exits silently (no toast); the whole job's output is discarded.

**Why download only?** Download is the number people mean by "the wifi is back to full speed" — and an upload leg would add another ~10 s to a toast the user already waited ~10 s for. One direction, fast, disposable.

**Why `kill -- "-$pid"` in `kill_speedtest`?** The minus sign signals the *process group*, not the leader — combined with `setsid`, a single `kill` reaps the speed test and anything it spawned, so a zombie test can't fire its toast during the next outage. If group-kill fails it falls back to killing the leader directly.

## Runtime files

Only two files are ever touched, both machine-local and volatile — there is no log, no history, nothing persistent:

| File | Contents | Written by |
|------|----------|-----------|
| `/tmp/wifi-state.txt` | the current state, one word: `ok` or `timeout` | `notify_main` on each flip |
| `/tmp/wifi-speed-id.txt` | the speed toast's notification ID | the finished speed test |

`/tmp` is `tmpfs` (RAM) — on reboot both vanish. Reading them is how you check on the monitor (`cat /tmp/wifi-state.txt`).

## The diagnosis

On timeout, the toast body is built from the **last-known-good** values captured *before* the cut (the link is dead by the time you're notified, so measuring then is useless).

Signal and latency are read as they fluctuate; packet loss is the % of failed pings in the last 10-sample window — but any **trailing run of consecutive failures is excluded**, so the cut that caused the outage can never be counted as packet loss. Only failures that happened *before* the cut (intermittent drops) can push loss over the threshold.

### It learns your "normal" — no fake defaults

The bracketed "normal" is **not a constant** — the monitor learns it from your actual link. Every healthy ping feeds a slow-moving average (EWMA) per metric, and that becomes the `(normal …)` shown in brackets:

- **Signal:** the bracket shows your typical dBm while connected
- **Latency:** the bracket shows your typical round-trip time
- **Packet loss:** the bracket shows your typical loss (normally 0%)

So on a hotspot that's normally ~54 ms, a 240 ms spike shows `latency high 240 ms (normal 54)` — meaningful context. On a fast line it shows `(normal 12)`. Same code, no profiling, nothing written to disk.

#### The math (exact formula, no tricks)

This is **not a latency-only thing**. The exact same EWMA runs on all three metrics — signal, latency, and packet loss — each with its own independent baseline, updated only on healthy pings:

```awk
# one line per metric, identical weight (in record_sample):
bsig  = 0.95 × bsig  + 0.05 × signal   # dBm
blat  = 0.95 × blat  + 0.05 × latency  # ms
bloss = 0.95 × bloss + 0.05 × loss     # %
```

Five properties fall straight out of that formula — worth knowing before you trust a bracket:

1. **Not a halver.** Steady 100 ms latency converges to a baseline of exactly `100`, not `50`. Likewise a steady −53 dBm signal settles at `−53`, and 0% loss stays `0`. Each sample only pulls the baseline 5% of the way toward the new reading, so the "typical" value dominates.
2. **Damped against spikes.** A 3-second latency spike to 400 ms on a normal 100 ms link only moves the baseline to ~143 ms, and it relaxes back toward 100 on its own. A 5-second signal sag from −53 to −70 only drags the signal baseline a few dB. One bad second can't poison your "normal".
3. **Cold start.** The first sample seeds the baseline verbatim (`baseline = sample`), so you get honest brackets within ~20–30 s of connecting, and full convergence after a few minutes of the same signal.
4. **It chases slow reality too.** If your connection is *genuinely* slow (steady 250 ms) or genuinely weak (steady −80 dBm), the baseline honestly settles there — your network is judged by your real world, not an imagined fast one.
5. **Relearns on network change.** All three baselines reset on every reconnect, so switching from a hotspot to home WiFi gives the new link its own normal within a couple of minutes.

**Why speed isn't factored into the latency normal:** latency (delay, ms) and speed (throughput, Mbps) are orthogonal — satellite links have huge speed and huge latency; congested links the reverse. Polluting the delay reading with throughput would distort it, so each axis gets its own measurement. Your monitor therefore reports throughput separately (the `download: X Mbps` toast on reconnect) and learns delay only from observed round-trips.

### Deviation thresholds, relative to that normal

A metric is only called a problem when it deviates *relative to your own baseline*, with an absolute floor so nothing goes unmonitored:

| Metric | Flags when | Why relative |
|--------|-----------|--------------|
| **Signal** (dBm) | below `max(sig_lim, normal − 10)` | a 10+ dBm drop from your typical is a real problem even if it's a "good" absolute number |
| **Latency** (ms) | above `max(lat_lim, normal × 4)` | 4× your typical = clearly struggling; on a slow line a modest number isn't a blip |
| **Packet loss** (%) | above `max(loss_lim, normal × 3)` | even a chronically slightly-lossy link gets a fair threshold |

Defaults when nothing has been learned yet (first seconds after boot): `sig_lim=-75`, `lat_lim=150`, `loss_lim=10` — the classic absolute standards, listed as variables at the top of the script for tweaking.

All 9 cases are handled (each metric carries its learned normal value in brackets):

| Conditions | Toast body example |
|------------|-------------------|
| Signal far below its learned normal | `signal weak -70 dBm (normal -53)` |
| Latency far above its learned normal | `latency high 240 ms (normal 54)` |
| Packet loss above its learned normal | `packet loss 15% (normal 0%)` |
| Signal + latency | `signal weak -70 dBm (normal -53) + latency high 240 ms (normal 54)` |
| Signal + packet loss | `signal weak -70 dBm (normal -53) + packet loss 15% (normal 0%)` |
| Latency + packet loss | `latency high 240 ms (normal 54) + packet loss 15% (normal 0%)` |
| All three | `signal weak -70 dBm (normal -53) + latency high 240 ms (normal 54) + packet loss 15% (normal 0%)` |
| Clean cut, router unreachable | `router unreachable` |
| Clean cut, router fine | `internet unreachable` |

## Why "last known good" numbers, not live ones

When the timeout toast fires, the connection is already dead — live signal/latency/packet-loss measurements are meaningless or literally unreachable. So the monitor records measurements **while connected** and reuses the latest good values when the cut happens. That's how it can tell you `signal weak -70 dBm` — the last reading before the network vanished.

## The two-probe trick

Two probes, two different jobs:

- **`1.1.1.1`** → reaches the actual internet. Every provider answers pings; it's the standard "is the internet really there" check. It alone decides up/down.
- **Router gateway** → auto-discovered via `ip route show default`. Only feeds the diagnosis, letting you distinguish:

  - `internet unreachable` → your WiFi/router are fine, the line *outside* is dead
  - `router unreachable` → the router itself is gone/off

This matters a lot if you often see "WiFi connected but no internet".

## The systemd service explained

```ini
[Unit]
Description=WiFi link monitor with in-place Omarchy notifications
After=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.config/omarchy/scripts/wifi-watch.sh 1.1.1.1
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
```

Every line, decoded:

| Directive | What it does |
|-----------|--------------|
| `After=graphical-session.target` | waits until the desktop session is up — the monitor must not start before the notification daemon exists, or its first toast would be lost |
| `Type=simple` | the `ExecStart` process *is* the service — no daemonization, the `while true` loop runs in it directly |
| `ExecStart=%h/…/wifi-watch.sh 1.1.1.1` | `%h` is systemd's **home-directory expansion** — the unit works unedited for any username. The `1.1.1.1` argument becomes the script's `$1`, i.e. the ping target |
| `Restart=on-failure` | if the script crashes it's brought back automatically — the monitor is meant to be always-on |
| `RestartSec=3` | …but only after a 3-second pause, so a crash-loop can't hammer the CPU |
| `WantedBy=graphical-session.target` | starts the unit at login (as a user service, tied to your session, not the whole machine) |

It's a **user** unit (`systemctl --user`), so no `sudo` is involved, and it stops with your session — exactly the lifetime the monitor wants.

## Failure modes & edge cases

| Situation | What happens | Why it's handled |
|-----------|--------------|------------------|
| Boot/startup with WiFi already dead | first 3 ticks fail → `stable` hits 3 → timeout toast fires with the honest diagnosis (`router unreachable`/`internet unreachable`) | the 3-second rule creates a truthful "it never came up" report, not a panic |
| Single dropped ping | `stable` resets to 1, no toast | debounce guard |
| `iw` won't report a signal | signal sampling silently skipped; signal never flagged | no false "weak signal" alarms from a missing tool |
| Interface renamed / gone | installer auto-detected it at install; if it changes, `record_sample` just gets no signal and the router+internet logic still works | signal is only ever sampled, never required |
| Suspend / resume | the loop is paused by the kernel, resumes where it left off | no stale "timeout" fires from a suspended machine, and the 3-second rule applies afresh |
| Network dies mid-speed-test | the timeout's Act step calls `kill_speedtest` → group-kills the test → no speed toast during an outage | `setsid` + `kill -- "-$pid"` |
| Speed test returns nothing | empty result exits silently, no toast | an empty `WiFi speed` toast would just be noise |
| WiFi turned off / no network selected | toast dismissed **immediately** on the first unassociated tick; no notification while offline, ever | the `disconnected` state bypasses the 3-second wait |
| Outage lasting hours | exactly **one** timeout toast | `last_sent` dedup guard |
| Reconnect to a different network | baselines reset, new `(normal …)` learned ~20–30 s later | the brackets always describe the *current* link |
| `1.1.1.1` blocked by a provider | every ping times out → false outage until the target is changed | documented in Notes; target is the first script argument |

## Testing & real-world results

### Simulation tests (message logic)

The diagnosis function was driven with synthetic values for all 9 cases against a **learned baseline** (normal signal −53 dBm, normal latency 54 ms, normal loss 0%). Each produced the expected toast on a real desktop:

| # | Conditions | Toast shown |
|---|-----------|-------------|
| 1 | signal −70 vs normal −53 | `signal weak -70 dBm (normal -53)` |
| 2 | latency 240 vs normal 54 | `latency high 240 ms (normal 54)` |
| 3 | loss 15 vs normal 0 | `packet loss 15% (normal 0%)` |
| 4 | signal −70 + latency 240 | `signal weak -70 dBm (normal -53) + latency high 240 ms (normal 54)` |
| 5 | signal −70 + loss 15 | `signal weak -70 dBm (normal -53) + packet loss 15% (normal 0%)` |
| 6 | latency 240 + loss 15 | `latency high 240 ms (normal 54) + packet loss 15% (normal 0%)` |
| 7 | all three | `signal weak -70 dBm (normal -53) + latency high 240 ms (normal 54) + packet loss 15% (normal 0%)` |
| 8 | clean cut, router fine | `internet unreachable` |
| 9 | clean cut, router gone | `router unreachable` |

The same scenarios were also validated with the **boot defaults** (nothing learned yet) — the reference values fall back to `-50`, `12`, `0%` and the absolute thresholds `-75`/`150`/`10` kick in, so the monitor is never blind during warm-up.

### Live test (real wifi toggle)

WiFi was turned off at the router level and reconnected (the monitor runs the whole time — nothing simulated):

**Off** — the monitor detected the drop and diagnosed it from live readings. With the "trailing-cut" fix, a clean link death reports the root cause alone:

```
router unreachable
```

(An earlier build also showed `packet loss 60%` here — wrong. A clean cut isn't packet loss; it's just *down*. Packet loss now only counts failures that happened **before** the final cut — intermittent drops — so a dead link can't pollute the loss figure.)

**Back on** — the "WiFi working" toast replaced the timeout toast in place (same notification ID, no stacking), and the download-speed toast followed ~10 s later.

Because the baseline resets on each reconnect, the brackets always describe the *current* network — the same machine shows `(normal 12)` on one WiFi and `(normal 54)` on another without any reconfiguration.

The live test also confirmed the timing: the drop isn't reported until 3 steady seconds of failure, so a single missed ping never causes a false alarm.

## Files

Everything lives in this package (share the whole folder / repo):

| Path (in this package) | What it is |
|------------------------|-----------|
| `wifi-watch.md` | This document |
| `README.md` | The quick look-me-over readme |
| `wifi-watch.sh` | The monitor script (the whole thing) |
| `wifi-watch.service` | systemd user unit (uses `%h`, no editing needed) |
| `install.sh` | Self-contained one-command installer / uninstaller |

Which install to these locations:

| Path (on your machine) | What it is |
|------------------------|-----------|
| `~/.config/omarchy/scripts/wifi-watch.sh` | The monitor script |
| `~/.config/systemd/user/wifi-watch.service` | Runs it at login, restarts on failure |

Both targets are user-level config — nothing is touched in system directories.

## Install

### Option A — clone or one command (recommended)

```bash
git clone https://github.com/matan-workneh7/wifi-watch.git && cd wifi-watch
./install.sh
```

Or without cloning — the installer is self-contained (embeds everything):

```bash
curl -fsSL https://raw.githubusercontent.com/matan-workneh7/wifi-watch/main/install.sh | bash
```

The installer auto-detects your wifi interface (or use `./install.sh --iface wlp2s0`), backs up
anything it overwrites, writes both files, and enables the service. Done.

```bash
# Remove it again
./install.sh --uninstall
```

### Option B — manual

The script (adjust the ping target if you like):

```bash
# The script (adjust the ping target if you like)
sudo tee ~/.config/omarchy/scripts/wifi-watch.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u

target=${1:-1.1.1.1}
id=0
state_file=/tmp/wifi-state.txt
min_stable=3
stable=0
state="unknown"
last_sent=""
speed_pid=""

iface=wlo1          # wifi interface (change or use install --iface <name>)

sig_lim=-75
lat_lim=150
loss_lim=10

sig=""
lat=""
loss=""
gw_ok=""
history=( )
bsig=""    # learned normal signal (dBm), EWMA of OK samples
blat=""    # learned normal latency (ms), EWMA of OK samples
bloss=""   # learned normal packet loss (%), EWMA of OK samples

record_sample() {
  local gw
  gw=$(ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}')
  if [[ -n $gw ]] && ping -c1 -W2 "$gw" >/dev/null 2>&1; then
    gw_ok="yes"
  else
    gw_ok="no"
  fi
  local rtt="$1"
  if [[ $rtt == "ok" ]]; then
    s=$(iw dev $iface link 2>/dev/null | awk '/signal:/{print $2; exit}')
    if [[ -n $s ]]; then
      sig=$s
      bsig=$(awk -v b="$bsig" -v v="$s" 'BEGIN{if (b=="") print v; else printf "%.0f", 0.05*v + 0.95*b}')
    fi
    lat="$last_rtt"
    blat=$(awk -v b="$blat" -v v="$lat" 'BEGIN{if (b=="") print v; else printf "%.0f", 0.05*v + 0.95*b}')
    history+=("$last_rtt")
  else
    history+=("fail")
  fi
  if ((${#history[@]} > 10)); then history=("${history[@]:1}"); fi
  local i=${#history[@]} fails=0
  while (( i > 0 )) && [[ ${history[$((i-1))]} == "fail" ]]; do ((i--)); done
  for (( j=0; j<i; j++ )); do [[ ${history[j]} == "fail" ]] && ((fails++)); done
  if (( i > 0 )); then loss=$((fails*100/i)); else loss=0; fi
  if [[ $rtt == "ok" ]]; then
    bloss=$(awk -v b="$bloss" -v v="$loss" 'BEGIN{if (b=="") print v; else printf "%.0f", 0.05*v + 0.95*b}')
  fi
}

diagnose() {
  local prob=""
  # signal: flag when it falls below max(sig_lim, learned normal - 10 dBm)
  if [[ -n $sig ]] && (( $(awk -v v="$sig" -v b="${bsig:-}" -v abs="$sig_lim" 'BEGIN{
        t = (b != "" && (b-10) > abs) ? (b-10) : abs;
        print (v < t) ? 1 : 0 }') )); then
    prob+="signal weak ${sig} dBm (normal ${bsig:--50})"
  fi
  # latency: flag when it exceeds max(lat_lim, learned normal * 4)
  if [[ -n $lat ]] && awk -v v="$lat" -v b="${blat:-}" -v abs="$lat_lim" 'BEGIN{
      t = (b != "" && (b*4) > abs) ? (b*4) : abs;
      exit !(v > t) }'; then
    if [[ -n $prob ]]; then prob+=" + "; fi
    prob+="latency high ${lat} ms (normal ${blat:-12})"
  fi
  # packet loss: flag when it exceeds max(loss_lim, learned normal * 3)
  if (( $(awk -v v="$loss" -v b="${bloss:-}" -v abs="$loss_lim" 'BEGIN{
      t = (b != "" && (b*3) > abs) ? (b*3) : abs;
      print (v > t) ? 1 : 0 }') )); then
    if [[ -n $prob ]]; then prob+=" + "; fi
    prob+="packet loss ${loss}% (normal ${bloss:-0}%)"
  fi

  if [[ -z $prob ]]; then
    if [[ $gw_ok == "no" ]]; then
      prob="router unreachable"
    else
      prob="internet unreachable"
    fi
  else
    if [[ $gw_ok == "no" ]]; then
      prob+=" + router unreachable"
    fi
  fi

  echo "$prob"
}

notify_main() {
  local now="$1" body=""
  echo "$now" > "$state_file"
  if [[ $now == "timeout" ]]; then
    body=$(diagnose)
    id=$(omarchy notification send -r "$id" -u critical --app-name "wifi" -g "󰤯" -p "WiFi timeout" "$body" 2>/dev/null)
  elif [[ $now == "ok" ]]; then
    id=$(omarchy notification send -r "$id" -u low --app-name "wifi" -g "󰤨" -p "WiFi working" "ping is back" -t 1000 2>/dev/null)
  else
    omarchy notification dismiss "WiFi timeout" 2>/dev/null
  fi
}

kill_speedtest() {
  if [[ -n $speed_pid ]]; then
    kill -- "-$speed_pid" 2>/dev/null || kill "$speed_pid" 2>/dev/null
    wait "$speed_pid" 2>/dev/null
    speed_pid=""
  fi
}

start_speedtest() {
  kill_speedtest
  setsid bash -c '
    raw=$({ timeout 30 omarchy network speedtest down 2>/dev/null; } | sort -g | tail -1)
    [[ -n ${raw:-} ]] || exit 0
    if [[ -s /tmp/wifi-speed-id.txt ]]; then
      sid=$(cat /tmp/wifi-speed-id.txt 2>/dev/null || echo 0)
    else
      sid=0
    fi
    if [[ -n $sid ]] && ((sid > 0)); then
      sid=$(omarchy notification send -r "$sid" -u low --app-name "wifi" -g "󰤨" -t 5000 -p "WiFi speed" "download: ${raw} Mbps" 2>/dev/null)
    else
      sid=$(omarchy notification send -u low --app-name "wifi" -g "󰤨" -t 5000 -p "WiFi speed" "download: ${raw} Mbps" 2>/dev/null)
    fi
    printf "%s\n" "$sid" > /tmp/wifi-speed-id.txt
  ' >/dev/null 2>&1 &
  speed_pid=$!
}

while true; do
  out=$(ping -c1 -W2 "$target" 2>&1)
  rc=$?
  if (( rc == 0 )); then
    now="ok"
    last_rtt=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /time=/) {gsub(/time=/,"",$i); gsub(/ms/,"",$i); print $i; exit}}' <<<"$out")
    [[ -n $last_rtt ]] || last_rtt=$lat
  elif iw dev $iface link 2>/dev/null | grep -q "Connected to"; then
    now="timeout"
  else
    now="disconnected"
  fi
  record_sample "$now"

  if [[ $now == "$state" ]]; then
    ((stable = stable < 999999 ? stable + 1 : stable))
  else
    state=$now
    stable=1
  fi

  if [[ $now != "$last_sent" ]] && { [[ $now == "disconnected" ]] || (( stable >= min_stable )); }; then
    last_sent=$now
    if [[ $now == "timeout" ]]; then
      notify_main timeout
      kill_speedtest
    elif [[ $now == "ok" ]]; then
      sig=""; lat=""; loss=""; history=( )
      bsig=""; blat=""; bloss=""
      notify_main ok
      start_speedtest
    else
      notify_main disconnected
      kill_speedtest
    fi
  fi

  sleep 1
done
EOF
chmod +x ~/.config/omarchy/scripts/wifi-watch.sh
```

```bash
# The systemd user service — %h means "my home", no username editing
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/wifi-watch.service <<'EOF'
[Unit]
Description=WiFi link monitor with in-place Omarchy notifications
After=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.config/omarchy/scripts/wifi-watch.sh 1.1.1.1
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
```

Then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now wifi-watch.service
```

### Dependencies

- `ip`, `ping`, `iw`, `awk`, `grep` (standard on Arch/Omarchy)
- `omarchy` with its `notification send` and `network speedtest` commands
- A wifi interface — the installer auto-detects the first `wl*` device (fallback `wlo1`); the manual route edits the name in the script

## Customization

| Thing to change | Where |
|-----------------|-------|
| Ping target | First arg to the script / `ExecStart` |
| Signal threshold | `sig_lim` in the script |
| Latency threshold | `lat_lim` in the script |
| Packet-loss threshold | `loss_lim` in the script |
| How long "down" must persist before notifying | `min_stable` in the script |
| Notification text | the `omarchy notification send` lines in `notify_main` |
| Interface name | `iface` at the top of the script, or `install.sh --iface <name>` |

## Resource usage

The monitor is a single bash loop doing one ping + two tiny commands per second. On a typical build it idles around **~6 MB RSS** and essentially 0% CPU. A speed test spawns a short-lived subprocess (~10 s) while it runs, then it's gone.

## Porting to non-Omarchy desktops

The Omarchy-specific parts are:

1. `omarchy notification send -r <id>` → replace with `notify-send --replace-id <id>` (standard `libnotify`).
2. `omarchy network speedtest` → replace with any speedtest CLI (`speedtest-cli`, etc.), or rip out `start_speedtest` entirely — the up/down + diagnosis features don't need it.

Everything else (ping loop, rolling window, thresholds, diagnosis) is plain bash.

## Notes / limitations

- "Router ping" uses whatever IPv4 default gateway is active — it follows your network, no hardcoding.
- `1.1.1.1` answers pings worldwide; if an ISP/router blocks ICMP to it, switch the target (e.g. `8.8.8.8`).
- The toast shows your numbers; this monitor stores nothing to disk during normal operation. The files it touches are machine-local runtime state (`/tmp/wifi-state.txt`, `/tmp/wifi-speed-id.txt`) that vanish on reboot.
- **Privacy, for the sharing-minded:** nothing personal is ever written to the repo files or logged. No SSIDs, no gateway IPs, no hostnames, no usernames appear anywhere in `wifi-watch.sh`, `wifi-watch.service`, `install.sh`, or this doc. Interface detection is runtime-only (auto-detected by the installer). The only network identifiers evaluated are the ping target (default `1.1.1.1` — change it if you prefer) and the *runtime* gateway, which is never stored.
- Speed toast takes ~10 s to appear after reconnect — that's how long a download speed test takes.