#!/usr/bin/env bash
#
# OpenBot — default-deny boundary for social media work.
#
# Writes AGENT_COMPUTER_POLICY into .env: every Bot is refused the dangerous
# moves on social platforms (opening them, posting on them, typing credentials
# into them), while everything else remains allowed and audited. Deny rules are
# evaluated first and beat every allow, and a rule that cannot be evaluated
# counts as a match, so this fails closed.
#
# One ordering rule matters here: a boundary saved on the Admin -> Boundaries
# screen wins over .env at boot. If you ever saved rules there, reset that
# screen to the deployment's configuration before expecting this to apply; the
# screen says so, with a button.
#
# Usage:
#   sudo bash scripts/setup-policy.sh            enforce the social media deny
#   sudo bash scripts/setup-policy.sh --dry-run  record refusals, let everything through
#   sudo bash scripts/setup-policy.sh --off      remove the policy from .env
#
# Knobs (environment variables, all optional):
#   INSTALL_DIR   where OpenBot lives (default: /opt/openbot)

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/openbot}"
MODE="enforce"

for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry-run" ;;
    --off) MODE="off" ;;
    *) printf '\033[31mUnknown argument: %s\033[0m\n' "$arg"; exit 1 ;;
  esac
done

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
info()  { printf '\033[2m%s\033[0m\n' "$1"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

die() { red "$1"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash $0"
[ -f "$INSTALL_DIR/.env" ] || die "$INSTALL_DIR/.env is missing. Run scripts/install-vps.sh first."
cd "$INSTALL_DIR"

# ---------------------------------------------------------------------------
# The default social media deny list.
#
# Guards matter: `element` only exists on clicks and `key` only on keypresses,
# and a deny rule that cannot be evaluated counts as a match, so each clause is
# scoped to the action that carries the field it reads.
# ---------------------------------------------------------------------------

POLICY_JSON='{"mode":"'"$MODE"'","deny":["intent == \"navigate\" && (contains(page.host, \"facebook.com\") || contains(page.host, \"instagram.com\") || contains(page.host, \"x.com\") || contains(page.host, \"twitter.com\") || contains(page.host, \"linkedin.com\") || contains(page.host, \"tiktok.com\") || contains(page.host, \"youtube.com\") || contains(page.host, \"reddit.com\") || contains(page.host, \"threads.net\") || contains(page.host, \"bsky.app\") || contains(page.host, \"t.me\") || contains(page.host, \"telegram.org\") || contains(page.host, \"zalo.me\"))","intent == \"activate\" && (contains(page.host, \"facebook.com\") || contains(page.host, \"instagram.com\") || contains(page.host, \"x.com\") || contains(page.host, \"twitter.com\") || contains(page.host, \"linkedin.com\") || contains(page.host, \"tiktok.com\") || contains(page.host, \"youtube.com\") || contains(page.host, \"reddit.com\") || contains(page.host, \"threads.net\") || contains(page.host, \"bsky.app\")) && (contains(element.name, \"post\") || contains(element.name, \"tweet\") || contains(element.name, \"publish\") || contains(element.name, \"share\") || contains(element.name, \"comment\"))","intent == \"type\" && contains(element.name, \"password\")"],"allow":["true"]}'

step "1/3  Write AGENT_COMPUTER_POLICY"
tmp="$(mktemp)"
grep -vE '^AGENT_COMPUTER_POLICY=' .env > "$tmp" || true
if [ "$MODE" != "off" ]; then
  printf 'AGENT_COMPUTER_POLICY=%s\n' "$POLICY_JSON" >> "$tmp"
fi
mv "$tmp" .env

if [ "$MODE" = "off" ]; then
  info "  removed from .env; the deployment falls back to its built-in allow-everything default"
else
  green "  mode: $MODE"
  info "  deny: never open a social platform, never activate a post/share/comment control on one, never type into a password field"
fi

# ---------------------------------------------------------------------------
# Restart so the new configuration is what the gateway enforces.
# ---------------------------------------------------------------------------

step "2/3  Restart"
systemctl restart openbot
SERVER_PORT="$(grep -E '^PORT=' .env | tail -1 | cut -d= -f2-)"
SERVER_PORT="${SERVER_PORT:-3001}"
READY=0
for _ in $(seq 1 45); do
  if curl -fsS --max-time 5 "http://localhost:$SERVER_PORT/api/capabilities" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
if [ "$READY" != "1" ]; then
  red "  openbot did not come back. A malformed policy stops startup by design."
  red "  Debug with: journalctl -u openbot -n 100"
  exit 1
fi
green "  openbot is back up"

# ---------------------------------------------------------------------------
# Warn about a saved boundary that would shadow this configuration.
# ---------------------------------------------------------------------------

step "3/3  Check the saved boundary"
if command -v psql >/dev/null 2>&1 && [ -n "${DATABASE_URL:-}" ]; then
  SAVED="$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM action_policy WHERE id = 'current'" 2>/dev/null || echo '?')"
else
  SAVED='?'
fi

cat <<EOF

$(green "Policy configuration written.")

  Mode:    $MODE
  Source:  AGENT_COMPUTER_POLICY in $INSTALL_DIR/.env

  One thing can shadow it: a boundary saved on the Admin -> Boundaries screen
  wins over configuration at boot. If rules were ever saved there, open
  Admin -> Boundaries and use "Reset to the deployment's configuration".

  Known limits of a host-list deny, the honest ones:
  - A link that redirects onto a social platform from somewhere else is a
    navigation to the original host, and is allowed until the Bot acts there.
  - Rules match button labels: a platform that names its post button something
    else is not covered by the label rule (the host rule still stands).
  - New platforms are not on the list; add hosts in .env or on the Boundaries
    screen and re-run this script to keep both in agreement.
EOF
