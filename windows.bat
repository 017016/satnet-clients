@echo off
setlocal

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Please run as Administrator.
    pause
    exit /b 1
)

cls
echo =========================================
echo      Welcome to the Satnet Installer
echo =========================================
echo.
echo By installing this software, you agree to share your internet bandwidth
echo to participate in the Satnet P2P network.
echo.
echo Terms ^& Conditions:
echo 1. You authorize this device to act as a proxy node.
echo 2. We are not responsible for traffic passed through your node.
echo 3. You may uninstall at any time using 'satnet-uninstall'.
echo.

set /p confirm="Do you accept these terms? (y/N): "
if /i not "%confirm%"=="y" (
    echo Installation aborted.
    pause
    exit /b 1
)

echo.
echo Starting installation...

node -v >nul 2>&1
if %errorLevel% neq 0 (
    echo Node.js not found. Installing...
    powershell -Command "Invoke-WebRequest -Uri 'https://nodejs.org/dist/v20.10.0/node-v20.10.0-x64.msi' -OutFile 'nodejs.msi'"
    echo Installing Node.js MSI...
    msiexec /i nodejs.msi /qn
    del nodejs.msi
    set "PATH=%PATH%;C:\Program Files\nodejs"
)

if not exist "C:\Satnet" mkdir "C:\Satnet"
cd /d "C:\Satnet"

if not exist package.json (
    echo {"name": "satnet-client", "version": "1.0.0", "private": true} > package.json
)

echo Installing NPM dependencies...
call "C:\Program Files\nodejs\npm" install ws --silent

echo Creating application files...
powershell -Command "$c = @'
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
'@; [System.IO.File]::WriteAllText('C:\Satnet\client.js', $c)"

echo Configuring Scheduled Task...
schtasks /create /tn "SatnetClient" /tr "\"C:\Program Files\nodejs\node.exe\" C:\Satnet\client.js" /sc onstart /ru SYSTEM /f >nul

schtasks /run /tn "SatnetClient" >nul

(
echo @echo off
echo powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=Get-Content 'C:\Satnet\stats.json' -Raw | ConvertFrom-Json; $rx=$s.bytesRx/1MB; $tx=$s.bytesTx/1MB; Write-Host '=== Satnet Status ==='; Write-Host ('Download: {0:N2} MB' -f $rx); Write-Host ('Upload:   {0:N2} MB' -f $tx); if (Test-Path 'C:\Satnet\satnet.id') { Write-Host ('Node ID:  ' + (Get-Content 'C:\Satnet\satnet.id')) } else { Write-Host 'Node ID:  (Registering...)' }"
echo pause
) > "%SystemRoot%\satnet-status.bat"

(
echo @echo off
echo echo Stopping service...
echo schtasks /end /tn "SatnetClient" 2^>nul
echo schtasks /delete /tn "SatnetClient" /f 2^>nul
echo echo Removing files...
echo rmdir /s /q "C:\Satnet"
echo del "%SystemRoot%\satnet-status.bat"
echo del "%SystemRoot%\satnet-uninstall.bat"
echo echo Satnet uninstalled successfully.
echo pause
) > "%SystemRoot%\satnet-uninstall.bat"

echo.
echo Success! Satnet is installed and running in the background.
echo.
echo Commands available:
echo   satnet-status     : Check stats
echo   satnet-uninstall  : Uninstall
echo.
pause
