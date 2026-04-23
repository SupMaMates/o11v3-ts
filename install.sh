#!/usr/bin/env bash
set -euo pipefail

# Ensure script is run with bash
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Please run with bash: sudo bash install.sh"
  exit 1
fi

# Ensure script is run as root
if [ "${EUID}" -ne 0 ]; then
  echo "Please run as root (e.g., sudo bash install.sh)"
  exit 1
fi

# Ensure interactive terminal exists
if [ ! -r /dev/tty ]; then
  echo "No interactive terminal found. Run this script from a normal SSH terminal."
  exit 1
fi

prompt_default() {
  # $1=Label, $2=Default, $3=Output variable name
  local label="$1" def="$2" outvar="$3" value=""
  read -r -p "${label} [default: ${def}]: " value < /dev/tty
  value="${value:-$def}"
  printf -v "$outvar" '%s' "$value"
}

prompt_secret_default() {
  # $1=Label, $2=Default, $3=Output variable name
  local label="$1" def="$2" outvar="$3" value=""
  printf "%s [default: %s]: " "$label" "$def" > /dev/tty
  stty -echo < /dev/tty
  IFS= read -r value < /dev/tty
  stty echo < /dev/tty
  printf "\n" > /dev/tty
  value="${value:-$def}"
  printf -v "$outvar" '%s' "$value"
}

echo "========================================"
echo "    o11 & Multiplexer Proxy Installer   "
echo "========================================"
echo ""

# Prompts
prompt_default "Enter o11 backend port" "2086" O11_PORT
prompt_default "Enter Multiplexer Proxy listen port" "8080" PROXY_PORT
prompt_default "Enter Multiplexer Proxy listen host" "0.0.0.0" LISTEN_HOST
prompt_default "Enter upstream o11 host:port for proxy" "127.0.0.1:${O11_PORT}" O11_UPSTREAM
prompt_default "Enter Admin Username" "admin" ADMIN_USER
prompt_secret_default "Enter Admin Password" "admin" ADMIN_PASS

# Hash password
HASHED_PASS="$(printf '%s' "$ADMIN_PASS" | sha256sum | awk '{print $1}')"

echo ""
echo "Installing dependencies (ffmpeg, unzip, nodejs, npm)..."
apt-get update
apt-get install -y ffmpeg unzip nodejs npm

echo "Creating /home/o11 directory..."
mkdir -p /home/o11
cd /home/o11

echo "Downloading v3p.zip..."
wget -q --show-progress -O v3p.zip https://files.senator.dpdns.org/v3/v3p.zip

echo "Unzipping v3p.zip..."
unzip -o v3p.zip > /dev/null

echo "Changing permissions on v3p_launcher..."
chmod +x /home/o11/v3p_launcher

