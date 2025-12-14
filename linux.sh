#!/bin/bash

SATNET_DIR="/opt/satnet"
SERVICE_NAME="satnet"
ID_FILE="$SATNET_DIR/satnet.id"
STATS_FILE="$SATNET_DIR/stats.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo).${NC}"
  exit 1
fi

clear
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}      Welcome to the Satnet Installer    ${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo ""
echo "By installing this software, you agree to share your internet bandwidth"
echo "to participate in the Satnet P2P network."
echo ""
echo "Terms & Conditions:"
echo "1. You authorize this device to act as a proxy node."
echo "2. We are not responsible for traffic passed through your node."
echo "3. You may uninstall at any time using 'satnet-uninstall'."
echo ""

read -p "Do you accept these terms? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Installation aborted.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Starting installation...${NC}"

if ! command -v node &> /dev/null; then
    echo "Node.js not found. Installing..."
    if [ -f /etc/debian_version ]; then
        curl -fsSL https://deb.nodesource.com/setup_24.x | bash - > /dev/null 2>&1
        apt-get install -y nodejs > /dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        curl -fsSL https://rpm.nodesource.com/setup_24.x | bash - > /dev/null 2>&1
        yum install -y nodejs > /dev/null 2>&1
    else
        echo -e "${RED}Unsupported OS. Please install Node.js manually.${NC}"
        exit 1
    fi
fi

echo "Setting up application files..."
mkdir -p "$SATNET_DIR"
cd "$SATNET_DIR"

if [ ! -f package.json ]; then
    echo '{"name": "satnet-client", "version": "1.0.0", "private": true}' > package.json
fi

echo "Installing NPM dependencies..."
npm install ws --silent

cat << 'EOF' > "$SATNET_DIR/client.js"
const WebSocket = require('ws');
const net = require('net');
const fs = require('fs');
const path = require('path');

const SERVER_URL = 'wss://p2p.satnet.cv';
const BASE_DIR = __dirname;
const ID_FILE = path.join(BASE_DIR, 'satnet.id');
const STATS_FILE = path.join(BASE_DIR, 'stats.json');

let stats = {
    bytesRx: 0,
    bytesTx: 0,
    startTime: Date.now()
};

if (fs.existsSync(STATS_FILE)) {
    try {
        const saved = JSON.parse(fs.readFileSync(STATS_FILE, 'utf8'));
        stats.bytesRx = saved.bytesRx || 0;
        stats.bytesTx = saved.bytesTx || 0;
        stats.startTime = saved.startTime || Date.now();
    } catch (e) {}
}

setInterval(() => {
    fs.writeFile(STATS_FILE, JSON.stringify(stats), () => {});
}, 5000);

function log(msg, isError = false) {
    const timestamp = new Date().toISOString();
    const formatted = `[${timestamp}] ${isError ? 'ERROR: ' : ''}${msg}`;
    console.log(formatted);
}

const activeSockets = new Map();
let myNodeId = null;

if (fs.existsSync(ID_FILE)) {
    try {
        myNodeId = fs.readFileSync(ID_FILE, 'utf8').trim();
        log(`Loaded existing Node ID: ${myNodeId}`);
    } catch (e) {
        log(`Failed to read ID file: ${e.message}`, true);
    }
}

function connect() {
    log(`Connecting to ${SERVER_URL}...`);
    const ws = new WebSocket(SERVER_URL);

    ws.on('open', () => {
        log('Connected to server');
        const payload = { type: 'REGISTER' };
        if (myNodeId) payload.id = myNodeId;
        ws.send(JSON.stringify(payload));
    });

    ws.on('message', (message) => {
        try {
            const msg = JSON.parse(message);
            
            if (msg.type === 'REGISTERED') {
                myNodeId = msg.id;
                fs.writeFileSync(ID_FILE, myNodeId);
                log(`Registered! Node ID: ${myNodeId}`);
            } else {
                handleServerMessage(ws, msg);
            }
        } catch (e) {
            log(`Message error: ${e.message}`, true);
        }
    });

    ws.on('close', () => {
        log('Disconnected. Reconnecting in 5s...');
        setTimeout(connect, 5000);
    });

    ws.on('error', (err) => {
        log(`WebSocket error: ${err.message}`, true);
    });
}

function handleServerMessage(ws, msg) {
    if (msg.type === 'CONNECT') {
        const { requestId, host, port } = msg;

        const socket = net.createConnection(port, host, () => {
            ws.send(JSON.stringify({
                type: 'CONNECTED',
                requestId
            }));
        });

        activeSockets.set(requestId, socket);

        socket.on('data', (chunk) => {
            stats.bytesRx += chunk.length;
            
            ws.send(JSON.stringify({
                type: 'DATA',
                requestId,
                payload: chunk.toString('base64')
            }));
        });

        socket.on('end', () => {
            ws.send(JSON.stringify({ type: 'CLOSED', requestId }));
            activeSockets.delete(requestId);
        });

        socket.on('error', (err) => {
            log(`Proxy socket error: ${err.message}`, true);
            ws.send(JSON.stringify({ type: 'ERROR', requestId, error: err.message }));
            activeSockets.delete(requestId);
        });
    } else if (msg.type === 'DATA') {
        const { requestId, payload } = msg;
        const socket = activeSockets.get(requestId);
        if (socket) {
            const buffer = Buffer.from(payload, 'base64');
            
            stats.bytesTx += buffer.length;

            socket.write(buffer);
        }
    } else if (msg.type === 'CLOSE') {
        const { requestId } = msg;
        const socket = activeSockets.get(requestId);
        if (socket) {
            socket.end();
            activeSockets.delete(requestId);
        }
    }
}

connect();
EOF

echo "Configuring systemd service..."
cat << EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=Satnet P2P Client
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$SATNET_DIR
ExecStart=$(which node) $SATNET_DIR/client.js
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=satnet

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME > /dev/null 2>&1
systemctl restart $SERVICE_NAME

cat << 'EOF' > /usr/local/bin/satnet-status
#!/bin/bash
STATS_FILE="/opt/satnet/stats.json"
ID_FILE="/opt/satnet/satnet.id"

echo "=== Satnet Status ==="
systemctl status satnet | grep "Active:" --color=never

if [ -f "$ID_FILE" ]; then
    echo "Node ID: $(cat $ID_FILE)"
else
    echo "Node ID: (Registering...)"
fi

if [ -f "$STATS_FILE" ]; then
    # Parse JSON simply with grep/awk to avoid jq dependency
    RX=$(grep -o '"bytesRx":[0-9]*' $STATS_FILE | cut -d':' -f2)
    TX=$(grep -o '"bytesTx":[0-9]*' $STATS_FILE | cut -d':' -f2)
    
    # Function to format bytes
    format_bytes() {
        num=$1
        if [ -z "$num" ]; then echo "0 B"; return; fi
        if [ "$num" -gt 1073741824 ]; then
            echo "$(awk "BEGIN {printf \"%.2f\", $num/1073741824}") GB"
        elif [ "$num" -gt 1048576 ]; then
            echo "$(awk "BEGIN {printf \"%.2f\", $num/1048576}") MB"
        elif [ "$num" -gt 1024 ]; then
            echo "$(awk "BEGIN {printf \"%.2f\", $num/1024}") KB"
        else
            echo "$num B"
        fi
    }

    echo "Bandwidth Used:"
    echo "  Download (Rx): $(format_bytes $RX)"
    echo "  Upload   (Tx): $(format_bytes $TX)"
else
    echo "No stats available yet."
fi
echo "====================="
EOF
chmod +x /usr/local/bin/satnet-status

cat << EOF > /usr/local/bin/satnet-uninstall
#!/bin/bash
echo "Stopping Satnet service..."
systemctl stop $SERVICE_NAME
systemctl disable $SERVICE_NAME

echo "Removing files..."
rm -rf $SATNET_DIR
rm /etc/systemd/system/${SERVICE_NAME}.service
rm /usr/local/bin/satnet-status
rm /usr/local/bin/satnet-logs
rm /usr/local/bin/satnet-uninstall

systemctl daemon-reload
echo "Satnet has been successfully uninstalled."
echo "If you'd like to reinstall, please run the installer script again."
EOF
chmod +x /usr/local/bin/satnet-uninstall

cat << 'EOF' > /usr/local/bin/satnet-logs
#!/bin/bash
SERVICE_NAME="satnet"

if command -v journalctl >/dev/null 2>&1; then
  echo "Streaming logs for: ${SERVICE_NAME} (Ctrl+C to stop)"
  exec journalctl -u "${SERVICE_NAME}" -f -o cat
else
  echo "journalctl not found. Try: tail -f /var/log/syslog | grep satnet"
  exit 1
fi
EOF
chmod +x /usr/local/bin/satnet-logs

echo "Waiting for node registration..."
sleep 5

echo -e "\n${GREEN}Success! Satnet is installed and running.${NC}"
if [ -f "$ID_FILE" ]; then
    echo -e "Your Node ID is: ${YELLOW}$(cat $ID_FILE)${NC}"
else 
    echo "Node ID is being generated. Run 'satnet-status' in a moment to see it."
fi

echo ""
echo "Commands available:"
echo "  satnet-status     : Check service status and bandwidth"
echo "  satnet-uninstall  : Remove the application"
echo "  satnet-logs       : View live logs"
echo ""
