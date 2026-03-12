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
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"

WIDTH="${RESOLUTION%x*}"
HEIGHT="${RESOLUTION#*x}"
DISPLAY_NUM=99

echo "Starting virtual display ${RESOLUTION}..."
Xvfb ":${DISPLAY_NUM}" -screen 0 "${RESOLUTION}x24" &
XVFB_PID=$!
sleep 2

export DISPLAY=":${DISPLAY_NUM}"

echo "Starting PulseAudio..."
pulseaudio -D --exit-idle-time=-1 2>/dev/null || true
sleep 1
pacmd load-module module-null-sink sink_name=virtual_speaker sink_properties=device.description=VirtualSpeaker 2>/dev/null || true
pacmd set-default-sink virtual_speaker 2>/dev/null || true
PULSE_SOURCE="virtual_speaker.monitor"

echo "Launching Chromium at ${WEBPAGE_URL}..."
chromium-browser \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --disable-software-rasterizer \
  --start-fullscreen \
  --kiosk \
  --autoplay-policy=no-user-gesture-required \
  --window-size="${WIDTH},${HEIGHT}" \
  --window-position=0,0 \
  "${WEBPAGE_URL}" &
BROWSER_PID=$!
sleep 5

echo "Starting FFmpeg stream to ${STREAM_URL%/*}/****..."

cleanup() {
  echo "Shutting down..."
  kill "$FFMPEG_PID" "$BROWSER_PID" "$XVFB_PID" 2>/dev/null || true
  pulseaudio --kill 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

ffmpeg \
  -f x11grab -video_size "${RESOLUTION}" -framerate "${FRAMERATE}" -i ":${DISPLAY_NUM}" \
  -f pulse -i "${PULSE_SOURCE}" \
  -c:v libx264 -preset veryfast -tune zerolatency -b:v "${VIDEO_BITRATE}" -maxrate "${VIDEO_BITRATE}" -bufsize "$((${VIDEO_BITRATE%k} * 2))k" \
  -pix_fmt yuv420p -g "$((FRAMERATE * 2))" \
  -c:a aac -b:a "${AUDIO_BITRATE}" -ar 44100 \
  -f flv "${STREAM_URL}" &
FFMPEG_PID=$!

wait "$FFMPEG_PID"
