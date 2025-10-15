#!/bin/bash

# FazzNet Monitor - Project Setup Script
# This script creates complete project structure and files

set -e

PROJECT_NAME="fazznet-monitor"
PROJECT_DIR="$HOME/$PROJECT_NAME"

echo "=========================================="
echo "FazzNet Monitor - Project Setup"
echo "=========================================="
echo ""
echo "This will create project structure at: $PROJECT_DIR"
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# Create directory structure
echo "[1/10] Creating directory structure..."
mkdir -p "$PROJECT_DIR"/{backend,frontend/{public,src/components},scripts,config/{nginx,cloudflare,systemd,mikrotik},docs,docker}

# Backend files
echo "[2/10] Creating backend files..."

# server.js
cat > "$PROJECT_DIR/backend/server.js" << 'BACKEND_JS'
const express = require('express');
const cors = require('cors');
const RouterOSAPI = require('node-routeros').RouterOSAPI;
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

const mikrotikConfig = {
  host: process.env.MIKROTIK_HOST || '192.168.88.1',
  user: process.env.MIKROTIK_USER || 'admin',
  password: process.env.MIKROTIK_PASSWORD || '',
  port: process.env.MIKROTIK_PORT || 8728,
  timeout: 10
};

async function connectMikrotik() {
  const conn = new RouterOSAPI({
    host: mikrotikConfig.host,
    user: mikrotikConfig.user,
    password: mikrotikConfig.password,
    port: mikrotikConfig.port,
    timeout: mikrotikConfig.timeout
  });

  try {
    await conn.connect();
    return conn;
  } catch (err) {
    console.error('Mikrotik connection error:', err);
    throw err;
  }
}

function formatBytes(bytes) {
  if (bytes === 0) return '0 Bytes';
  const k = 1024;
  const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return Math.round((bytes / Math.pow(k, i)) * 100) / 100 + ' ' + sizes[i];
}

function formatUptime(uptime) {
  if (!uptime) return '0h';
  const match = uptime.match(/(\d+w)?(\d+d)?(\d+h)?(\d+m)?(\d+s)?/);
  if (!match) return uptime;
  let result = '';
  if (match[1]) result += match[1] + ' ';
  if (match[2]) result += match[2] + ' ';
  if (match[3]) result += match[3];
  if (!result && match[4]) result += match[4];
  return result.trim() || '0h';
}

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', message: 'Mikrotik Monitor API is running' });
});

app.get('/api/static-clients', async (req, res) => {
  let conn;
  try {
    conn = await connectMikrotik();
    const leases = await conn.write('/ip/dhcp-server/lease/print');
    
    const clients = leases.map(lease => ({
      id: lease['.id'],
      ip: lease.address || 'N/A',
      mac: lease['mac-address'] || 'N/A',
      name: lease['host-name'] || lease.comment || 'Unknown',
      status: lease.status === 'bound' ? 'online' : 'offline',
      uptime: formatUptime(lease['expires-after'] || '0s'),
      server: lease.server || 'N/A',
      lastSeen: lease['last-seen'] || 'N/A'
    }));

    await conn.close();
    res.json(clients);
  } catch (error) {
    console.error('Error fetching static clients:', error);
    if (conn) await conn.close();
    res.status(500).json({ error: 'Failed to fetch static clients', message: error.message });
  }
});

app.get('/api/pppoe-clients', async (req, res) => {
  let conn;
  try {
    conn = await connectMikrotik();
    const sessions = await conn.write('/ppp/active/print');
    const secrets = await conn.write('/ppp/secret/print');
    
    const clients = sessions.map(session => {
      const secret = secrets.find(s => s.name === session.name);
      return {
        id: session['.id'],
        username: session.name || 'N/A',
        ip: session.address || 'N/A',
        status: 'online',
        uptime: formatUptime(session.uptime || '0s'),
        rx: formatBytes(parseInt(session['bytes-in'] || 0)),
        tx: formatBytes(parseInt(session['bytes-out'] || 0)),
        service: session.service || 'pppoe',
        callerID: session['caller-id'] || 'N/A',
        profile: secret ? (secret.profile || 'default') : 'N/A'
      };
    });

    await conn.close();
    res.json(clients);
  } catch (error) {
    console.error('Error fetching PPPoE clients:', error);
    if (conn) await conn.close();
    res.status(500).json({ error: 'Failed to fetch PPPoE clients', message: error.message });
  }
});

