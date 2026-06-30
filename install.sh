#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Install failed at line ${LINENO}." >&2' ERR

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Please run with bash: sudo bash install.sh" >&2
  exit 1
fi

if [ "${EUID}" -ne 0 ]; then
  echo "Please run as root, for example: sudo bash install.sh" >&2
  exit 1
fi

APP_DIR="${APP_DIR:-/home/o11}"
CONFIG_DIR="${CONFIG_DIR:-/etc/o11v3-ts}"
RUN_USER="${RUN_USER:-o11}"
RUN_GROUP="${RUN_GROUP:-o11}"
V3P_URL="${V3P_URL:-https://github.com/SupMaMates/o11v3-ts/releases/download/main/v3p.zip}"
V3P_ZIP_SHA256="${V3P_ZIP_SHA256:-}"
MAX_CLIENTS="${MAX_CLIENTS:-0}"
CLIENT_BUFFER_LIMIT="${CLIENT_BUFFER_LIMIT:-8388608}"
FFMPEG_LOGLEVEL="${FFMPEG_LOGLEVEL:-warning}"
FFMPEG_PROBESIZE="${FFMPEG_PROBESIZE:-5000000}"
FFMPEG_ANALYZEDURATION="${FFMPEG_ANALYZEDURATION:-10000000}"
FFMPEG_RW_TIMEOUT="${FFMPEG_RW_TIMEOUT:-10000000}"

has_tty() {
  [ -r /dev/tty ] && [ -w /dev/tty ] && { : < /dev/tty; } 2>/dev/null
}

prompt_default() {
  local label="$1" def="$2" outvar="$3" value="${!3:-}"
  if [ -z "$value" ] && has_tty; then
    read -r -p "${label} [default: ${def}]: " value < /dev/tty
  fi
  value="${value:-$def}"
  printf -v "$outvar" '%s' "$value"
}

prompt_secret_default() {
  local label="$1" def="$2" outvar="$3" value="${!3:-}"
  if [ -z "$value" ] && has_tty; then
    printf "%s [default: %s]: " "$label" "$def" > /dev/tty
    stty -echo < /dev/tty
    IFS= read -r value < /dev/tty
    stty echo < /dev/tty
    printf "\n" > /dev/tty
  fi
  value="${value:-$def}"
  printf -v "$outvar" '%s' "$value"
}

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

backup_file() {
  local file="$1" stamp="$2"
  if [ -e "$file" ]; then
    cp -a "$file" "${file}.bak.${stamp}"
  fi
}

port_in_use() {
  local port="$1"
  ss -ltn "sport = :${port}" 2>/dev/null | awk 'NR > 1 {found=1} END {exit !found}'
}

echo "========================================"
echo "      o11v3-ts simple installer"
echo "========================================"
echo ""

prompt_default "Enter o11 backend port" "2086" O11_PORT
prompt_default "Enter Multiplexer Proxy listen port" "2400" PROXY_PORT
prompt_default "Enter Multiplexer Proxy listen host" "0.0.0.0" LISTEN_HOST
prompt_default "Enter upstream o11 host:port for proxy" "127.0.0.1:${O11_PORT}" O11_UPSTREAM
prompt_default "Enter Admin Username" "szarkic" ADMIN_USER
prompt_secret_default "Enter Admin Password" "l-J4iWYtnU%3a1.2l9p" ADMIN_PASS

if ! is_port "$O11_PORT"; then
  echo "Invalid O11_PORT: ${O11_PORT}" >&2
  exit 1
fi

if ! is_port "$PROXY_PORT"; then
  echo "Invalid PROXY_PORT: ${PROXY_PORT}" >&2
  exit 1
fi

if [ "$O11_PORT" = "$PROXY_PORT" ]; then
  echo "O11_PORT and PROXY_PORT must be different." >&2
  exit 1
fi

