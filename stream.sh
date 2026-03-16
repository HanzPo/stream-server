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
BROWSER_RESTART_HOURS="${BROWSER_RESTART_HOURS:-6}"

WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"
DISPLAY_NUM=99

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Suppress dbus errors
export DBUS_SESSION_BUS_ADDRESS=/dev/null

# --- PID file for Docker healthcheck ---
HEALTHY_FILE="/tmp/stream-healthy"

log "Starting virtual display ${RESOLUTION}..."
Xvfb ":${DISPLAY_NUM}" -screen 0 "${RESOLUTION}x24" -nocursor &
XVFB_PID=$!
sleep 2

# Verify Xvfb actually started
if ! kill -0 "$XVFB_PID" 2>/dev/null; then
  log "ERROR: Xvfb failed to start"
  exit 1
fi

export DISPLAY=":${DISPLAY_NUM}"

log "Starting window manager..."
openbox &
sleep 1

log "Hiding cursor..."
unclutter -idle 0 -root &

# --- Chromium launch as a function so we can restart it ---
launch_browser() {
  log "Launching Chromium at ${WEBPAGE_URL}..."
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
  BROWSER_STARTED=$(date +%s)

  log "Waiting for Chromium to load..."
  sleep 10

  # Force fullscreen
  xdotool search --onlyvisible --name "Chromium" windowactivate --sync windowfocus --sync key F11 2>/dev/null || true
  sleep 2
}

launch_browser

log "Starting FFmpeg stream to ${STREAM_URL%/*}/****..."

FFMPEG_PID=""
SHUTTING_DOWN=false

cleanup() {
  SHUTTING_DOWN=true
  log "Shutting down..."
  rm -f "$HEALTHY_FILE"
  kill "$FFMPEG_PID" "$BROWSER_PID" "$XVFB_PID" 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# --- Watchdog: monitors Chromium and restarts it if crashed or leaking ---
watchdog() {
  while [ "$SHUTTING_DOWN" = false ]; do
    sleep 30

    # Check if Chromium is still alive
    if ! kill -0 "$BROWSER_PID" 2>/dev/null; then
      log "WATCHDOG: Chromium crashed (PID $BROWSER_PID). Restarting..."
      launch_browser
      # Restart FFmpeg too since the display may have gone stale
      if [ -n "$FFMPEG_PID" ] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        kill "$FFMPEG_PID" 2>/dev/null || true
      fi
      continue
    fi

    # Periodic restart to combat Chromium memory leaks
    local now
    now=$(date +%s)
    local elapsed=$(( now - BROWSER_STARTED ))
    local max_seconds=$(( BROWSER_RESTART_HOURS * 3600 ))
    if [ "$elapsed" -ge "$max_seconds" ]; then
      log "WATCHDOG: Restarting Chromium after ${BROWSER_RESTART_HOURS}h to prevent memory leaks..."
      kill "$BROWSER_PID" 2>/dev/null || true
      sleep 2
      launch_browser
      if [ -n "$FFMPEG_PID" ] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        kill "$FFMPEG_PID" 2>/dev/null || true
      fi
    fi
  done
}
watchdog &
WATCHDOG_PID=$!

# --- Main FFmpeg loop ---
while true; do
  log "Starting FFmpeg stream..."

  ffmpeg -nostdin -loglevel warning \
    -probesize 10M -analyzeduration 10M \
    -thread_queue_size 512 \
    -f x11grab -video_size "${RESOLUTION}" -framerate "${FRAMERATE}" -i ":${DISPLAY_NUM}" \
    -f lavfi -i anullsrc=r=48000:cl=stereo \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -b:v "${VIDEO_BITRATE}" -maxrate "${VIDEO_BITRATE}" -bufsize "$((${VIDEO_BITRATE%k} * 2))k" \
    -pix_fmt yuv420p -g "$((FRAMERATE * 2))" -keyint_min "$((FRAMERATE * 2))" -sc_threshold 0 \
    -c:a aac -b:a 128k -ar 48000 \
    -f flv "${STREAM_URL}" &
  FFMPEG_PID=$!

  # Mark healthy once FFmpeg is running
  touch "$HEALTHY_FILE"

  wait "$FFMPEG_PID" || true

  rm -f "$HEALTHY_FILE"

  if [ "$SHUTTING_DOWN" = true ]; then
    break
  fi

  log "FFmpeg exited. Restarting in 5 seconds..."
  sleep 5
done

kill "$WATCHDOG_PID" 2>/dev/null || true
