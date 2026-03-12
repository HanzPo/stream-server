# stream-server

Stream a webpage to YouTube/Twitch 24/7 using a headless Chromium browser and FFmpeg.

## Setup

```bash
cp .env.example .env
# Edit .env with your webpage URL and stream key
```

## Run

```bash
docker compose up -d --build
```

## Logs

```bash
docker compose logs -f
```

## Stop

```bash
docker compose down
```