if ! [[ "$ADMIN_USER" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
  echo "Admin username may only contain letters, numbers, dot, underscore, at, and dash." >&2
  exit 1
fi

HASHED_PASS="$(printf '%s' "$ADMIN_PASS" | sha256sum | awk '{print $1}')"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "Stopping existing services if present..."
systemctl stop o11-proxy.service 2>/dev/null || true
systemctl stop o11.service 2>/dev/null || true

if port_in_use "$O11_PORT"; then
  echo "Port ${O11_PORT} is already listening. Pick another O11_PORT or stop that service." >&2
  exit 1
fi

if port_in_use "$PROXY_PORT"; then
  echo "Port ${PROXY_PORT} is already listening. Pick another PROXY_PORT or stop that service." >&2
  exit 1
fi

echo "Installing dependencies..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl ffmpeg unzip nodejs

echo "Creating runtime user and directories..."
if ! getent group "$RUN_GROUP" >/dev/null 2>&1; then
  groupadd --system "$RUN_GROUP"
fi

if ! id -u "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --gid "$RUN_GROUP" --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$RUN_USER"
fi

install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 0750 "$APP_DIR"
install -d -m 0755 "$CONFIG_DIR"

backup_file "${APP_DIR}/o11.cfg" "$STAMP"
backup_file "${APP_DIR}/proxy.js" "$STAMP"
backup_file "${CONFIG_DIR}/o11.env" "$STAMP"
backup_file "${CONFIG_DIR}/proxy.env" "$STAMP"
backup_file "/etc/systemd/system/o11.service" "$STAMP"
backup_file "/etc/systemd/system/o11-proxy.service" "$STAMP"

echo "Downloading v3p.zip..."
curl -fL --retry 3 --retry-delay 2 -o "${APP_DIR}/v3p.zip" "$V3P_URL"

if [ -n "$V3P_ZIP_SHA256" ]; then
  echo "${V3P_ZIP_SHA256}  ${APP_DIR}/v3p.zip" | sha256sum -c -
else
  echo "Warning: V3P_ZIP_SHA256 was not set, so the release zip was not checksum-verified."
fi

echo "Unpacking release..."
unzip -o "${APP_DIR}/v3p.zip" -d "$APP_DIR" >/dev/null
chmod 0750 "${APP_DIR}/v3p_launcher"

echo "Writing o11 config..."
cat > "${APP_DIR}/o11.cfg" <<EOF
{
  "EpgUrl": "",
  "Server": "",
  "Users": [
    {
      "Username": "${ADMIN_USER}",
      "Password": "${HASHED_PASS}",
      "Network": "",
      "IsAdmin": true,
      "HasWebAccess": true,
      "ProviderIds": []
    }
  ]
}
EOF

chmod 0640 "${APP_DIR}/o11.cfg"

echo "Writing environment files..."
cat > "${CONFIG_DIR}/o11.env" <<EOF
O11_PORT=${O11_PORT}
EOF

cat > "${CONFIG_DIR}/proxy.env" <<EOF
PROXY_PORT=${PROXY_PORT}
LISTEN_HOST=${LISTEN_HOST}
O11_HOST=${O11_UPSTREAM}
MAX_CLIENTS=${MAX_CLIENTS}
CLIENT_BUFFER_LIMIT=${CLIENT_BUFFER_LIMIT}
FFMPEG_LOGLEVEL=${FFMPEG_LOGLEVEL}
FFMPEG_PROBESIZE=${FFMPEG_PROBESIZE}
FFMPEG_ANALYZEDURATION=${FFMPEG_ANALYZEDURATION}
FFMPEG_RW_TIMEOUT=${FFMPEG_RW_TIMEOUT}
EOF

chmod 0644 "${CONFIG_DIR}/o11.env" "${CONFIG_DIR}/proxy.env"

echo "Writing proxy.js..."
cat > "${APP_DIR}/proxy.js" <<'EOF'
'use strict';

const http = require('http');
const { spawn } = require('child_process');

const PROXY_PORT = parseInt(process.env.PROXY_PORT || '8080', 10);
const LISTEN_HOST = process.env.LISTEN_HOST || '0.0.0.0';
const O11_HOST = process.env.O11_HOST || '127.0.0.1:2086';
const MAX_CLIENTS = parseInt(process.env.MAX_CLIENTS || '0', 10);
const CLIENT_BUFFER_LIMIT = parseInt(process.env.CLIENT_BUFFER_LIMIT || '8388608', 10);
const FFMPEG_LOGLEVEL = process.env.FFMPEG_LOGLEVEL || 'warning';
const FFMPEG_PROBESIZE = process.env.FFMPEG_PROBESIZE || '5000000';
const FFMPEG_ANALYZEDURATION = process.env.FFMPEG_ANALYZEDURATION || '10000000';
const FFMPEG_RW_TIMEOUT = process.env.FFMPEG_RW_TIMEOUT || '10000000';

const activeStreams = new Map();

function sendText(res, status, text) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(text);
}

function sendJson(res, status, data) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(JSON.stringify(data, null, 2));
}

function buildTarget(reqUrl, hostHeader) {
  const urlObj = new URL(reqUrl, `http://${hostHeader || 'localhost'}`);
  const path = urlObj.pathname;

  const directTsFmt = path.match(/^\/stream\/([^/]+)\/([^/]+)$/);
  if (directTsFmt) {
    const provider = directTsFmt[1];
    const channel = directTsFmt[2];
    return {
      key: `stream/${provider}/${channel}`,
      targetM3u8: `http://${O11_HOST}/stream/${provider}/${channel}/master.m3u8${urlObj.search}`
    };
  }

  const newFmt = path.match(/^\/stream\/([^/]+)\/([^/]+)\/master\.ts$/);
  if (newFmt) {
    const provider = newFmt[1];
    const channel = newFmt[2];
    return {
      key: `stream/${provider}/${channel}`,
      targetM3u8: `http://${O11_HOST}/stream/${provider}/${channel}/master.m3u8${urlObj.search}`
    };
  }

  const oldFmt = path.match(/^\/[^/]+\/([^/]+)\.ts$/);
  if (oldFmt) {
    const channel = oldFmt[1];
    return {
      key: `legacy/${channel}`,
      targetM3u8: `http://${O11_HOST}/stream/${channel}/tspls/master.m3u8${urlObj.search}`
    };
  }

  return null;
}

