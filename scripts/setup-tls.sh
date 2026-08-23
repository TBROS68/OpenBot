#!/usr/bin/env bash
#
# OpenBot — put TLS and a domain name in front of a running deployment.
#
# Installs Caddy as an automatic-HTTPS reverse proxy in front of the OpenBot
# server (port 3001), then points .env at the public origin so future
# sign-in cookies and OAuth callbacks use the real domain.
#
# BEFORE running: point an A record of your domain at this VPS's public IP.
# Caddy obtains its certificate over HTTP-01, which fails until DNS resolves.
#
# Usage:
#   sudo bash scripts/setup-tls.sh example.com
#   or: sudo DOMAIN=example.com bash scripts/setup-tls.sh
#
# Knobs (environment variables, all optional):
#   DOMAIN        the domain OpenBot will answer on (or the first argument)
#   INSTALL_DIR   where OpenBot lives (default: /opt/openbot)
#   SERVER_PORT   the local port the OpenBot server listens on (default: 3001)

set -euo pipefail

DOMAIN="${1:-${DOMAIN:-}}"
INSTALL_DIR="${INSTALL_DIR:-/opt/openbot}"
SERVER_PORT="${SERVER_PORT:-3001}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
info()  { printf '\033[2m%s\033[0m\n' "$1"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

die() { red "$1"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  die "Run as root: sudo bash $0 <domain>"
fi

if [ -z "$DOMAIN" ]; then
  if [ -t 0 ]; then
    read -rp "Domain name for this deployment (e.g. openbot.example.com): " DOMAIN </dev/tty || true
  fi
  [ -n "$DOMAIN" ] || die "A domain is required: sudo bash $0 <domain>"
fi

if [ ! -f "$INSTALL_DIR/.env" ]; then
  die "$INSTALL_DIR/.env is missing. Run scripts/install-vps.sh first."
fi

# ---------------------------------------------------------------------------
# 1. DNS must resolve here before a certificate can be issued
# ---------------------------------------------------------------------------

step "1/4  DNS"
RESOLVED="$(getent hosts "$DOMAIN" | awk '{print $1; exit}')"
if [ -z "$RESOLVED" ]; then
  die "$DOMAIN does not resolve. Add an A record pointing at this VPS's public IP, wait for it to propagate, and re-run."
fi
info "  $DOMAIN -> $RESOLVED"

# ---------------------------------------------------------------------------
# 2. Caddy, the reverse proxy that owns the certificate
# ---------------------------------------------------------------------------

step "2/4  Caddy"
if ! command -v caddy >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
  green "  caddy installed"
else
  info "  caddy already present: $(caddy version)"
fi

# Everything reaches OpenBot through the proxy; the direct port stops being
# public. Loopback keeps the proxy's own path working.
cat > /etc/caddy/Caddyfile <<EOF
# OpenBot. Caddy obtains and renews the certificate automatically.
$DOMAIN {
	reverse_proxy localhost:$SERVER_PORT
}
EOF

caddy validate --config /etc/caddy/Caddyfile >/dev/null
systemctl enable --now caddy >/dev/null 2>&1 || systemctl restart caddy
systemctl reload caddy 2>/dev/null || systemctl restart caddy
green "  Caddyfile written, caddy reloaded"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  # The product is behind the proxy now; its own port no longer needs to be public.
  ufw delete allow "$SERVER_PORT/tcp" >/dev/null 2>&1 || true
  info "  ufw: allowed 80,443; closed $SERVER_PORT"
fi

# ---------------------------------------------------------------------------
# 3. Point .env at the public origin
# ---------------------------------------------------------------------------

step "3/4  OpenBot configuration"
cd "$INSTALL_DIR"

# Set or replace one KEY=VALUE line in .env.
set_env() {
  local name="$1" value="$2" tmp
  tmp="$(mktemp)"
  grep -vE "^$name=" .env > "$tmp" || true
  printf '%s=%s\n' "$name" "$value" >> "$tmp"
  mv "$tmp" .env
}

# Where OAuth callbacks come back to, and which origins the app is served from.
# Both must be the public origin, or sign-in cookies and callbacks break the
# moment an identity provider is configured.
set_env BETTER_AUTH_URL "https://$DOMAIN"
set_env TRUSTED_ORIGINS "https://$DOMAIN"

systemctl restart openbot
green "  .env updated, openbot restarted"

# ---------------------------------------------------------------------------
# 4. Health check over real HTTPS
# ---------------------------------------------------------------------------

step "4/4  Health check"
READY=0
for _ in $(seq 1 45); do
  if curl -fsS --max-time 5 "https://$DOMAIN/api/capabilities" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

if [ "$READY" != "1" ]; then
  red "  https://$DOMAIN is not answering yet."
  red "  The certificate may still be issuing; check: journalctl -u caddy -n 50"
  red "  The server itself: journalctl -u openbot -n 50"
  exit 1
fi
green "  https://$DOMAIN is serving OpenBot over TLS"

cat <<EOF

$(green "TLS is live.")

  Product:      https://$DOMAIN
  Direct chat:  https://$DOMAIN/bot
  Coworkers:    https://$DOMAIN/agents
  Audit trail:  https://$DOMAIN/admin/audit

Certificates renew automatically; nothing to schedule.

Sign-in can be configured now: scripts/setup-signin.sh walks through Google,
Microsoft or Okta (or register SAML / OIDC at Admin -> Identity providers
later). BETTER_AUTH_URL already points at https://$DOMAIN.
EOF
