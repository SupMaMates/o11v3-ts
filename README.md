# O11V3-TS

Modified version of O11V3 with a lightweight TS proxy for IPTV clients that need direct `.ts`-style stream URLs instead of HLS playlist URLs.

## Features

* O11 backend service managed by systemd
* TS proxy service managed by systemd
* Direct TS URL shape:

```text
http://SERVER_IP:2400/stream/PROVIDER/CHANNEL?u=USERNAME&p=PASSWORD_HASH
```

* Backward compatible proxy route:

```text
http://SERVER_IP:2400/stream/PROVIDER/CHANNEL/master.ts?u=USERNAME&p=PASSWORD_HASH
```

* Reuses one FFmpeg process per active stream and shares it between viewers
* Remuxes O11 HLS to clean MPEG-TS without transcoding
* Regenerates timestamps and resends MPEG-TS headers for stricter restream panels
* Stops FFmpeg when the last viewer disconnects
* Health and status endpoints:

```text
http://SERVER_IP:2400/healthz
http://SERVER_IP:2400/status
```

## Installation

Run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/SupMaMates/o11v3-ts/refs/heads/main/install.sh -o /root/o11v3-ts-install.sh
bash /root/o11v3-ts-install.sh
```

The installer defaults to:

```text
O11 backend port: 2086
TS proxy port:   2400
Admin user:      szarkic
```

You can override settings non-interactively:

```bash
O11_PORT=2086 \
PROXY_PORT=2400 \
LISTEN_HOST=0.0.0.0 \
O11_UPSTREAM=127.0.0.1:2086 \
ADMIN_USER=szarkic \
ADMIN_PASS='your-password' \
FFMPEG_PROBESIZE=5000000 \
FFMPEG_ANALYZEDURATION=10000000 \
bash /root/o11v3-ts-install.sh
```

## URL Conversion

Original O11 HLS URL:

```text
http://SERVER_IP:2086/stream/magentaME/hrt2/master.m3u8?u=szarkic&p=HASH
```

TS proxy URL:

```text
http://SERVER_IP:2400/stream/magentaME/hrt2?u=szarkic&p=HASH
```

Rule:

```text
:2086/stream/PROVIDER/CHANNEL/master.m3u8?... -> :2400/stream/PROVIDER/CHANNEL?...
```

The proxy still pulls the O11 HLS playlist internally, then FFmpeg remuxes it into MPEG-TS with stream copy. It does not transcode video or audio.

Default remux settings are tuned for XUI-style TS ingest:

```text
Generate timestamps: yes
Preserve source timestamps: no
Probe size: 5000000
Analyze duration: 10000000
PAT/PMT resend: yes
Video extra data on keyframes: yes
```

## Service Commands

```bash
systemctl status o11 o11-proxy
journalctl -u o11 -f
journalctl -u o11-proxy -f
curl http://127.0.0.1:2400/healthz
curl http://127.0.0.1:2400/status
```

## Uninstallation

```bash
curl -fsSL https://raw.githubusercontent.com/SupMaMates/o11v3-ts/refs/heads/main/uninstall.sh -o /root/o11v3-ts-uninstall.sh
bash /root/o11v3-ts-uninstall.sh
```

For non-interactive removal:

```bash
FORCE=1 bash /root/o11v3-ts-uninstall.sh
```

## Disclaimer

This project is a modified version of O11V3 and is provided for educational and personal use only. Make sure you comply with all applicable laws and service provider terms when using IPTV services.