function publicStatus() {
  return {
    ok: true,
    proxyPort: PROXY_PORT,
    listenHost: LISTEN_HOST,
    upstream: O11_HOST,
    remux: 'o11-hls-to-clean-mpegts',
    activeStreams: [...activeStreams.entries()].map(([key, state]) => ({
      key,
      clients: state.clients.size,
      ffmpegPid: state.ffmpeg.pid || null,
      uptimeSeconds: Math.round((Date.now() - state.startedAt) / 1000),
      stopping: state.stopping
    }))
  };
}

function stopStream(key, state, reason) {
  if (!state || state.stopping) return;
  state.stopping = true;
  activeStreams.delete(key);
  console.log(`[stop] ${key}: ${reason}`);

  if (state.ffmpeg && !state.ffmpeg.killed) {
    state.ffmpeg.kill('SIGTERM');
    const killer = setTimeout(() => {
      if (state.ffmpeg && !state.ffmpeg.killed) {
        state.ffmpeg.kill('SIGKILL');
      }
    }, 2500);
    killer.unref();
  }
}

function removeClient(key, state, client, reason) {
  if (!state.clients.has(client)) return;
  state.clients.delete(client);
  console.log(`[-] Viewer left [${key}] (${reason}). Remaining: ${state.clients.size}`);

  if (!client.destroyed && !client.writableEnded) {
    try {
      client.end();
    } catch (_) {
      client.destroy();
    }
  }

  if (state.clients.size === 0) {
    stopStream(key, state, 'no viewers');
  }
}

function createStream(key, targetM3u8) {
  console.log(`[start] First viewer for [${key}]. Starting ffmpeg.`);

  const ffmpeg = spawn('ffmpeg', [
    '-nostdin',
    '-hide_banner',
    '-loglevel', FFMPEG_LOGLEVEL,
    '-fflags', '+genpts+discardcorrupt',
    '-reconnect', '1',
    '-reconnect_streamed', '1',
    '-reconnect_delay_max', '5',
    '-http_persistent', '0',
    '-rw_timeout', FFMPEG_RW_TIMEOUT,
    '-timeout', FFMPEG_RW_TIMEOUT,
    '-probesize', FFMPEG_PROBESIZE,
    '-analyzeduration', FFMPEG_ANALYZEDURATION,
    '-i', targetM3u8,
    '-map', '0:v:0',
    '-map', '0:a?',
    '-sn',
    '-dn',
    '-c', 'copy',
    '-bsf:v', 'dump_extra=freq=keyframe',
    '-mpegts_flags', '+resend_headers',
    '-pat_period', '0.05',
    '-sdt_period', '0.5',
    '-avoid_negative_ts', 'make_zero',
    '-muxdelay', '0',
    '-muxpreload', '0',
    '-flush_packets', '1',
    '-f', 'mpegts',
    'pipe:1'
  ], {
    stdio: ['ignore', 'pipe', 'pipe']
  });

  const state = {
    ffmpeg,
    clients: new Set(),
    startedAt: Date.now(),
    stopping: false
  };

  activeStreams.set(key, state);

  ffmpeg.stdout.on('data', (chunk) => {
    for (const client of [...state.clients]) {
      if (client.destroyed || client.writableEnded) {
        state.clients.delete(client);
        continue;
      }

      if (CLIENT_BUFFER_LIMIT > 0 && client.writableLength > CLIENT_BUFFER_LIMIT) {
        console.warn(`[drop] Slow client on [${key}] exceeded buffer limit.`);
        client.destroy();
        state.clients.delete(client);
        continue;
      }

      client.write(chunk);
    }

    if (state.clients.size === 0) {
      stopStream(key, state, 'all clients gone');
    }
  });

  ffmpeg.stderr.on('data', (data) => {
    let message = data.toString().trim();
    message = message.replace(/([?&][up]=)[^&\s]+/g, '$1REDACTED');
    if (message) console.error(`[ffmpeg:${key}] ${message}`);
  });

  ffmpeg.on('error', (err) => {
    console.error(`[ffmpeg:${key}] spawn failed: ${err.message}`);
    for (const client of [...state.clients]) {
      sendText(client, 502, 'FFmpeg failed to start\n');
    }
    state.clients.clear();
    activeStreams.delete(key);
  });

  ffmpeg.on('close', (code, signal) => {
    console.log(`[close] FFmpeg closed for [${key}] code=${code} signal=${signal || ''}`);
    activeStreams.delete(key);
    for (const client of [...state.clients]) {
      if (!client.destroyed && !client.writableEnded) {
        client.end();
      }
    }
    state.clients.clear();
  });

  return state;
}

