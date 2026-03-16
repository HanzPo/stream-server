FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    ffmpeg \
    xvfb \
    openbox \
    unclutter \
    xdotool \
    procps \
    fonts-liberation \
    fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash streamer && \
    mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix && \
    mkdir -p /etc/chromium/policies/managed && \
    echo '{"CommandLineFlagSecurityWarningsEnabled": false}' > /etc/chromium/policies/managed/disable-warnings.json

WORKDIR /app
COPY stream.sh .
RUN chown -R streamer:streamer /app

USER streamer
CMD ["./stream.sh"]
