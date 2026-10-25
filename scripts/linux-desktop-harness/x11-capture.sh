#!/usr/bin/env bash
# Cap's recording targets on X11 (Xvfb, MIT-SHM capture, no portal): a Studio
# recording of the display, of an area and of another app's window, and a
# screenshot. Display and area recordings hide Cap and wait for the Stop
# shortcut to start and to stop, pressed here with real X input (xdotool).
# Checks each recording finished, kept no backup of replaced media and holds
# video of the target's size. Prints key=value results to <out-dir>/result.txt and
# fails unless every case passed.
# Usage: x11-capture.sh <cap-gpui> <ffmpeg lib dir> <out-dir>
set -uo pipefail
command -v Xvfb >/dev/null && command -v xdotool >/dev/null && command -v xmessage >/dev/null ||
  { echo "install xvfb, xdotool and x11-utils" >&2; exit 2; }
if [[ -z ${X11_CAPTURE_BUS:-} ]]; then
  exec env X11_CAPTURE_BUS=1 dbus-run-session -- bash "$0" "$@"
fi
bin=$1 libs=$2 out=$3
mkdir -p "$out"
: >"$out/result.txt"
result() { printf '%s=%s\n' "$1" "$2" >>"$out/result.txt"; }
unset WAYLAND_DISPLAY
export DISPLAY=:79 XDG_SESSION_TYPE=x11
Xvfb "$DISPLAY" -screen 0 1920x1080x24 >/dev/null 2>&1 &
xvfb=$!
sleep 1
xmessage -geometry 480x270+700+300 -title "Window to record" "A window to record" >/dev/null 2>&1 &
other=$!
trap 'kill $other $xvfb 2>/dev/null' EXIT