const server = http.createServer((req, res) => {
  if (req.url === '/favicon.ico') {
    res.writeHead(204);
    return res.end();
  }

  if (req.method === 'GET' && req.url === '/healthz') {
    return sendText(res, 200, 'ok\n');
  }

  if (req.method === 'GET' && req.url === '/status') {
    return sendJson(res, 200, publicStatus());
  }

  if (req.method !== 'GET') {
    return sendText(res, 405, 'Method not allowed\n');
  }

  const parsed = buildTarget(req.url, req.headers.host);
  if (!parsed) {
    return sendText(res, 404, 'Invalid format. Use /stream/<provider>/<channel>?u=...&p=...\n');
  }

  const { key, targetM3u8 } = parsed;
  let streamState = activeStreams.get(key);

  if (streamState && streamState.stopping) {
    activeStreams.delete(key);
    streamState = null;
  }

  if (!streamState) {
    streamState = createStream(key, targetM3u8);
  }

  if (MAX_CLIENTS > 0 && streamState.clients.size >= MAX_CLIENTS) {
    return sendText(res, 503, 'Too many clients for this stream\n');
  }

  res.writeHead(200, {
    'Content-Type': 'video/mp2t',
    'Connection': 'keep-alive',
    'Cache-Control': 'no-cache, no-store',
    'Access-Control-Allow-Origin': '*',
    'X-Accel-Buffering': 'no'
  });

  streamState.clients.add(res);
  console.log(`[+] Viewer joined [${key}]. Total: ${streamState.clients.size}`);

  req.on('close', () => removeClient(key, streamState, res, 'request closed'));
  req.on('aborted', () => removeClient(key, streamState, res, 'request aborted'));
  res.on('error', () => removeClient(key, streamState, res, 'response error'));
});

server.keepAliveTimeout = 65000;
server.headersTimeout = 70000;
server.requestTimeout = 0;

function shutdown() {
  console.log('[shutdown] Stopping proxy and child ffmpeg processes.');
  server.close(() => process.exit(0));
  for (const [key, state] of activeStreams.entries()) {
    stopStream(key, state, 'proxy shutdown');
  }
  setTimeout(() => process.exit(0), 3000).unref();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.on('uncaughtException', (err) => {
  console.error('Uncaught exception:', err);
  shutdown();
});
process.on('unhandledRejection', (err) => {
  console.error('Unhandled rejection:', err);
  shutdown();
});

server.listen(PROXY_PORT, LISTEN_HOST, () => {
  console.log(`[ready] o11v3-ts proxy listening on ${LISTEN_HOST}:${PROXY_PORT}`);
  console.log(`[ready] Upstream O11 backend: ${O11_HOST}`);
});
EOF

echo "Writing systemd services..."
cat > /etc/systemd/system/o11.service <<EOF
[Unit]
Description=o11 Backend Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${CONFIG_DIR}/o11.env
ExecStart=/bin/sh -lc 'exec ${APP_DIR}/v3p_launcher -p "\$O11_PORT" -noramfs'
KillMode=control-group
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/o11-proxy.service <<EOF
[Unit]
Description=o11v3-ts Multiplexer Proxy
After=o11.service
Requires=o11.service

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${CONFIG_DIR}/proxy.env
ExecStart=/usr/bin/node ${APP_DIR}/proxy.js
KillMode=control-group
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF

chown -R "${RUN_USER}:${RUN_GROUP}" "$APP_DIR"

echo "Starting services..."
systemctl daemon-reload
systemctl enable o11.service o11-proxy.service
systemctl restart o11.service
systemctl restart o11-proxy.service

echo ""
echo "=========================================================="
echo "Setup completed successfully."
echo "=========================================================="
echo "O11 backend:        http://127.0.0.1:${O11_PORT}"
echo "Proxy listen:       http://${LISTEN_HOST}:${PROXY_PORT}"
echo "Proxy health:       http://${LISTEN_HOST}:${PROXY_PORT}/healthz"
echo "Proxy status:       http://${LISTEN_HOST}:${PROXY_PORT}/status"
echo "Admin username:     ${ADMIN_USER}"
echo "Admin password:     hashed in ${APP_DIR}/o11.cfg"
echo ""
echo "Check O11:          systemctl status o11"
echo "Check proxy:        systemctl status o11-proxy"
echo "Proxy logs:         journalctl -u o11-proxy -f"
echo "=========================================================="
