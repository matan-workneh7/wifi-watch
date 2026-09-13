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
    raw=$({ timeout 30 omarchy network speedtest down 2>/dev/null; } | tail -n +2 | sort -g | tail -1)
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