app.get('/api/stats', async (req, res) => {
  let conn;
  try {
    conn = await connectMikrotik();
    const leases = await conn.write('/ip/dhcp-server/lease/print');
    const sessions = await conn.write('/ppp/active/print');
    const secrets = await conn.write('/ppp/secret/print');
    
    const activeLeases = leases.filter(l => l.status === 'bound').length;
    const activePPPoE = sessions.length;
    
    await conn.close();
    
    res.json({
      totalClients: leases.length,
      activeClients: activeLeases,
      totalPPPoE: secrets.length,
      activePPPoE: activePPPoE,
      totalActive: activeLeases + activePPPoE,
      lastUpdate: new Date().toISOString()
    });
  } catch (error) {
    console.error('Error fetching stats:', error);
    if (conn) await conn.close();
    res.status(500).json({ error: 'Failed to fetch statistics', message: error.message });
  }
});

app.get('/api/system-resources', async (req, res) => {
  let conn;
  try {
    conn = await connectMikrotik();
    const resources = await conn.write('/system/resource/print');
    const resource = resources[0];
    
    await conn.close();
    
    res.json({
      cpu: resource['cpu-load'] || '0%',
      memory: {
        total: formatBytes(parseInt(resource['total-memory'] || 0)),
        free: formatBytes(parseInt(resource['free-memory'] || 0)),
        used: formatBytes(parseInt(resource['total-memory'] || 0) - parseInt(resource['free-memory'] || 0))
      },
      uptime: formatUptime(resource.uptime || '0s'),
      version: resource.version || 'N/A',
      board: resource['board-name'] || 'N/A'
    });
  } catch (error) {
    console.error('Error fetching system resources:', error);
    if (conn) await conn.close();
    res.status(500).json({ error: 'Failed to fetch system resources', message: error.message });
  }
});

app.post('/api/pppoe-disconnect/:username', async (req, res) => {
  let conn;
  try {
    conn = await connectMikrotik();
    const username = req.params.username;
    const sessions = await conn.write('/ppp/active/print', [`?name=${username}`]);
    
    if (sessions.length === 0) {
      await conn.close();
      return res.status(404).json({ error: 'Session not found' });
    }
    
    await conn.write('/ppp/active/remove', [`=.id=${sessions[0]['.id']}`]);
    await conn.close();
    res.json({ success: true, message: `User ${username} disconnected` });
  } catch (error) {
    console.error('Error disconnecting PPPoE client:', error);
    if (conn) await conn.close();
    res.status(500).json({ error: 'Failed to disconnect client', message: error.message });
  }
});

app.listen(PORT, () => {
  console.log(`🚀 Mikrotik Monitor API running on port ${PORT}`);
  console.log(`📡 Mikrotik host: ${mikrotikConfig.host}`);
  console.log(`🌐 API ready at http://localhost:${PORT}/api`);
});
BACKEND_JS

# package.json
cat > "$PROJECT_DIR/backend/package.json" << 'EOF'
{
  "name": "mikrotik-monitor-api",
  "version": "1.0.0",
  "description": "Backend API for Mikrotik Monitoring with fazznet.my.id",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "nodemon server.js"
  },
  "keywords": ["mikrotik", "monitoring", "api", "routeros"],
  "author": "FazzNet",
  "license": "MIT",
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "dotenv": "^16.3.1",
    "node-routeros": "^2.2.1"
  },
  "devDependencies": {
    "nodemon": "^3.0.1"
  }
}
EOF

# .env.example
cat > "$PROJECT_DIR/backend/.env.example" << 'EOF'
MIKROTIK_HOST=192.168.88.1
MIKROTIK_USER=admin
MIKROTIK_PASSWORD=your_password_here
MIKROTIK_PORT=8728
PORT=3000
NODE_ENV=production
ALLOWED_ORIGINS=https://monitor.fazznet.my.id,https://fazznet.my.id
EOF

