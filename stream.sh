#!/usr/bin/env bash
set -euo pipefail

# Load .env file if present (not needed when running via Docker)
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

# Validate required vars
if [ -z "${WEBPAGE_URL:-}" ] || [ -z "${STREAM_URL:-}" ]; then
  echo "ERROR: WEBPAGE_URL and STREAM_URL must be set. Copy .env.example to .env and fill in your values."
  exit 1
fi

# Defaults
RESOLUTION="${RESOLUTION:-1920x1080}"
FRAMERATE="${FRAMERATE:-30}"
VIDEO_BITRATE="${VIDEO_BITRATE:-4500k}"

WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"
DISPLAY_NUM=99

# Suppress dbus errors
export DBUS_SESSION_BUS_ADDRESS=/dev/null

echo "Starting virtual display ${RESOLUTION}..."
Xvfb ":${DISPLAY_NUM}" -screen 0 "${RESOLUTION}x24" -nocursor &
XVFB_PID=$!
sleep 2

export DISPLAY=":${DISPLAY_NUM}"

echo "Starting window manager..."
openbox &
sleep 1

echo "Hiding cursor..."
unclutter -idle 0 -root &

echo "Launching Chromium at ${WEBPAGE_URL}..."
chromium \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --disable-software-rasterizer \
  --disable-extensions \
  --disable-background-networking \
  --disable-default-apps \
  --disable-component-update \
  --disable-breakpad \
  --disable-features=GCMDriver,dbus,Translate \
  --no-first-run \
  --no-default-browser-check \
  --noerrdialogs \
  --mute-audio \
  --js-flags="--max-old-space-size=512" \
  --autoplay-policy=no-user-gesture-required \
  --window-size="${WIDTH},${HEIGHT}" \
  --window-position=0,0 \
  "${WEBPAGE_URL}" &
BROWSER_PID=$!

echo "Waiting for Chromium to load..."
sleep 10

# Force the browser window to fullscreen
xdotool search --onlyvisible --name "Chromium" windowactivate --sync windowfocus --sync key F11 2>/dev/null || true
sleep 2

echo "Starting FFmpeg stream to ${STREAM_URL%/*}/****..."

cleanup() {
  echo "Shutting down..."
  kill "$FFMPEG_PID" "$BROWSER_PID" "$XVFB_PID" 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

ffmpeg \
  -probesize 10M -analyzeduration 10M \
  -thread_queue_size 512 \
  -f x11grab -video_size "${RESOLUTION}" -framerate "${FRAMERATE}" -i ":${DISPLAY_NUM}" \
  -f lavfi -i anullsrc=r=48000:cl=stereo \
  -c:v libx264 -preset veryfast -tune zerolatency \
  -b:v "${VIDEO_BITRATE}" -maxrate "${VIDEO_BITRATE}" -bufsize "$((${VIDEO_BITRATE%k} * 2))k" \
  -pix_fmt yuv420p -g "$((FRAMERATE * 2))" -keyint_min "$((FRAMERATE * 2))" -sc_threshold 0 \
  -c:a aac -b:a 128k -ar 48000 \
  -shortest \
  -f flv "${STREAM_URL}" &
FFMPEG_PID=$!

wait "$FFMPEG_PID"