# Prints "<seconds> <width> <height>" for the first video track of an MP4.
mp4_info() {
  python3 - "$1" <<'PY'
import struct
import sys

data = open(sys.argv[1], "rb").read()


def boxes(start, end):
    while start + 8 <= end:
        size, kind = struct.unpack(">I4s", data[start : start + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[start + 8 : start + 16])[0]
            header = 16
        elif size == 0:
            size = end - start
        if size < header:
            return
        yield kind, start + header, start + size
        start += size


seconds = width = height = None
for kind, body, end in boxes(0, len(data)):
    if kind != b"moov":
        continue
    for inner, inner_body, inner_end in boxes(body, end):
        if inner == b"mvhd":
            if data[inner_body] == 1:
                scale, duration = struct.unpack(">IQ", data[inner_body + 20 : inner_body + 32])
            else:
                scale, duration = struct.unpack(">II", data[inner_body + 12 : inner_body + 20])
            seconds = duration / scale if scale else None
        if inner == b"trak" and width is None:
            for track, track_body, _ in boxes(inner_body, inner_end):
                if track == b"tkhd":
                    offset = track_body + (88 if data[track_body] == 1 else 76)
                    w, h = struct.unpack(">II", data[offset : offset + 8])
                    if w and h:
                        width, height = w >> 16, h >> 16
if seconds is not None:
    print(f"{seconds:.2f} {width} {height}")
PY
}

# Prints "<width> <height>" of a PNG.
png_size() {
  python3 -c 'import struct, sys
data = open(sys.argv[1], "rb").read(24)
if data[:8] == b"\x89PNG\r\n\x1a\n":
    print(*struct.unpack(">II", data[16:24]))' "$1"
}

# launch <name> [KEY=VALUE...]: Cap in a fresh profile, logging to <name>/cap.log.
launch() {
  local name=$1; shift
  local profile=$out/$name
  mkdir -p "$profile/recordings" "$profile/logs"
  printf '%s' '{"general_settings":{"hasCompletedStartup":true,"hasCompletedOnboarding":true,"enableNotifications":false,"enableTelemetry":false,"recordingCountdown":0},"recording_start_safety":{"confirmBeforeRecordingWithoutMicrophone":false}}' >"$profile/store"
  env LD_LIBRARY_PATH="$libs" CAP_GPUI_APP_DATA_DIR="$profile" CAP_GPUI_RECORDINGS_DIR="$profile/recordings" \
    CAP_GPUI_LOG_DIR="$profile/logs" CAP_GPUI_NO_TRAY=1 CAP_GPUI_AUTO_NO_MIC=1 RUST_LOG=info "$@" \
    "$bin" >"$profile/cap.log" 2>&1 &
  echo $! >"$profile/pid"
}

wait_log() {
  local log=$1 pattern=$2 seconds=$3
  for _ in $(seq $((seconds * 4))); do
    grep -aq -- "$pattern" "$log" 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}

finish() {
  local name=$1 pid
  pid=$(cat "$out/$name/pid")
  result "${name}_cap_alive" "$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)"
  result "${name}_panics" "$(grep -ac 'panicked at' "$out/$name/cap.log")"
  kill "$pid" 2>/dev/null
  for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  kill -9 "$pid" 2>/dev/null
}

# record <name> <width> <height> <shortcut:yes|no> [KEY=VALUE...]
record() {
  local name=$1 want_width=$2 want_height=$3 shortcut=$4; shift 4
  local log=$out/$name/cap.log
  launch "$name" "$@"
  if [[ $shortcut == yes ]]; then
    wait_log "$log" "auto-record start requested" 30
    sleep 2
    xdotool key ctrl+shift+F9
  fi
  local started=no finished=no
  wait_log "$log" "recording started" 20 && started=yes
  if [[ $started == yes && $shortcut == yes ]]; then
    sleep 4
    xdotool key ctrl+shift+F9
  fi
  wait_log "$log" "recording finished" 60 && finished=yes
  sleep 2
  result "${name}_started" "$started"
  result "${name}_finished" "$finished"
  local project video info
  project=$(find "$out/$name/recordings" -maxdepth 1 -name "*.cap" | head -1)
  # A finish keeps its recovery workspace by design; the backup of the media
  # it replaced must be gone.
  result "${name}_backup_left" "$(find "$out/$name/recordings" -path '*/.recovery-*/original-segments' 2>/dev/null | wc -l)"
  video=$(find "${project:-/nonexistent}" -path "*segment-0/display.mp4" 2>/dev/null | head -1)
  info=$( [[ -n $video ]] && mp4_info "$video")
  echo "$name: ${video:-no display.mp4} ${info:-}" >>"$out/actions.log"
  read -r seconds width height <<<"${info:-0 0 0}"
  result "${name}_video" "$(awk -v s="$seconds" -v w="$width" -v h="$height" -v W="$want_width" -v H="$want_height" \
    'BEGIN { print (s >= 2 && w == W && h == H ? "yes" : "no") }')"
  finish "$name"
}

record display 1920 1080 yes CAP_GPUI_AUTO_RECORD=studio:60
record area 640 360 yes CAP_GPUI_AUTO_RECORD=studio:60 CAP_GPUI_AUTO_OVERLAY=area CAP_GPUI_AUTO_AREA=100,100,640,360
record window 480 270 no CAP_GPUI_AUTO_RECORD=studio:4 CAP_GPUI_AUTO_OVERLAY=window \
  CAP_GPUI_AUTO_WINDOW="Window to record"

# With no title to match, the picker's first window must be the other app's:
# Cap's own windows are not offered.
launch picker CAP_GPUI_AUTO_OVERLAY=window
wait_log "$out/picker/cap.log" "auto window target" 30
picked=$(sed 's/\x1b\[[0-9;]*m//g' "$out/picker/cap.log" | grep -a "auto window target" | head -1)
echo "picker: ${picked:-no window picked}" >>"$out/actions.log"
result picker_offers_other_app "$([[ $picked == *'title=Window to record'* ]] && echo yes || echo no)"
finish picker

launch screenshot CAP_GPUI_AUTO_RECORD=screenshot
shot=""
for _ in $(seq 80); do
  shot=$(find "$out/screenshot" -path "*.cap/original.png" 2>/dev/null | head -1)
  [[ -n $shot ]] && break
  sleep 0.25
done
sleep 1
size=$( [[ -n $shot ]] && png_size "$shot")
echo "screenshot: ${shot:-none} ${size:-}" >>"$out/actions.log"
result screenshot_png "$([[ $size == "1920 1080" ]] && echo yes || echo no)"
finish screenshot

cat "$out/result.txt"
failed=0
while IFS== read -r key value; do
  case $key in
    *_panics | *_backup_left) [[ $value == 0 ]] || failed=1 ;;
    *) [[ $value == yes ]] || failed=1 ;;
  esac
done <"$out/result.txt"
exit $failed