# ecosystem.config.js
cat > "$PROJECT_DIR/backend/ecosystem.config.js" << 'EOF'
module.exports = {
  apps: [{
    name: 'mikrotik-api',
    script: './server.js',
    instances: 2,
    exec_mode: 'cluster',
    max_memory_restart: '500M',
    env: {
      NODE_ENV: 'production',
      PORT: 3000
    },
    error_file: '/var/log/pm2/mikrotik-api-error.log',
    out_file: '/var/log/pm2/mikrotik-api-out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    merge_logs: true,
    autorestart: true,
    watch: false,
    max_restarts: 10,
    min_uptime: '10s'
  }]
};
EOF

# .gitignore
cat > "$PROJECT_DIR/backend/.gitignore" << 'EOF'
node_modules/
.env
*.log
.DS_Store
EOF

echo "[3/10] Creating frontend files..."

# Frontend package.json
cat > "$PROJECT_DIR/frontend/package.json" << 'EOF'
{
  "name": "fazznet-monitor-frontend",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "react-scripts": "5.0.1",
    "lucide-react": "^0.263.1"
  },
  "scripts": {
    "start": "react-scripts start",
    "build": "react-scripts build",
    "test": "react-scripts test",
    "eject": "react-scripts eject"
  },
  "eslintConfig": {
    "extends": ["react-app"]
  },
  "browserslist": {
    "production": [">0.2%", "not dead", "not op_mini all"],
    "development": ["last 1 chrome version", "last 1 firefox version", "last 1 safari version"]
  }
}
EOF

# public/index.html
cat > "$PROJECT_DIR/frontend/public/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <link rel="icon" href="%PUBLIC_URL%/favicon.ico" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="theme-color" content="#000000" />
    <meta name="description" content="FazzNet Mikrotik Monitor - Real-time network monitoring" />
    <link rel="apple-touch-icon" href="%PUBLIC_URL%/logo192.png" />
    <link rel="manifest" href="%PUBLIC_URL%/manifest.json" />
    <title>FazzNet Monitor</title>
    <script src="https://cdn.tailwindcss.com"></script>
  </head>
  <body>
    <noscript>You need to enable JavaScript to run this app.</noscript>
    <div id="root"></div>
  </body>
</html>
EOF

# public/manifest.json
cat > "$PROJECT_DIR/frontend/public/manifest.json" << 'EOF'
{
  "short_name": "FazzNet Monitor",
  "name": "FazzNet Mikrotik Monitoring Dashboard",
  "icons": [
    {
      "src": "favicon.ico",
      "sizes": "64x64 32x32 24x24 16x16",
      "type": "image/x-icon"
    }
  ],
  "start_url": ".",
  "display": "standalone",
  "theme_color": "#000000",
  "background_color": "#ffffff"
}
EOF

# src/index.js
cat > "$PROJECT_DIR/frontend/src/index.js" << 'EOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import './index.css';
import App from './App';

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
EOF

# src/index.css
cat > "$PROJECT_DIR/frontend/src/index.css" << 'EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', 'Oxygen',
    'Ubuntu', 'Cantarell', 'Fira Sans', 'Droid Sans', 'Helvetica Neue',
    sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

code {
  font-family: source-code-pro, Menlo, Monaco, Consolas, 'Courier New', monospace;
}
EOF

# Note: App.js sudah ada di artifact sebelumnya
echo "NOTE: Copy App.js from previous artifact to frontend/src/App.js"

# .gitignore
cat > "$PROJECT_DIR/frontend/.gitignore" << 'EOF'
node_modules/
build/
.env.local
.DS_Store
npm-debug.log*
EOF

echo "[4/10] Creating script files..."

# install.sh - Copy from artifact
cat > "$PROJECT_DIR/scripts/install.sh" << 'INSTALLSCRIPT'
#!/bin/bash
set -e

echo "=========================================="
echo "FazzNet Mikrotik Monitor Installation"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

apt update && apt upgrade -y
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs nginx build-essential
npm install -g pm2

wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared-linux-amd64.deb
rm cloudflared-linux-amd64.deb

mkdir -p /var/www/mikrotik-monitor/{backend,frontend}
mkdir -p /var/log/pm2
mkdir -p /backup/fazznet-monitor

echo "Installation complete! Next steps:"
echo "1. Copy backend files to /var/www/mikrotik-monitor/backend/"
echo "2. Copy frontend files to /var/www/mikrotik-monitor/frontend/"
echo "3. Configure .env file"
echo "4. Run setup scripts"
INSTALLSCRIPT

