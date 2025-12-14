#!/bin/bash

SATNET_DIR="/usr/local/satnet"
SERVICE_LABEL="cv.satnet.client"
PLIST_PATH="/Library/LaunchDaemons/${SERVICE_LABEL}.plist"
ID_FILE="$SATNET_DIR/satnet.id"
STATS_FILE="$SATNET_DIR/stats.json"
LOG_FILE="/var/log/satnet.log"

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
echo -e "${YELLOW}   Welcome to the Satnet Installer (Mac) ${NC}"
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
    echo "Node.js not found."
    if command -v brew &> /dev/null; then
        echo "Attempting to install Node.js via Homebrew..."
        brew install node
    else
        echo -e "${RED}Node.js is required but not found.${NC}"
        echo "Please install it manually from: https://nodejs.org/"
        exit 1
    fi
    
    if ! command -v node &> /dev/null; then
         echo -e "${RED}Node.js installation failed. Please install manually.${NC}"
         exit 1
    fi
fi

NODE_BIN=$(command -v node)
echo "Node.js found at: $NODE_BIN"

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
        log(`Proxy Request: ${host}:${port} (${requestId})`);

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

echo "Configuring LaunchDaemon (MacOS Service)..."

touch "$LOG_FILE"
chmod 666 "$LOG_FILE"

cat << EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${NODE_BIN}</string>
        <string>${SATNET_DIR}/client.js</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SATNET_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
EOF

chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

launchctl unload "$PLIST_PATH" 2>/dev/null
launchctl load -w "$PLIST_PATH"

cat << 'EOF' > /usr/local/bin/satnet-status
#!/bin/bash
STATS_FILE="/usr/local/satnet/stats.json"
ID_FILE="/usr/local/satnet/satnet.id"
SERVICE_LABEL="cv.satnet.client"
LOG_FILE="/var/log/satnet.log"

echo "=== Satnet Status (MacOS) ==="

PID=$(launchctl list | grep "$SERVICE_LABEL" | awk '{print $1}')

if [[ "$PID" =~ ^[0-9]+$ ]]; then
    echo -e "Status: \033[0;32mActive\033[0m (PID: $PID)"
else
    echo -e "Status: \033[0;31mInactive\033[0m"
fi

if [ -f "$ID_FILE" ]; then
    echo "Node ID: $(cat $ID_FILE)"
else
    echo "Node ID: (Registering...)"
fi

if [ -f "$STATS_FILE" ]; then
    RX=$(grep -o '"bytesRx":[0-9]*' $STATS_FILE | cut -d':' -f2)
    TX=$(grep -o '"bytesTx":[0-9]*' $STATS_FILE | cut -d':' -f2)
    
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
echo "Logs available at: $LOG_FILE"
EOF
chmod +x /usr/local/bin/satnet-status

cat << EOF > /usr/local/bin/satnet-uninstall
#!/bin/bash
if [ "\$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)."
  exit 1
fi

echo "Stopping Satnet service..."
launchctl unload "$PLIST_PATH"

echo "Removing files..."
rm -rf "$SATNET_DIR"
rm "$PLIST_PATH"
rm /usr/local/bin/satnet-status
rm /usr/local/bin/satnet-uninstall
rm "$LOG_FILE"

echo "Satnet has been successfully uninstalled."
EOF
chmod +x /usr/local/bin/satnet-uninstall

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
echo "  tail -f $LOG_FILE : View live logs"
echo ""
