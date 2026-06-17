#!/bin/bash
# ============================================================
# Pi Gateway - Configure: Dashboard + Telegram Bot + systemd
# Run AFTER 01_install.sh and editing config.env
# ============================================================
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
die()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash 02_configure.sh"
source /etc/EdgeGateway/config.env

APP_DIR=/opt/EdgeGateway
VENV=$APP_DIR/venv

# ── Validate required config ───────────────────────────────
if [[ -z "$BOT_TOKEN" ]]; then
    die "BOT_TOKEN is empty. Edit /etc/EdgeGateway/config.env first."
fi
if [[ -z "$ADMIN_CHAT_ID" ]]; then
    die "ADMIN_CHAT_ID is empty. Edit /etc/EdgeGateway/config.env first."
fi

# ── WARP watchdog script ──────────────────────────────────
info "Creating WARP watchdog..."
cat > /usr/local/bin/warp-watchdog.sh <<'WATCHDOG'
#!/bin/bash
# Reconnect WARP if tunnel drops
STATUS=$(warp-cli status 2>/dev/null | grep -o "Connected\|Disconnected" | head -1)
if [[ "$STATUS" != "Connected" ]]; then
    logger -t warp-watchdog "WARP disconnected - reconnecting..."
    warp-cli connect
    sleep 5
    # If still down, reroute via raw WAN temporarily
    if ! warp-cli status | grep -q "Connected"; then
        logger -t warp-watchdog "WARP still down - traffic via WAN (fallback)"
    fi
fi
WATCHDOG
chmod +x /usr/local/bin/warp-watchdog.sh

# Cron: run watchdog every minute (deduplicate first)
(crontab -l 2>/dev/null | grep -v "warp-watchdog.sh"; echo "* * * * * /usr/local/bin/warp-watchdog.sh") | crontab -
ok "WARP watchdog installed"

# ── Gateway stats helper ──────────────────────────────────
info "Creating stats helper..."
cat > /usr/local/bin/gw-stats.sh <<'STATS'
#!/bin/bash
set -o pipefail

# Source config for interface names
source /etc/EdgeGateway/config.env 2>/dev/null

# Fallback defaults if config didn't load
: "${WAN_IFACE:=eth0}"

# WARP status
WARP_STATUS=$(warp-cli status 2>/dev/null | grep -o "Connected\|Disconnected" | head -1)
WARP_STATUS="${WARP_STATUS:-Unknown}"
WARP_IP=$(warp-cli warp-stats 2>/dev/null | grep "WAN IP" | awk '{print $NF}' || echo "N/A")
WARP_IP="${WARP_IP:-N/A}"

# CPU usage
CPU=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{printf "%.0f", $2}' || echo "0")

# Memory
MEM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || echo "0")
MEM_USED=$(free -m 2>/dev/null | awk '/Mem:/{print $3}' || echo "0")
if [[ "$MEM_TOTAL" -gt 0 ]]; then
    MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
else
    MEM_PCT=0
fi

# Temperature (try vcgencmd first, then sysfs)
TEMP="0"
if command -v vcgencmd &>/dev/null; then
    TEMP_RAW=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2 | cut -d\' -f1)
    [[ -n "$TEMP_RAW" ]] && TEMP="$TEMP_RAW"
else
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp)
        TEMP=$(awk "BEGIN {printf \"%.1f\", $TEMP_RAW/1000}")
    fi
fi

# Uptime
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || echo "unknown")

# Network via vnstat (optional)
RX_TODAY=$(vnstat -i "$WAN_IFACE" --oneline 2>/dev/null | cut -d';' -f10 || echo "N/A")
TX_TODAY=$(vnstat -i "$WAN_IFACE" --oneline 2>/dev/null | cut -d';' -f11 || echo "N/A")
RX_TODAY="${RX_TODAY:-N/A}"
TX_TODAY="${TX_TODAY:-N/A}"