chmod +x "$PROJECT_DIR/scripts/install.sh"

# restart-all.sh
cat > "$PROJECT_DIR/scripts/restart-all.sh" << 'EOF'
#!/bin/bash
echo "🔄 Restarting all FazzNet Monitor services..."
pm2 restart mikrotik-api
systemctl restart cloudflared
systemctl restart nginx
echo "✅ All services restarted!"
pm2 status
EOF

chmod +x "$PROJECT_DIR/scripts/restart-all.sh"

# update.sh
cat > "$PROJECT_DIR/scripts/update.sh" << 'EOF'
#!/bin/bash
BACKUP_DIR="/backup/fazznet-monitor/pre-update-$(date +%Y%m%d_%H%M%S)"
echo "Creating backup..."
mkdir -p $BACKUP_DIR
cp -r /var/www/mikrotik-monitor $BACKUP_DIR/
cd /var/www/mikrotik-monitor/backend
npm install
pm2 restart mikrotik-api
echo "✅ Update complete! Backup: $BACKUP_DIR"
EOF

chmod +x "$PROJECT_DIR/scripts/update.sh"

echo "[5/10] Creating config files..."

# Nginx config
cat > "$PROJECT_DIR/config/nginx/fazznet-monitor.conf" << 'EOF'
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=web_limit:10m rate=30r/s;

upstream backend_api {
    server 127.0.0.1:3000 max_fails=3 fail_timeout=30s;
    keepalive 32;
}

server {
    listen 80;
    server_name monitor.fazznet.my.id;
    root /var/www/mikrotik-monitor/frontend;
    index index.html;
    
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/json;
    
    limit_req zone=web_limit burst=20 nodelay;
    
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    location / {
        try_files $uri $uri/ /index.html;
    }
    
    location /api {
        proxy_pass http://backend_api;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_cache_bypass $http_upgrade;
        limit_req zone=api_limit burst=5 nodelay;
    }
    
    access_log /var/log/nginx/fazznet-monitor-access.log;
    error_log /var/log/nginx/fazznet-monitor-error.log;
}

