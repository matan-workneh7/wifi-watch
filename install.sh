#!/usr/bin/env bash
#
# wifi-watch — one-command installer
#
# Meaninglessly easy:
#   curl -fsSL https://YOUR-HOST/wifi-watch/install.sh | bash
#   sh <(curl -fsSL https://YOUR-HOST/wifi-watch/install.sh)
#   ./install.sh            (from a clone of this repo)
#
# Options:
#   --yes            don't ask for confirmation
#   --uninstall      remove wifi-watch and its service
#   --iface <name>   wifi interface to monitor (default: auto-detect or wlo1)
#
# Everything is user-level: files under ~/.config, a systemd --user unit.
# No sudo, no system files, no package manager.

set -euo pipefail

ACTION=install
YES=0
IFACE="${WIFI_WATCH_IFACE:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$HOME/.config/omarchy/scripts"
SVC_DIR="$HOME/.config/systemd/user"
SERVICE=wifi-watch.service
STATE_FILE=/tmp/wifi-state.txt

for arg in "$@"; do
  case "$arg" in
    --yes|-y)          YES=1 ;;
    --uninstall|-u)    ACTION=uninstall ;;
    --iface)           echo "install.sh: --iface requires a value" >&2; exit 2 ;;
    --iface=*)         IFACE="${arg#*=}" ;;
    --help|-h)
      sed -n '2,12p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      if [[ -z $IFACE ]]; then IFACE="$arg"; else
        echo "install.sh: unknown argument: $arg" >&2; exit 2
      fi ;;
  esac
done

step()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n $IFACE ]] || {
  for d in /sys/class/net/wl*; do
    if [[ -e $d ]]; then IFACE="$(basename "$d")"; break; fi
  done
}
[[ -n $IFACE ]] || IFACE=wlo1

confirm() {
  [[ $YES == 1 ]] && return 0
  [[ -t 0 ]] || return 0
  printf '\033[1;33m==>\033[0m %s [y/N] ' "$1"
  read -r ans < /dev/tty || read -r ans
  [[ $ans == y || $ans == Y ]] || die "aborted."
}

deps() {
  local missing=""
  for c in omarchy ip ping iw awk sort systemctl; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [[ -n $missing ]]; then
    die "missing dependencies:$missing"
  fi
}

write_script() {
  local dest="$SCRIPTS_DIR/wifi-watch.sh"
  mkdir -p "$SCRIPTS_DIR"
  if [[ -f "$SCRIPT_DIR/wifi-watch.sh" ]]; then
    cp "$SCRIPT_DIR/wifi-watch.sh" "$dest"
  else
    cat > "$dest" <<'WIFI_SCRIPT_EOF'
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
WIFI_SCRIPT_EOF
  fi
  chmod +x "$dest"
  sed -i "s/\bwlo1\b/$IFACE/g" "$dest"
}

write_service() {
  local dest="$SVC_DIR/$SERVICE"
  mkdir -p "$SVC_DIR"
  if [[ -f "$SCRIPT_DIR/$SERVICE" ]]; then
    cp "$SCRIPT_DIR/$SERVICE" "$dest"
  else
    cat > "$dest" <<'SERVICE_EOF'
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
SERVICE_EOF
  fi
}

backup_existing() {
  local f
  for f in "$SCRIPTS_DIR/wifi-watch.sh" "$SVC_DIR/$SERVICE"; do
    [[ -f "$f" ]] || continue
    cp "$f" "$f.bak.$(date +%s)"
    warn "backed up existing $f → $f.bak.$(date +%s)"
  done
}

do_install() {
  deps
  step "Installing wifi-watch for user $USER (interface: $IFACE)"
  confirm "Proceed with installation?"
  backup_existing
  write_script
  write_service
  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE" >/dev/null 2>&1 || warn "enable failed; the service may still work"
  step "Service: $(systemctl --user is-enabled "$SERVICE" 2>/dev/null || echo '?') / $(systemctl --user is-active "$SERVICE" 2>/dev/null || echo '?')"
  sleep 3
  if [[ -f $STATE_FILE ]]; then
    step "Monitoring: $(cat "$STATE_FILE") (see /tmp/wifi-state.txt)"
  else
    warn "state file not written yet — check service logs: journalctl --user -u wifi-watch"
  fi
  cat <<'EOT'

  wifi-watch is live. Flip your WiFi off and back on to see it work.
  - status:  systemctl --user status wifi-watch.service
  - logs:    journalctl --user -u wifi-watch
  - remove:  curl -fsSL https://raw.githubusercontent.com/matan-workneh7/wifi-watch/main/install.sh | bash -s -- --uninstall
  - docs:    wifi-watch.md in this package
EOT
}

do_uninstall() {
  step "Stopping and removing wifi-watch"
  systemctl --user disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$SVC_DIR/$SERVICE" "$SCRIPTS_DIR/wifi-watch.sh"
  rm -f "$STATE_FILE" /tmp/wifi-speed-id.txt
  systemctl --user daemon-reload
  step "Removed cleanly."
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
esac