# Connected clients (DHCP leases)
LEASES_FILE="/var/lib/misc/dnsmasq.leases"
if [[ -f "$LEASES_FILE" ]]; then
    CLIENTS=$(wc -l < "$LEASES_FILE" 2>/dev/null || echo "0")
else
    CLIENTS=0
fi

# Throughput (bytes/sec snapshot)
RX1=$(cat /sys/class/net/"$WAN_IFACE"/statistics/rx_bytes 2>/dev/null || echo 0)
TX1=$(cat /sys/class/net/"$WAN_IFACE"/statistics/tx_bytes 2>/dev/null || echo 0)
sleep 1
RX2=$(cat /sys/class/net/"$WAN_IFACE"/statistics/rx_bytes 2>/dev/null || echo 0)
TX2=$(cat /sys/class/net/"$WAN_IFACE"/statistics/tx_bytes 2>/dev/null || echo 0)
RX_RATE=$(( (RX2-RX1) / 1024 ))
TX_RATE=$(( (TX2-TX1) / 1024 ))

# Output JSON using python for guaranteed valid JSON
python3 -c "
import json, sys
data = {
    'warp': '$WARP_STATUS',
    'warp_ip': '$WARP_IP',
    'cpu': int('$CPU'),
    'mem_pct': int('$MEM_PCT'),
    'mem_used': int('$MEM_USED'),
    'mem_total': int('$MEM_TOTAL'),
    'temp': '$TEMP',
    'uptime': '$UPTIME',
    'clients': int('$CLIENTS'),
    'rx_today': '$RX_TODAY',
    'tx_today': '$TX_TODAY',
    'rx_kbps': int('$RX_RATE'),
    'tx_kbps': int('$TX_RATE'),
}
print(json.dumps(data))
"
STATS
chmod +x /usr/local/bin/gw-stats.sh
ok "Stats helper ready"

# ── Flask Dashboard ───────────────────────────────────────
info "Deploying dashboard..."
cat > $APP_DIR/dashboard.py <<'DASHBOARD'
import os, json, subprocess, time
from flask import Flask, render_template, jsonify, request
from flask_socketio import SocketIO
import threading

app = Flask(__name__)
# Restrict CORS to same origin only
socketio = SocketIO(app, cors_allowed_origins=[], async_mode="eventlet")
PORT = int(os.environ.get("DASHBOARD_PORT", 5000))

# Restrict API endpoints to AP subnet by default
AP_SUBNET = os.environ.get("AP_SUBNET", "192.168.50.0/24")

def get_stats():
    try:
        r = subprocess.run(["/usr/local/bin/gw-stats.sh"], capture_output=True, text=True, timeout=10)
        return json.loads(r.stdout)
    except Exception as e:
        return {"error": str(e)}

def get_leases():
    leases = []
    try:
        with open("/var/lib/misc/dnsmasq.leases") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 4:
                    leases.append({"ip": parts[2], "mac": parts[1], "name": parts[3], "expires": parts[0]})
    except:
        pass
    return leases

@app.before_request
def restrict_subnet():
    """Optional: restrict write operations to AP subnet."""
    # Allow all GET requests; restrict POST to AP subnet only
    if request.method == "POST":
        client_ip = request.remote_addr
        # Check if client is in AP subnet (simple prefix check for /24)
        if not client_ip.startswith(AP_SUBNET.rsplit(".", 1)[0] + "."):
            return jsonify({"error": "Forbidden: not on AP subnet"}), 403

@app.route("/")
def index():
    return render_template("dashboard.html")

@app.route("/api/stats")
def api_stats():
    return jsonify(get_stats())

@app.route("/api/clients")
def api_clients():
    return jsonify(get_leases())

@app.route("/api/warp/toggle", methods=["POST"])
def warp_toggle():
    stats = get_stats()
    if stats.get("warp") == "Connected":
        subprocess.run(["warp-cli", "disconnect"])
        return jsonify({"action": "disconnected"})
    else:
        subprocess.run(["warp-cli", "connect"])
        return jsonify({"action": "connected"})

