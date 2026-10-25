#!/usr/bin/env bash
# Exporting from the editor: record a Studio clip, open it in the editor and
# export it to a file (CAP_GPUI_AUTO_EXPORT), once as MP4 and once as GIF,
# then check each file holds the clip. Prints key=value results to
# $HARNESS_OUT/result.txt.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
out=${HARNESS_OUT:-/out}

bash "$here/scenario-start-stop.sh" >/dev/null
recorded=$(sed -n 's/^attempt1_finished=//p' "$out/result.txt")
mv "$out/result.txt" "$out/recording-result.txt"
: >"$out/result.txt"
result() { printf '%s=%s\n' "$1" "$2" >>"$out/result.txt"; }
result recorded "${recorded:-no}"
[[ $recorded == yes ]] || exit 0

eval "$(systemctl --user show-environment | grep -E "^(WAYLAND_DISPLAY|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP|XDG_SESSION_DESKTOP|LIBGL_ALWAYS_SOFTWARE|HYPRLAND_INSTANCE_SIGNATURE|NIRI_SOCKET)=" | sed 's/^/export /')"

# Prints the seconds of video an MP4's movie header declares, or nothing.
mp4_seconds() {
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


for kind, body, end in boxes(0, len(data)):
    if kind != b"moov":
        continue
    for inner, inner_body, _ in boxes(body, end):
        if inner == b"mvhd":
            version = data[inner_body]
            if version == 1:
                scale, duration = struct.unpack(">IQ", data[inner_body + 20 : inner_body + 32])
            else:
                scale, duration = struct.unpack(">II", data[inner_body + 12 : inner_body + 20])
            if scale:
                print(f"{duration / scale:.2f}")
PY
}

# Prints a GIF's frame count and the seconds its frame delays add up to (the
# encoder merges identical frames into longer ones), or nothing.
gif_frames_and_seconds() {
  python3 - "$1" <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
if data[:6] in (b"GIF87a", b"GIF89a"):
    frames, centiseconds, at = 0, 0, data.find(b"\x21\xf9\x04")
    while at != -1 and at + 6 <= len(data):
        frames += 1
        centiseconds += data[at + 4] | data[at + 5] << 8
        at = data.find(b"\x21\xf9\x04", at + 8)
    print(frames, f"{centiseconds / 100:.2f}")
PY
}

export_once() {
  local kind=$1 file=$out/export.$1 name=cap-$1
  bash "$here/launch-cap.sh" "$name" CAP_GPUI_AUTO_EDITOR=1 CAP_GPUI_AUTO_EXPORT="$file" >/dev/null
  local done=""
  for _ in $(seq 720); do
    done=$(sed 's/\x1b\[[0-9;]*m//g' "$out/$name.log" 2>/dev/null |
      grep -aoE "editor export completed|editor export failed.*|panicked at.*" | head -1)
    [[ -n $done ]] && break
    sleep 0.25
  done
  echo "$kind: ${done:-no export line}" >>"$out/actions.log"
  result "${kind}_exported" "$([[ $done == "editor export completed" ]] && echo yes || echo no)"
  if [[ $kind == mp4 ]]; then
    local seconds
    seconds=$(mp4_seconds "$file" 2>/dev/null)
    echo "mp4 seconds: ${seconds:-none}, bytes: $(stat -c %s "$file" 2>/dev/null)" >>"$out/actions.log"
    result mp4_has_video "$(awk -v s="${seconds:-0}" 'BEGIN { print (s >= 1 ? "yes" : "no") }')"
  else
    local frames seconds
    read -r frames seconds < <(gif_frames_and_seconds "$file" 2>/dev/null)
    echo "gif frames: ${frames:-none}, seconds: ${seconds:-none}, bytes: $(stat -c %s "$file" 2>/dev/null)" >>"$out/actions.log"
    result gif_has_video "$(awk -v s="${seconds:-0}" 'BEGIN { print (s >= 1 ? "yes" : "no") }')"
  fi
  result "${kind}_cap_alive" "$(kill -0 "$(cat "$XDG_RUNTIME_DIR/$name.pid" 2>/dev/null)" 2>/dev/null && echo yes || echo no)"
  kill "$(cat "$XDG_RUNTIME_DIR/$name.pid" 2>/dev/null)" 2>/dev/null
  sleep 2
}

export_once mp4
export_once gif
cat "$out/result.txt"
