#!/usr/bin/env bash
#
# OpenBot — one-shot VPS installer (Ubuntu/Debian).
#
# Takes a fresh VPS to a running OpenBot deployment:
#   system deps -> Docker -> Bun -> clone -> .env with generated secrets ->
#   docker compose services -> migrations -> app build -> systemd service ->
#   health check.
#
# Usage (interactive):
#   curl -fsSL <raw url of this file> -o install-vps.sh && sudo bash install-vps.sh
#   or, from a checkout: sudo bash scripts/install-vps.sh
#
# Usage (non-interactive, everything from the environment):
#   sudo MODEL_PROVIDER=deepseek MODEL_API_KEY=sk-... \
#        INTELLIGENCE_API_KEY=cpk-... COPILOTKIT_LICENSE_TOKEN=... \
#        bash install-vps.sh
#
# Knobs (environment variables, all optional):
#   REPO_URL              default: https://github.com/TBROS68/OpenBot.git
#   INSTALL_DIR           default: /opt/openbot
#   MODEL_PROVIDER        openai | deepseek          (default: deepseek)
#   MODEL_API_KEY         the provider's key         (required)
#   BOT_MODEL             provider's own model name  (default: provider default)
#   OPENAI_BASE_URL       any OpenAI-compatible endpoint for provider=openai
#   INTELLIGENCE_API_KEY  CopilotKit Intelligence runtime key (required)
#   COPILOTKIT_LICENSE_TOKEN                              (required)
#   PUBLIC_PORT           port the product answers on (default: 3001)
#   OPENBOT_SINGLE_USER   one administrator, no sign-in (default: true)

set -euo pipefail

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/TBROS68/OpenBot.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/openbot}"
MODEL_PROVIDER="${MODEL_PROVIDER:-deepseek}"
MODEL_API_KEY="${MODEL_API_KEY:-}"
BOT_MODEL="${BOT_MODEL:-}"
INTELLIGENCE_API_KEY="${INTELLIGENCE_API_KEY:-}"
COPILOTKIT_LICENSE_TOKEN="${COPILOTKIT_LICENSE_TOKEN:-}"
PUBLIC_PORT="${PUBLIC_PORT:-3001}"
OPENBOT_SINGLE_USER="${OPENBOT_SINGLE_USER:-true}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
info()  { printf '\033[2m%s\033[0m\n' "$1"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

die() { red "$1"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  die "Run as root: sudo bash $0"
fi

case "$MODEL_PROVIDER" in
  openai|deepseek) ;;
  *) die "MODEL_PROVIDER must be openai or deepseek (got: $MODEL_PROVIDER)" ;;
esac

# ---------------------------------------------------------------------------
# 1. System dependencies
# ---------------------------------------------------------------------------

step "1/8  System dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl openssl lsof python3 ca-certificates gnupg >/dev/null
green "  apt packages installed"

# ---------------------------------------------------------------------------
# 2. Docker
# ---------------------------------------------------------------------------

step "2/8  Docker"
if command -v docker >/dev/null 2>&1; then
  info "  docker already present: $(docker --version)"
else
  curl -fsSL https://get.docker.com | sh >/dev/null
  green "  docker installed"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "docker compose plugin is missing"
green "  docker compose available"

# ---------------------------------------------------------------------------
# 3. Bun
# ---------------------------------------------------------------------------

step "3/8  Bun"
export BUN_INSTALL="${BUN_INSTALL:-/usr/local}"
if command -v bun >/dev/null 2>&1; then
  info "  bun already present: $(bun --version)"
else
  curl -fsSL https://bun.sh/install | bash >/dev/null
  green "  bun installed"
fi
BUN_BIN="$(command -v bun || echo "$BUN_INSTALL/bin/bun")"
[ -x "$BUN_BIN" ] || die "bun binary not found after install"

# ---------------------------------------------------------------------------
# 4. Source code
# ---------------------------------------------------------------------------

step "4/8  Source code"
if [ -d "$INSTALL_DIR/.git" ]; then
  info "  $INSTALL_DIR already cloned, pulling latest"
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
green "  source at $INSTALL_DIR"

# ---------------------------------------------------------------------------
# 5. .env with generated secrets
# ---------------------------------------------------------------------------

step "5/8  Configuration"

# Prompt only when a value is missing AND a terminal is attached.
ask() {
  local name="$1" prompt="$2" value="${!1:-}"
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return
  fi
  if [ -t 0 ]; then
    read -rp "$prompt" value </dev/tty || true
  fi
  printf '%s' "$value"
}

MODEL_API_KEY="$(ask MODEL_API_KEY "Model API key for $MODEL_PROVIDER: ")"
INTELLIGENCE_API_KEY="$(ask INTELLIGENCE_API_KEY "CopilotKit Intelligence runtime key (cpk-...): ")"
COPILOTKIT_LICENSE_TOKEN="$(ask COPILOTKIT_LICENSE_TOKEN "CopilotKit license token: ")"

[ -n "$MODEL_API_KEY" ] || die "A model API key is required (MODEL_API_KEY)."
[ -n "$INTELLIGENCE_API_KEY" ] || die "INTELLIGENCE_API_KEY is required. Run 'npx copilotkit@latest login && npx copilotkit@latest project select' on any machine to get one."
[ -n "$COPILOTKIT_LICENSE_TOKEN" ] || die "COPILOTKIT_LICENSE_TOKEN is required. Run 'npx copilotkit@latest license --write' to get one."