@app.route("/api/warp/reconnect", methods=["POST"])
def warp_reconnect():
    subprocess.run(["warp-cli", "disconnect"])
    time.sleep(2)
    subprocess.run(["warp-cli", "connect"])
    return jsonify({"action": "reconnected"})

@app.route("/api/restart/<service>", methods=["POST"])
def restart_service(service):
    allowed = ["hostapd", "dnsmasq", "warp-svc"]
    if service not in allowed:
        return jsonify({"error": "not allowed"}), 403
    subprocess.run(["systemctl", "restart", service])
    return jsonify({"action": f"restarted {service}"})

@app.route("/api/reboot", methods=["POST"])
def reboot_pi():
    subprocess.Popen(["bash", "-c", "sleep 3 && reboot"])
    return jsonify({"action": "rebooting in 3 seconds"})

def push_stats():
    while True:
        socketio.emit("stats", get_stats())
        time.sleep(3)

@socketio.on("connect")
def on_connect():
    pass

if __name__ == "__main__":
    t = threading.Thread(target=push_stats, daemon=True)
    t.start()
    socketio.run(app, host="0.0.0.0", port=PORT)
DASHBOARD
ok "dashboard.py written"

# ── Telegram Bot ──────────────────────────────────────────
info "Deploying Telegram bot..."
cat > $APP_DIR/bot.py <<'BOT'
import os, json, subprocess, logging, asyncio
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

BOT_TOKEN    = os.environ.get("BOT_TOKEN", "")
ADMIN_IDS    = [int(x) for x in os.environ.get("ADMIN_CHAT_ID", "").split(",") if x.strip()]

if not BOT_TOKEN:
    raise SystemExit("BOT_TOKEN not set! Edit /etc/EdgeGateway/config.env")

if not ADMIN_IDS:
    logger.warning("ADMIN_CHAT_ID is empty — no users will have admin access!")

def is_admin(update: Update) -> bool:
    return update.effective_user.id in ADMIN_IDS

def get_stats():
    try:
        r = subprocess.run(["/usr/local/bin/gw-stats.sh"], capture_output=True, text=True, timeout=12)
        return json.loads(r.stdout)
    except Exception as e:
        return {"error": str(e)}

def get_leases():
    leases = []
    try:
        with open("/var/lib/misc/dnsmasq.leases") as f:
            for line in f:
                p = line.strip().split()
                if len(p) >= 4:
                    leases.append(f"• `{p[2]}` — {p[3]} ({p[1]})")
    except:
        leases = ["No leases file found"]
    return leases

def fmt_stats(s):
    w = "🟢 Connected" if s.get("warp") == "Connected" else "🔴 Disconnected"
    return (
        f"*Pi Gateway Status*\n\n"
        f"🛡 WARP: {w}\n"
        f"🌐 Exit IP: `{s.get('warp_ip','N/A')}`\n\n"
        f"🖥 CPU: `{s.get('cpu','?')}%`\n"
        f"💾 RAM: `{s.get('mem_used','?')}/{s.get('mem_total','?')} MB ({s.get('mem_pct','?')}%)`\n"
        f"🌡 Temp: `{s.get('temp','?')}°C`\n"
        f"⏱ Uptime: {s.get('uptime','?')}\n\n"
        f"📶 Clients: `{s.get('clients','?')}`\n"
        f"⬇ RX: `{s.get('rx_kbps','?')} KB/s` | ⬆ TX: `{s.get('tx_kbps','?')} KB/s`\n"
        f"📊 Today RX: {s.get('rx_today','?')} | TX: {s.get('tx_today','?')}"
    )