server {
    listen 80;
    server_name api.fazznet.my.id;
    
    add_header Access-Control-Allow-Origin "https://monitor.fazznet.my.id" always;
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
    
    limit_req zone=api_limit burst=10 nodelay;
    
    location / {
        if ($request_method = 'OPTIONS') {
            return 204;
        }
        proxy_pass http://backend_api;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    
    access_log /var/log/nginx/fazznet-api-access.log;
    error_log /var/log/nginx/fazznet-api-error.log;
}
EOF

# Cloudflare config
cat > "$PROJECT_DIR/config/cloudflare/config.yml" << 'EOF'
tunnel: mikrotik-monitor
credentials-file: /root/.cloudflared/TUNNEL_ID.json

ingress:
  - hostname: monitor.fazznet.my.id
    service: http://localhost:80
  - hostname: api.fazznet.my.id
    service: http://localhost:3000
  - service: http_status:404
EOF

# Cloudflare setup script
cat > "$PROJECT_DIR/config/cloudflare/setup.sh" << 'EOF'
#!/bin/bash
echo "🌐 Setting up Cloudflare Tunnel for fazznet.my.id"

if ! command -v cloudflared &> /dev/null; then
    wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb
    rm cloudflared-linux-amd64.deb
fi

cloudflared tunnel login
cloudflared tunnel create mikrotik-monitor

TUNNEL_ID=$(cloudflared tunnel list | grep mikrotik-monitor | awk '{print $1}')
echo "Tunnel ID: $TUNNEL_ID"

mkdir -p ~/.cloudflared
sed "s/TUNNEL_ID/$TUNNEL_ID/g" config.yml > ~/.cloudflared/config.yml

cloudflared tunnel route dns mikrotik-monitor monitor.fazznet.my.id
cloudflared tunnel route dns mikrotik-monitor api.fazznet.my.id

cloudflared service install
systemctl start cloudflared
systemctl enable cloudflared

echo "✅ Cloudflare Tunnel setup complete!"
EOF

chmod +x "$PROJECT_DIR/config/cloudflare/setup.sh"

# Mikrotik setup commands
cat > "$PROJECT_DIR/config/mikrotik/setup-commands.rsc" << 'EOF'
# FazzNet Monitor - Mikrotik Setup Commands

/ip service set api disabled=no port=8728
/ip service set api-ssl disabled=no port=8729

/user group add name=monitoring policy=read,api,winbox comment="FazzNet Monitor"
/user add name=monitor password=MonitorPass123! group=monitoring

/ip firewall filter add chain=input protocol=tcp dst-port=8728 src-address=SERVER_IP action=accept comment="Allow Monitor API"
/ip firewall filter add chain=input protocol=tcp dst-port=8728 action=drop comment="Block others"

/ip pool add name=dhcp-pool ranges=192.168.1.100-192.168.1.200
/ip dhcp-server add name=dhcp1 interface=bridge address-pool=dhcp-pool disabled=no
/ip dhcp-server network add address=192.168.1.0/24 gateway=192.168.1.1 dns-server=8.8.8.8

/interface bridge add name=bridge-local
/ip pool add name=pppoe-pool ranges=10.10.10.2-10.10.10.254

/ppp profile add name=Profile-10M local-address=10.10.10.1 remote-address=pppoe-pool rate-limit=10M/10M
/ppp profile add name=Profile-20M local-address=10.10.10.1 remote-address=pppoe-pool rate-limit=20M/20M

/interface pppoe-server server add service-name=FazzNet interface=bridge-local disabled=no

/system ntp client set enabled=yes primary-ntp=0.id.pool.ntp.org
/system clock set time-zone-name=Asia/Jakarta

/system identity set name=FazzNet-Router
/system backup save name=fazznet-initial-config

:put "FazzNet Monitor setup complete!"
EOF

# Systemd service
cat > "$PROJECT_DIR/config/systemd/mikrotik-api.service" << 'EOF'
[Unit]
Description=Mikrotik Monitor API Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/www/mikrotik-monitor/backend
ExecStart=/usr/bin/node /var/www/mikrotik-monitor/backend/server.js
Restart=on-failure
RestartSec=10
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

echo "[6/10] Creating documentation..."

# README.md
cat > "$PROJECT_DIR/README.md" << 'EOF'
# FazzNet Mikrotik Monitor

Real-time monitoring dashboard untuk Mikrotik RouterOS dengan domain fazznet.my.id

## Features
- ✅ Real-time monitoring Static IP & PPPoE clients
- ✅ System resources monitoring
- ✅ Bandwidth usage tracking
- ✅ PPPoE session management
- ✅ Cloudflare Tunnel integration
- ✅ Responsive dashboard

## Quick Start

```bash
# Run installation
sudo bash scripts/install.sh

# Copy files to server
scp -r backend/* root@server:/var/www/mikrotik-monitor/backend/
scp -r frontend/build/* root@server:/var/www/mikrotik-monitor/frontend/

# Configure
cd /var/www/mikrotik-monitor/backend
cp .env.example .env
nano .env

# Start
pm2 start ecosystem.config.js
bash config/cloudflare/setup.sh
```

## URLs
- Frontend: https://monitor.fazznet.my.id
- API: https://api.fazznet.my.id

## Documentation
See `docs/` folder for detailed documentation.

## License
MIT
EOF

# QUICKSTART.md
cat > "$PROJECT_DIR/docs/QUICKSTART.md" << 'EOF'
# Quick Start Guide

## Prerequisites
- Ubuntu 20.04+ server
- Domain: fazznet.my.id (in Cloudflare)
- Mikrotik with RouterOS 6.x/7.x

## 5-Minute Setup

1. **Install dependencies**
```bash
sudo bash scripts/install.sh
```

2. **Deploy files**
```bash
sudo cp -r backend/* /var/www/mikrotik-monitor/backend/
sudo cp -r frontend/build/* /var/www/mikrotik-monitor/frontend/
```

3. **Configure**
```bash
cd /var/www/mikrotik-monitor/backend
cp .env.example .env
nano .env  # Edit Mikrotik credentials
```

4. **Start services**
```bash
pm2 start ecosystem.config.js
pm2 save
pm2 startup
```

5. **Setup Cloudflare**
```bash
bash /path/to/config/cloudflare/setup.sh
```

6. **Configure Nginx**
```bash
sudo cp config/nginx/fazznet-monitor.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/fazznet-monitor.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

7. **Setup Mikrotik**
Run commands from `config/mikrotik/setup-commands.rsc` in Mikrotik terminal

8. **Access**
Open https://monitor.fazznet.my.id

Done! ✅
EOF

echo "[7/10] Creating Docker files..."

# Dockerfile
cat > "$PROJECT_DIR/docker/Dockerfile" << 'EOF'
FROM node:20-alpine
WORKDIR /app
COPY backend/package*.json ./
RUN npm install --production
COPY backend/ ./
EXPOSE 3000
HEALTHCHECK --interval=30s CMD node -e "require('http').get('http://localhost:3000/api/health')"
CMD ["node", "server.js"]
EOF

# docker-compose.yml
cat > "$PROJECT_DIR/docker/docker-compose.yml" << 'EOF'
version: '3.8'
services:
  backend:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    container_name: fazznet-monitor-api
    restart: unless-stopped
    ports:
      - "3000:3000"
    env_file:
      - ../backend/.env
    volumes:
      - ../backend:/app
      - /app/node_modules
    networks:
      - fazznet-network

  nginx:
    image: nginx:alpine
    container_name: fazznet-monitor-nginx
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ../frontend/build:/usr/share/nginx/html
      - ../config/nginx/fazznet-monitor.conf:/etc/nginx/conf.d/default.conf
    depends_on:
      - backend
    networks:
      - fazznet-network

networks:
  fazznet-network:
    driver: bridge
EOF

echo "[8/10] Creating .gitignore files..."

cat > "$PROJECT_DIR/.gitignore" << 'EOF'
node_modules/
.env
*.log
.DS_Store
build/
dist/
.pm2/
*.json
credentials/
EOF

echo "[9/10] Setting permissions..."
chmod +x "$PROJECT_DIR"/scripts/*.sh
chmod 600 "$PROJECT_DIR/backend/.env.example"

echo "[10/10] Creating deployment guide..."

cat > "$PROJECT_DIR/DEPLOY.md" << 'EOF'
# Deployment Guide

## Server Setup

1. Upload project to server:
```bash
rsync -avz fazznet-monitor/ root@server:/root/fazznet-monitor/
```

2. Run installation:
```bash
ssh root@server
cd /root/fazznet-monitor
bash scripts/install.sh
```

3. Deploy files:
```bash
cp -r backend/* /var/www/mikrotik-monitor/backend/
cd /var/www/mikrotik-monitor/backend
npm install
cp .env.example .env
nano .env
```

4. Build frontend (on local machine):
```bash
cd frontend
npm install
npm run build
```

5. Upload frontend build:
```bash
scp -r build/* root@server:/var/www/mikrotik-monitor/frontend/
```

6. Setup services:
```bash
pm2 start /var/www/mikrotik-monitor/backend/ecosystem.config.js
pm2 save
pm2 startup

cp config/nginx/fazznet-monitor.conf /etc/nginx/sites-available/
ln -s /etc/nginx/sites-available/fazznet-monitor.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

7. Setup Cloudflare:
```bash
cd config/cloudflare
bash setup.sh
```

8. Configure Mikrotik:
Copy commands from `config/mikrotik/setup-commands.rsc`
Run in Mikrotik terminal/Winbox

## Verify

```bash
# Check services
pm2 status
systemctl status cloudflared
systemctl status nginx

# Test API
curl http://localhost:3000/api/health
curl https://api.fazznet.my.id/api/health

# Test frontend
curl https://monitor.fazznet.my.id
```

## Done!
Access: https://monitor.fazznet.my.id
EOF

echo ""
echo "=========================================="
echo "✅ Project structure created successfully!"
echo "=========================================="
echo ""
echo "Project location: $PROJECT_DIR"
echo ""
echo "Next steps:"
echo "1. cd $PROJECT_DIR"
echo "2. Review and edit configuration files"
echo "3. Install backend dependencies: cd backend && npm install"
echo "4. Install frontend dependencies: cd frontend && npm install"
echo "5. Build frontend: cd frontend && npm run build"
echo "6. Follow DEPLOY.md for deployment"
echo ""
echo "Quick commands:"
echo "  cd $PROJECT_DIR"
echo "  tree -L 2  # View structure"
echo "  cat DEPLOY.md  # Deployment guide"
echo ""
echo "=========================================="