echo "Generating o11.cfg with your credentials..."
cat <<EOF > /home/o11/o11.cfg
{
    "EpgUrl": "",
    "Server": "",
    "Users":[
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

echo "Creating proxy.js..."
cat <<EOF > /home/o11/proxy.js
const http = require('http');
const { spawn } = require('child_process');

/*
  All runtime config is stored directly in this file
  (no Environment= values in systemd service).
*/
const PROXY_PORT = ${PROXY_PORT};
const LISTEN_HOST = '${LISTEN_HOST}';
const O11_HOST = '${O11_UPSTREAM}';

const activeStreams = new Map();

function buildTarget(reqUrl, hostHeader) {
  const urlObj = new URL(reqUrl, \`http://\${hostHeader}\`);
  const path = urlObj.pathname;

  // New format:
  // /stream/<provider>/<channel>/master.ts?...
  const newFmt = path.match(/^\\/stream\\/([^/]+)\\/([^/]+)\\/master\\.ts$/);
  if (newFmt) {
    const provider = newFmt[1];
    const channel = newFmt[2];
    const key = \`stream/\${provider}/\${channel}\`;
    const targetM3u8 = \`http://\${O11_HOST}/stream/\${provider}/\${channel}/master.m3u8\${urlObj.search}\`;
    return { key, targetM3u8 };
  }

  // Old format (backward compatibility):
  // /<anything>/<channel>.ts?...
  const oldFmt = path.match(/^\\/[^/]+\\/([^/]+)\\.ts$/);
  if (oldFmt) {
    const channelName = oldFmt[1];
    const key = \`legacy/\${channelName}\`;
    const targetM3u8 = \`http://\${O11_HOST}/stream/\${channelName}/tspls/master.m3u8\${urlObj.search}\`;
    return { key, targetM3u8 };
  }

  return null;
}

const server = http.createServer((req, res) => {
  if (req.url === '/favicon.ico') return res.end();

  let streamKey = '';
  let targetM3u8 = '';

  try {
    const parsed = buildTarget(req.url, req.headers.host);
    if (!parsed) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      return res.end('Invalid format. Use /stream/<provider>/<channel>/master.ts?...');
    }
    streamKey = parsed.key;
    targetM3u8 = parsed.targetM3u8;
  } catch (e) {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    return res.end('Bad request');
  }

  res.writeHead(200, {
    'Content-Type': 'video/mp2t',
    'Connection': 'keep-alive',
    'Cache-Control': 'no-cache',
    'Access-Control-Allow-Origin': '*'
  });

  let streamState = activeStreams.get(streamKey);

  if (!streamState) {
    console.log(\`[?] First viewer for [\${streamKey}]. Waking up o11...\`);

    const ffmpeg = spawn('ffmpeg', [
      '-hide_banner', '-loglevel', 'error',
      '-reconnect', '1',
      '-reconnect_streamed', '1',
      '-reconnect_delay_max', '5',
      '-http_persistent', '0',
      '-timeout', '10000000',
      '-i', targetM3u8,
      '-c', 'copy',
      '-copyts',
      '-f', 'mpegts',
      'pipe:1'
    ]);

    streamState = {
      ffmpeg,
      clients: new Set()
    };
    activeStreams.set(streamKey, streamState);

    ffmpeg.stdout.on('data', (chunk) => {
      for (const client of streamState.clients) {
        client.write(chunk);
      }
    });

    ffmpeg.stderr.on('data', (data) => {
      console.error(\`[FFmpeg Error - \${streamKey}]: \${data}\`);
    });

    ffmpeg.on('close', () => {
      console.log(\`[?] FFmpeg closed for [\${streamKey}].\`);
      activeStreams.delete(streamKey);
      for (const client of streamState.clients) {
        client.end();
      }
    });
  } else {
    console.log(\`[+] Additional viewer joined [\${streamKey}]. Total: \${streamState.clients.size + 1}\`);
  }

  streamState.clients.add(res);

  req.on('close', () => {
    if (streamState && streamState.clients.has(res)) {
      streamState.clients.delete(res);
      console.log(\`[-] Viewer left [\${streamKey}]. Remaining: \${streamState.clients.size}\`);

      if (streamState.clients.size === 0) {
        console.log(\`[zzz] Room empty for [\${streamKey}]. Killing FFmpeg to let o11 sleep.\`);
        streamState.ffmpeg.kill('SIGKILL');
        activeStreams.delete(streamKey);
      }
    }
  });
});

const cleanupAndExit = () => {
  console.log('\\n[!] Shutting down proxy. Cleaning up FFmpeg processes...');
  for (const [, state] of activeStreams.entries()) {
    state.ffmpeg.kill('SIGKILL');
  }
  process.exit(0);
};

process.on('SIGINT', cleanupAndExit);
process.on('SIGTERM', cleanupAndExit);
process.on('uncaughtException', (err) => {
  console.error('Uncaught Exception:', err);
  cleanupAndExit();
});

server.listen(PROXY_PORT, LISTEN_HOST, () => {
  console.log(\`[?] MULTIPLEXER Proxy running on \${LISTEN_HOST}:\${PROXY_PORT}\`);
  console.log(\`[?] Forwarding requests to o11 backend on \${O11_HOST}\`);
});
EOF

echo "Creating systemd services..."

cat <<EOF > /etc/systemd/system/o11.service
[Unit]
Description=o11 Backend Service
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/home/o11
ExecStart=/home/o11/v3p_launcher -p ${O11_PORT} -noramfs
KillMode=control-group
Restart=on-failure
RestartSec=3
TasksMax=infinity
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/o11-proxy.service
[Unit]
Description=o11 Multiplexer Node Proxy
After=o11.service
Requires=o11.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/home/o11
ExecStart=/usr/bin/node /home/o11/proxy.js
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd and enabling services..."
systemctl daemon-reload
systemctl enable o11.service o11-proxy.service
systemctl restart o11.service o11-proxy.service

echo ""
echo "=========================================================="
echo " Setup completed successfully!"
echo "=========================================================="
echo " o11 Backend port:                 ${O11_PORT}"
echo " Proxy listen:                     ${LISTEN_HOST}:${PROXY_PORT}"
echo " Proxy upstream o11 target:        ${O11_UPSTREAM}"
echo " Admin Username:                   ${ADMIN_USER}"
echo " Admin Password:                   (Hashed in /home/o11/o11.cfg)"
echo ""
echo " Check o11 status:    sudo systemctl status o11"
echo " Check Proxy status:  sudo systemctl status o11-proxy"
echo " View Proxy Logs:     sudo journalctl -u o11-proxy -f"
echo "=========================================================="
