#!/bin/bash

# Ensure the script is run as root
if[ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g., sudo bash install.sh)"
  exit 1
fi

echo "========================================"
echo "    o11 & Multiplexer Proxy Installer   "
echo "========================================"
echo ""

# 1. Ask user for inputs with defaults (Reading explicitly from /dev/tty to survive curl | bash)
read -p "Enter o11 backend port[default: 2086]: " O11_PORT < /dev/tty
O11_PORT=${O11_PORT:-2086}

read -p "Enter Multiplexer Proxy port[default: 8080]: " PROXY_PORT < /dev/tty
PROXY_PORT=${PROXY_PORT:-8080}

read -p "Enter Admin Username [default: admin]: " ADMIN_USER < /dev/tty
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Enter Admin Password [default: admin]: " ADMIN_PASS < /dev/tty
echo ""
ADMIN_PASS=${ADMIN_PASS:-admin}

# Hash the password in SHA-256
HASHED_PASS=$(echo -n "$ADMIN_PASS" | sha256sum | awk '{print $1}')

echo ""
echo "Installing dependencies (ffmpeg, unzip, nodejs)..."
sudo apt-get update
sudo apt-get install -y ffmpeg unzip nodejs npm

echo "Creating /home/o11 directory..."
mkdir -p /home/o11
cd /home/o11

echo "Downloading v3p.zip..."
wget -q --show-progress https://files.senator.dpdns.org/v3/v3p.zip

echo "Unzipping v3p.zip..."
unzip -o v3p.zip > /dev/null

echo "Changing permissions on v3p_launcher..."
chmod +x v3p_launcher

# 2. Create the configuration file (o11.cfg)
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

# 3. Create the Node.js proxy script
echo "Creating proxy.js..."
cat <<'EOF' > /home/o11/proxy.js
const http = require('http');
const { spawn } = require('child_process');

const PROXY_PORT = process.env.PROXY_PORT || 8080;
const O11_HOST = process.env.O11_HOST || "127.0.0.1:2086"; 

const activeStreams = new Map();

const server = http.createServer((req, res) => {
    if (req.url === '/favicon.ico') return res.end();

    let channelName = "";
    let targetM3u8 = "";

    try {
        const urlObj = new URL(req.url, `http://${req.headers.host}`);
        const pathParts = urlObj.pathname.split('/');
        
        if (pathParts.length === 3 && pathParts[2].endsWith('.ts')) {
            channelName = pathParts[2].replace('.ts', '');
            targetM3u8 = `http://${O11_HOST}/stream/${channelName}/tspls/master.m3u8${urlObj.search}`;
        } else {
            res.writeHead(404);
            return res.end('Invalid format.');
        }
    } catch (e) {
        res.writeHead(400);
        return res.end('Bad request');
    }

    res.writeHead(200, {
        'Content-Type': 'video/mp2t',
        'Connection': 'keep-alive',
        'Cache-Control': 'no-cache',
        'Access-Control-Allow-Origin': '*'
    });

    let streamState = activeStreams.get(channelName);

    if (!streamState) {
        console.log(`[?] First viewer for[${channelName}]. Waking up o11...`);

        const ffmpeg = spawn('ffmpeg',[
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
            ffmpeg: ffmpeg,
            clients: new Set()
        };
        activeStreams.set(channelName, streamState);

        ffmpeg.stdout.on('data', (chunk) => {
            for (const client of streamState.clients) {
                client.write(chunk);
            }
        });

        ffmpeg.stderr.on('data', (data) => {
            console.error(`[FFmpeg Error - ${channelName}]: ${data}`);
        });

        ffmpeg.on('close', () => {
            console.log(`[?] FFmpeg closed for [${channelName}].`);
            activeStreams.delete(channelName);
            for (const client of streamState.clients) {
                client.end();
            }
        });
    } else {
        console.log(`[+] Additional viewer joined[${channelName}]. Total: ${streamState.clients.size + 1}`);
    }

    streamState.clients.add(res);

    req.on('close', () => {
        if (streamState && streamState.clients.has(res)) {
            streamState.clients.delete(res);
            console.log(`[-] Viewer left[${channelName}]. Remaining: ${streamState.clients.size}`);

            if (streamState.clients.size === 0) {
                console.log(`[zzz] Room empty for [${channelName}]. Killing FFmpeg to let o11 sleep.`);
                streamState.ffmpeg.kill('SIGKILL');
                activeStreams.delete(channelName);
            }
        }
    });
});

const cleanupAndExit = () => {
    console.log(`\n[!] Shutting down proxy. Cleaning up FFmpeg processes...`);
    for (const [channel, state] of activeStreams.entries()) {
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

server.listen(PROXY_PORT, () => {
    console.log(`[?] MULTIPLEXER Proxy running on port ${PROXY_PORT}`);
    console.log(`[?] Forwarding requests to o11 backend on ${O11_HOST}`);
});
EOF

# 4. Create systemd services
echo "Creating systemd services..."

cat <<EOF | sudo tee /etc/systemd/system/o11.service > /dev/null
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

cat <<EOF | sudo tee /etc/systemd/system/o11-proxy.service > /dev/null[Unit]
Description=o11 Multiplexer Node Proxy
After=o11.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/home/o11
Environment="PROXY_PORT=${PROXY_PORT}"
Environment="O11_HOST=127.0.0.1:${O11_PORT}"
ExecStart=/usr/bin/node /home/o11/proxy.js
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 5. Start and Enable Services
echo "Reloading systemd and enabling services..."
sudo systemctl daemon-reload

sudo systemctl enable o11.service
sudo systemctl enable o11-proxy.service

sudo systemctl restart o11.service
sudo systemctl restart o11-proxy.service

echo ""
echo "=========================================================="
echo " Setup completed successfully!"
echo "=========================================================="
echo " o11 Backend is running on port:  ${O11_PORT}"
echo " Multiplexer Proxy is running on: ${PROXY_PORT}"
echo " Admin Username:                  ${ADMIN_USER}"
echo " Admin Password:                  (Hashed securely in /home/o11/o11.cfg)"
echo ""
echo " Check o11 status:    sudo systemctl status o11"
echo " Check Proxy status:  sudo systemctl status o11-proxy"
echo " View Proxy Logs:     sudo journalctl -u o11-proxy -f"
echo "=========================================================="
