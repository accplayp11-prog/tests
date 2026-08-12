#!/bin/bash
# Keeps the PTERODACTYL NETWORK LAB stack alive on mc-lab-cs1 (single node).
# Panel + MariaDB via docker compose; wings daemon on host 8081; 5 MC servers via wings.
# Called on every keep-alive ping (every ~20 min). Idempotent.
set -u

STACK_DIR=/home/codespace/pterodactyl-lab
DIR=/workspaces/tests/.keepalive
CF="$STACK_DIR/bin/cloudflared"
WINGS_CFG="$STACK_DIR/wings/config.yml"
TOKEN=ATAoUGhhIgT2z0n3lo1o6ulPoGfmg0W19D9VLKacVCPKVe9KFIzyLMCIDFBBKHsd
VEL_UUID=91f0bb96-bf24-4070-8ca3-4be1436a2a4f
SERVERS="$VEL_UUID 856914c7-7f52-4255-a922-e12566047a48 9f44cb25-df80-4803-867f-c92ab991c1af 7fd14cb1-d8da-42ab-9c51-64e86faf5057 3f840f96-ddd5-4c56-8ce6-d02624fa1478"
PINGGY_LOG="$DIR/pinggy-mc.log"

# --- 1) panel + database (docker compose) ---
if [ -f "$STACK_DIR/docker-compose.yml" ]; then
  (cd "$STACK_DIR" && sudo docker compose up -d >/dev/null 2>&1 || true)
fi
sudo docker start ptero-panel ptero-database >/dev/null 2>&1 || true

# --- 2) wings daemon (host process, api on 8081) ---
if ! pgrep -f "wings --config" >/dev/null 2>&1; then
  sudo nohup "$STACK_DIR/bin/wings" --config "$WINGS_CFG" >>/var/log/pterodactyl/wings.log 2>&1 &
  sleep 12
fi

# --- 3) cloudflared tunnel: wings API (https://127.0.0.1:443) ---
if ! pgrep -f "cloudflared tunnel --url https://127.0.0.1:443" >/dev/null 2>&1; then
  sudo nohup "$CF" tunnel --url https://127.0.0.1:443 --no-tls-verify --no-autoupdate >"$DIR/wings-tunnel.log" 2>&1 &
  sleep 12
fi
WHOST=$(sudo grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" "$DIR/wings-tunnel.log" 2>/dev/null | head -1)
[ -n "$WHOST" ] && echo "$WHOST" > "$DIR/wings-hostname.txt"

# --- 4) cloudflared tunnel: panel (127.0.0.1:8080) ---
if ! pgrep -f "cloudflared tunnel --url http://127.0.0.1:8080" >/dev/null 2>&1; then
  sudo nohup "$CF" tunnel --url http://127.0.0.1:8080 --no-autoupdate >"$DIR/panel-tunnel.log" 2>&1 &
  sleep 10
fi
PHOST=$(sudo grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" "$DIR/panel-tunnel.log" 2>/dev/null | head -1)
[ -n "$PHOST" ] && echo "https://$PHOST" > "$DIR/panel-address.txt"

# --- 5) ensure all 5 MC servers are running (via wings API) ---
for U in $SERVERS; do
  if ! sudo docker ps --format "{{.Names}}" | grep -q "^${U}$"; then
    curl -sk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d '{"action":"start"}' "https://127.0.0.1:443/api/servers/$U/power" >/dev/null 2>&1
  fi
done

# --- 6) pinggy TCP tunnel -> velocity (public MC address) ---
VEL_IP=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $VEL_UUID 2>/dev/null | tr -d ' \n')
if [ -z "$VEL_IP" ] || ! pgrep -f "tcp@free.pinggy.io" >/dev/null 2>&1 || ! pgrep -af "tcp@free.pinggy.io" | grep -qE "-R0:${VEL_IP}:25565"; then
  sudo pkill -f "tcp@free.pinggy.io" >/dev/null 2>&1 || true
  sleep 2
  # fall back to the docker bridge gateway: 25565 is always published there
  [ -n "$VEL_IP" ] || VEL_IP=172.41.0.1
  sudo nohup ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -T -p 443 -R0:$VEL_IP:25565 tcp@free.pinggy.io >"$PINGGY_LOG" 2>&1 &
  sleep 16
fi
MCADDR=$(sudo grep -oE "tcp://[a-z0-9-]+\.(run\.pinggy-free\.link|free\.pinggy\.net):[0-9]+" "$PINGGY_LOG" 2>/dev/null | head -1)
[ -n "$MCADDR" ] && echo "$MCADDR" > "$DIR/mc-address.txt"

# --- 7) keep node fqdn in sync with the wings tunnel hostname ---
if [ -n "$WHOST" ]; then
  sudo docker exec ptero-database sh -c "mariadb -upterodactyl -pptero_test_password panel -e \"UPDATE nodes SET fqdn='$WHOST', scheme='https', daemonListen=443, behind_proxy=1 WHERE id=1;\"" >/dev/null 2>&1 || true
fi

# --- 8) publish current tunnel addresses to the repo ---
if git -C /workspaces/tests rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C /workspaces/tests add .keepalive/panel-address.txt .keepalive/wings-hostname.txt .keepalive/mc-address.txt 2>/dev/null
  if ! git -C /workspaces/tests diff --cached --quiet 2>/dev/null; then
    git -C /workspaces/tests commit -m "sync tunnel addresses" -q 2>/dev/null
    git -C /workspaces/tests push -q 2>/dev/null || true
  fi
fi

echo "stack ok"