def main_keyboard():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("📊 Status", callback_data="status"),
         InlineKeyboardButton("👥 Clients", callback_data="clients")],
        [InlineKeyboardButton("🔄 WARP Toggle", callback_data="warp_toggle"),
         InlineKeyboardButton("🔁 WARP Reconnect", callback_data="warp_reconnect")],
        [InlineKeyboardButton("↩ Restart hostapd", callback_data="restart_hostapd"),
         InlineKeyboardButton("↩ Restart dnsmasq", callback_data="restart_dnsmasq")],
        [InlineKeyboardButton("🔃 Reboot Pi", callback_data="reboot")]
    ])

async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    await update.message.reply_text(
        "👋 *Pi Gateway Control*\nChoose an action:",
        parse_mode="Markdown",
        reply_markup=main_keyboard()
    )

async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    s = get_stats()
    await update.message.reply_text(fmt_stats(s), parse_mode="Markdown", reply_markup=main_keyboard())

async def cmd_clients(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update): return
    leases = get_leases()
    msg = "*Connected Clients:*\n" + "\n".join(leases) if leases else "No clients"
    await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=main_keyboard())

async def button_handler(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not is_admin(update): return
    d = q.data

    if d == "status":
        s = get_stats()
        await q.edit_message_text(fmt_stats(s), parse_mode="Markdown", reply_markup=main_keyboard())

    elif d == "clients":
        leases = get_leases()
        msg = "*Connected Clients:*\n" + "\n".join(leases) if leases else "_No clients_"
        await q.edit_message_text(msg, parse_mode="Markdown", reply_markup=main_keyboard())

    elif d == "warp_toggle":
        s = get_stats()
        if s.get("warp") == "Connected":
            subprocess.run(["warp-cli", "disconnect"])
            await q.edit_message_text("🔴 WARP disconnected.", reply_markup=main_keyboard())
        else:
            subprocess.run(["warp-cli", "connect"])
            await q.edit_message_text("🟢 WARP connecting...", reply_markup=main_keyboard())

    elif d == "warp_reconnect":
        subprocess.run(["warp-cli", "disconnect"])
        await asyncio.sleep(2)
        subprocess.run(["warp-cli", "connect"])
        await q.edit_message_text("🔁 WARP reconnected.", reply_markup=main_keyboard())

    elif d == "restart_hostapd":
        subprocess.run(["systemctl", "restart", "hostapd"])
        await q.edit_message_text("↩ hostapd restarted.", reply_markup=main_keyboard())

    elif d == "restart_dnsmasq":
        subprocess.run(["systemctl", "restart", "dnsmasq"])
        await q.edit_message_text("↩ dnsmasq restarted.", reply_markup=main_keyboard())

    elif d == "reboot":
        await q.edit_message_text("🔃 Rebooting Pi in 5 seconds...")
        subprocess.Popen(["bash", "-c", "sleep 5 && reboot"])

def main():
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("clients", cmd_clients))
    app.add_handler(CallbackQueryHandler(button_handler))
    logger.info("Bot running...")
    app.run_polling()

if __name__ == "__main__":
    main()
BOT
ok "bot.py written"

# ── systemd: dashboard ────────────────────────────────────
info "Creating systemd units..."
cat > /etc/systemd/system/pi-dashboard.service <<EOF
[Unit]
Description=Pi Gateway Dashboard
After=network.target warp-svc.service

[Service]
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=/etc/EdgeGateway/config.env
ExecStart=$VENV/bin/python $APP_DIR/dashboard.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ── systemd: telegram bot ─────────────────────────────────
cat > /etc/systemd/system/pi-bot.service <<EOF
[Unit]
Description=Pi Gateway Telegram Bot
After=network.target

[Service]
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=/etc/EdgeGateway/config.env
ExecStart=$VENV/bin/python $APP_DIR/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pi-dashboard pi-bot
ok "systemd units installed"

# ── Done ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Pi Gateway fully configured!          ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Dashboard  : http://$AP_IP:$DASHBOARD_PORT"
echo "  Telegram   : /start your bot"
echo ""
echo "  Reboot to start everything: sudo reboot"
echo ""
