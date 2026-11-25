#!/usr/bin/env bash
# Read-only Wi-Fi diagnostic for macOS and Linux.
# It changes no settings. It sends test traffic (speed test, pings) and reads system state.
# Usage:  bash wifi-diag.sh            -> writes wifi-report.txt next to where you run it
set -u
OUT="${1:-wifi-report.txt}"
OS="$(uname -s)"
exec > >(tee "$OUT") 2>&1

hr() { printf '\n========== %s ==========\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

hr "SYSTEM"
date; uname -a

# ---------- Gateway / interface ----------
if [ "$OS" = "Darwin" ]; then
  GW="$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')"
  IF="$(route -n get default 2>/dev/null | awk '/interface/{print $2}')"
else
  GW="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
fi
echo "Default gateway: ${GW:-unknown}   Interface: ${IF:-unknown}"

# ---------- Wi-Fi link: band, channel, signal, link speed ----------
hr "CURRENT WI-FI LINK"
if [ "$OS" = "Darwin" ]; then
  system_profiler SPAirPortDataType 2>/dev/null | sed -n '/Current Network Information/,/Other Local Wi-Fi Networks/p'
else
  if have iw; then
    for w in $(iw dev | awk '/Interface/{print $2}'); do echo "-- $w"; iw dev "$w" link; iw dev "$w" info | grep -Ei 'channel|txpower'; done
  fi
  have nmcli && nmcli -f GENERAL.DEVICE,GENERAL.CONNECTION,WIFI-PROPERTIES.5GHZ,WIFI-PROPERTIES.6GHZ dev show 2>/dev/null | grep -v '^$'
fi

# ---------- Nearby networks / channel congestion ----------
hr "NEARBY NETWORKS"
if [ "$OS" = "Darwin" ]; then
  system_profiler SPAirPortDataType 2>/dev/null | sed -n '/Other Local Wi-Fi Networks/,$p'
else
  if have nmcli; then
    nmcli dev wifi rescan 2>/dev/null; sleep 3
    nmcli -f IN-USE,SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,SECURITY dev wifi list
    hr "NETWORKS PER CHANNEL"
    nmcli -t -f CHAN dev wifi list | sort -n | uniq -c | sort -rn
  else
    echo "nmcli not found; install NetworkManager or run: sudo iw dev <iface> scan"
  fi
fi

# ---------- Latency ----------
hr "LATENCY (20 pings each)"
for t in ${GW:+$GW} 1.1.1.1 8.8.8.8; do
  echo "-- $t"; ping -c 20 -i 0.3 "$t" 2>&1 | tail -3
done

# ---------- Speed test ----------
hr "SPEED TEST"
if [ "$OS" = "Darwin" ] && have networkQuality; then
  networkQuality -v
elif have speedtest; then speedtest
elif have speedtest-cli; then speedtest-cli --simple
else
  echo "Using Cloudflare (100 MB down, 25 MB up)"
  d=$(curl -s -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=100000000')
  u=$(head -c 25000000 /dev/zero | curl -s -o /dev/null -w '%{speed_upload}' --data-binary @- 'https://speed.cloudflare.com/__up')
  awk -v d="$d" -v u="$u" 'BEGIN{printf "Download: %.1f Mbps\nUpload:   %.1f Mbps\n", d*8/1e6, u*8/1e6}'
fi

# ---------- Bandwidth by process ----------
hr "BANDWIDTH BY PROCESS (5-second sample)"
if [ "$OS" = "Darwin" ]; then
  nettop -P -L 2 -s 5 -J bytes_in,bytes_out -x 2>/dev/null | tail -n +2 | sort -t, -k2 -nr | head -25
elif have nethogs; then
  sudo -n nethogs -t -c 5 2>/dev/null | tail -30 || echo "nethogs needs sudo; showing connections instead"
else
  echo "nethogs not installed; open connections per process:"
  ss -tunp 2>/dev/null | awk -F'"' 'NR>1{print $2}' | sort | uniq -c | sort -rn | head -25
fi

# ---------- Devices on the network ----------
hr "DEVICES ON THE NETWORK"
if [ -n "${GW:-}" ]; then
  PREFIX="${GW%.*}"
  echo "Pinging ${PREFIX}.1-254 to populate the neighbour table..."
  for i in $(seq 1 254); do
    if [ "$OS" = "Darwin" ]; then ping -c1 -t1 "$PREFIX.$i" >/dev/null 2>&1 &
    else ping -c1 -W1 "$PREFIX.$i" >/dev/null 2>&1 & fi
  done; wait
fi
if [ "$OS" = "Darwin" ]; then arp -an | grep -v incomplete
else ip neigh show | grep -v FAILED; fi
have nmap && [ -n "${GW:-}" ] && { echo "-- nmap"; nmap -sn "${GW%.*}.0/24"; }

hr "DONE"
echo "Report saved to $OUT. Paste its contents back to Claude."