KEY_ENCRYPTION_KEY="$(openssl rand -base64 32)"
MANAGED_AGENT_TOKEN="$(openssl rand -base64 32)"
COMPUTER_TOKEN="$(openssl rand -base64 32)"
SUPERVISOR_TOKEN="$(openssl rand -base64 32)"
AGENT_TOOL_TOKEN="$(openssl rand -base64 32)"

cp -n .env.example .env 2>/dev/null || info "  .env already exists, keeping it"

# Set or replace one KEY=VALUE line in .env.
set_env() {
  local name="$1" value="$2" tmp
  tmp="$(mktemp)"
  grep -vE "^$name=" .env > "$tmp" || true
  printf '%s=%s\n' "$name" "$value" >> "$tmp"
  mv "$tmp" .env
}

set_env KEY_ENCRYPTION_KEY "$KEY_ENCRYPTION_KEY"
set_env MANAGED_AGENT_TOKEN "$MANAGED_AGENT_TOKEN"
set_env COMPUTER_TOKEN "$COMPUTER_TOKEN"
set_env SUPERVISOR_TOKEN "$SUPERVISOR_TOKEN"
set_env AGENT_TOOL_TOKEN "$AGENT_TOOL_TOKEN"
set_env INTELLIGENCE_API_KEY "$INTELLIGENCE_API_KEY"
set_env COPILOTKIT_LICENSE_TOKEN "$COPILOTKIT_LICENSE_TOKEN"
set_env BOT_PROVIDER "$MODEL_PROVIDER"
set_env OPENBOT_SINGLE_USER "$OPENBOT_SINGLE_USER"

if [ "$MODEL_PROVIDER" = "deepseek" ]; then
  set_env DEEPSEEK_API_KEY "$MODEL_API_KEY"
  set_env OPENAI_API_KEY ""
else
  set_env OPENAI_API_KEY "$MODEL_API_KEY"
  set_env DEEPSEEK_API_KEY ""
fi
if [ -n "${OPENAI_BASE_URL:-}" ]; then
  set_env OPENAI_BASE_URL "$OPENAI_BASE_URL"
fi
if [ -n "$BOT_MODEL" ]; then
  set_env BOT_MODEL "$BOT_MODEL"
fi

chmod 600 .env
green "  .env written with fresh secrets (chmod 600)"

# ---------------------------------------------------------------------------
# 6. Dependencies and containers
# ---------------------------------------------------------------------------

step "6/8  Dependencies and containers"
"$BUN_BIN" install
export SUPERVISOR_TOKEN COMPUTER_TOKEN MANAGED_AGENT_TOKEN
docker compose up -d --build postgres supervisor agent-computer agent-bot agent-langgraph
if ! docker compose run --rm migrate; then
  die "Database migrations failed. See output above."
fi
green "  containers up, migrations applied"

# ---------------------------------------------------------------------------
# 7. Build the app and install the systemd service
# ---------------------------------------------------------------------------

step "7/8  App build and service"
(cd app && "$BUN_BIN" run build)
APP_DIST="$INSTALL_DIR/app/dist"
[ -f "$APP_DIST/index.html" ] || die "App build did not produce $APP_DIST/index.html"

cat > /etc/systemd/system/openbot.service <<EOF
[Unit]
Description=OpenBot API server and app
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/server
EnvironmentFile=$INSTALL_DIR/.env
Environment=PORT=$PUBLIC_PORT
Environment=APP_DIST_DIR=$APP_DIST
Environment=COMPUTER_SUPERVISOR_URL=http://localhost:4500
ExecStart=$BUN_BIN --env-file=$INSTALL_DIR/.env src/index.ts
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now openbot
green "  openbot.service installed and started"

# ---------------------------------------------------------------------------
# 8. Health check
# ---------------------------------------------------------------------------

step "8/8  Health check"
READY=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 3 "http://localhost:$PUBLIC_PORT/api/capabilities" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

if [ "$READY" != "1" ]; then
  red "  server did not become ready. Debug with: journalctl -u openbot -n 100"
  exit 1
fi
green "  server is answering on port $PUBLIC_PORT"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "$PUBLIC_PORT/tcp" >/dev/null
  info "  ufw: allowed $PUBLIC_PORT/tcp"
fi

IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

cat <<EOF

$(green "OpenBot is running.")

  Product:      http://$IP:$PUBLIC_PORT
  Direct chat:  http://$IP:$PUBLIC_PORT/bot
  Coworkers:    http://$IP:$PUBLIC_PORT/agents
  Audit trail:  http://$IP:$PUBLIC_PORT/admin/audit
  Model:        $MODEL_PROVIDER${BOT_MODEL:+ ($BOT_MODEL)}

Useful commands:
  journalctl -u openbot -f        follow the server log
  systemctl restart openbot       restart after .env changes
  docker compose logs -f          container logs (run from $INSTALL_DIR)
  $INSTALL_DIR/.env               all configuration, secrets included

Before opening this to the internet: put TLS in front of it and configure
sign-in. scripts/setup-tls.sh does the TLS half automatically once a domain
points at this machine: sudo bash scripts/setup-tls.sh your.domain.com
Sign-in stays off while OPENBOT_SINGLE_USER=true, which makes every visitor
the one administrator. See docs/configuration.md.
EOF
