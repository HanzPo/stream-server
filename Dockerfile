FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    ffmpeg \
    xvfb \
    pulseaudio \
    openbox \
    unclutter \
    xdotool \
    fonts-liberation \
    fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash streamer

WORKDIR /app
COPY stream.sh .
RUN chown -R streamer:streamer /app

USER streamer
CMD ["./stream.sh"]
