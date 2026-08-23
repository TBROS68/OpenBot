#!/usr/bin/env bash
#
# OpenBot — turn sign-in on for a running deployment.
#
# Configures one OAuth identity provider (Google, Microsoft or Okta), sets the
# admin floor, and restarts the server. While no provider is configured the
# deployment admits every visitor as one administrator; after this runs, sign-in
# is required and only people you admit get in.
#
# BEFORE running: create the OAuth client on the provider's side and register
# the redirect URI this script prints. Sign-in is a two-sided contract, and the
# provider's side cannot be created from here. Run scripts/setup-tls.sh first:
# providers refuse plain-HTTP callbacks on anything but localhost.
#
# Usage (interactive):
#   sudo bash scripts/setup-signin.sh
#
# Usage (non-interactive):
#   sudo SIGNIN_PROVIDER=google SIGNIN_CLIENT_ID=... SIGNIN_CLIENT_SECRET=... \
#        INITIAL_ADMIN_EMAILS=you@example.com bash scripts/setup-signin.sh
#
# Knobs (environment variables, all optional):
#   SIGNIN_PROVIDER         google | microsoft | okta    (default: google)
#   SIGNIN_CLIENT_ID        the provider's client id     (required)
#   SIGNIN_CLIENT_SECRET    the provider's client secret (required)
#   SIGNIN_TENANT_ID        Microsoft directory GUID   (default: common)
#   SIGNIN_ISSUER           Okta issuer URL              (required for okta)
#   INITIAL_ADMIN_EMAILS    comma separated admin floor  (required)
#   INSTALL_DIR             where OpenBot lives          (default: /opt/openbot)

set -euo pipefail

SIGNIN_PROVIDER="${SIGNIN_PROVIDER:-google}"
SIGNIN_CLIENT_ID="${SIGNIN_CLIENT_ID:-}"
SIGNIN_CLIENT_SECRET="${SIGNIN_CLIENT_SECRET:-}"
SIGNIN_TENANT_ID="${SIGNIN_TENANT_ID:-common}"
SIGNIN_ISSUER="${SIGNIN_ISSUER:-}"
INITIAL_ADMIN_EMAILS="${INITIAL_ADMIN_EMAILS:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/openbot}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
info()  { printf '\033[2m%s\033[0m\n' "$1"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

die() { red "$1"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  die "Run as root: sudo bash $0"
fi

[ -f "$INSTALL_DIR/.env" ] || die "$INSTALL_DIR/.env is missing. Run scripts/install-vps.sh first."

case "$SIGNIN_PROVIDER" in
  google|microsoft|okta) ;;
  *) die "SIGNIN_PROVIDER must be google, microsoft or okta (got: $SIGNIN_PROVIDER)" ;;
esac

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

# ---------------------------------------------------------------------------
# 1. The public origin the callbacks come back to
# ---------------------------------------------------------------------------

step "1/4  Public origin"
cd "$INSTALL_DIR"
BETTER_AUTH_URL="$(grep -E '^BETTER_AUTH_URL=' .env | tail -1 | cut -d= -f2-)"
if [ -z "$BETTER_AUTH_URL" ]; then
  BETTER_AUTH_URL="http://localhost:3001"
  info "  BETTER_AUTH_URL unset in .env, assuming $BETTER_AUTH_URL"
fi
case "$BETTER_AUTH_URL" in
  https://*) green "  callbacks return to $BETTER_AUTH_URL" ;;
  *) die "$BETTER_AUTH_URL is not https. Providers refuse plain-HTTP callbacks on a public host. Run scripts/setup-tls.sh <domain> first." ;;
esac
DOMAIN="${BETTER_AUTH_URL#https://}"
DOMAIN="${DOMAIN%%/*}"
CALLBACK="$BETTER_AUTH_URL/api/auth/callback/$SIGNIN_PROVIDER"

# ---------------------------------------------------------------------------
# 2. Provider credentials
# ---------------------------------------------------------------------------

step "2/4  Provider credentials ($SIGNIN_PROVIDER)"
cat <<EOF

  Register this redirect URI on the provider's side before continuing:

    $CALLBACK

EOF
SIGNIN_CLIENT_ID="$(ask SIGNIN_CLIENT_ID "Client id: ")"
SIGNIN_CLIENT_SECRET="$(ask SIGNIN_CLIENT_SECRET "Client secret: ")"
if [ "$SIGNIN_PROVIDER" = "okta" ]; then
  SIGNIN_ISSUER="$(ask SIGNIN_ISSUER "Okta issuer (https://<org>.okta.com/oauth2/default): ")"
  [ -n "$SIGNIN_ISSUER" ] || die "Okta needs SIGNIN_ISSUER."
fi
if [ "$SIGNIN_PROVIDER" = "microsoft" ]; then
  SIGNIN_TENANT_ID="$(ask SIGNIN_TENANT_ID "Microsoft tenant id (default: common): ")"
fi

[ -n "$SIGNIN_CLIENT_ID" ] || die "A client id is required."
[ -n "$SIGNIN_CLIENT_SECRET" ] || die "A client secret is required."

# ---------------------------------------------------------------------------
# 3. Who is an administrator, and the signing secret
# ---------------------------------------------------------------------------

step "3/4  Administrator floor"
INITIAL_ADMIN_EMAILS="$(ask INITIAL_ADMIN_EMAILS "Administrator email(s), comma separated: ")"
[ -n "$INITIAL_ADMIN_EMAILS" ] || die "INITIAL_ADMIN_EMAILS is required: nothing else grants the administrator role once sign-in is on."

set_env() {
  local name="$1" value="$2" tmp
  tmp="$(mktemp)"
  grep -vE "^$name=" .env > "$tmp" || true
  printf '%s=%s\n' "$name" "$value" >> "$tmp"
  mv "$tmp" .env
}

# The signing secret, generated once and kept. At least 32 characters is a
# startup requirement, so an existing one is left alone rather than rotated
# under a running session store.
BETTER_AUTH_SECRET="$(grep -E '^BETTER_AUTH_SECRET=' .env | tail -1 | cut -d= -f2-)"
if [ "${#BETTER_AUTH_SECRET}" -lt 32 ]; then
  BETTER_AUTH_SECRET="$(openssl rand -base64 32)"
  set_env BETTER_AUTH_SECRET "$BETTER_AUTH_SECRET"
  info "  generated BETTER_AUTH_SECRET"
fi

set_env INITIAL_ADMIN_EMAILS "$INITIAL_ADMIN_EMAILS"

case "$SIGNIN_PROVIDER" in
  google)
    set_env GOOGLE_OAUTH_CLIENT_ID "$SIGNIN_CLIENT_ID"
    set_env GOOGLE_OAUTH_CLIENT_SECRET "$SIGNIN_CLIENT_SECRET"
    ;;
  microsoft)
    set_env MICROSOFT_OAUTH_CLIENT_ID "$SIGNIN_CLIENT_ID"
    set_env MICROSOFT_OAUTH_CLIENT_SECRET "$SIGNIN_CLIENT_SECRET"
    set_env MICROSOFT_OAUTH_TENANT_ID "$SIGNIN_TENANT_ID"
    ;;
  okta)
    set_env OKTA_OAUTH_CLIENT_ID "$SIGNIN_CLIENT_ID"
    set_env OKTA_OAUTH_CLIENT_SECRET "$SIGNIN_CLIENT_SECRET"
    set_env OKTA_OAUTH_ISSUER "$SIGNIN_ISSUER"
    ;;
esac

# With a provider configured the server stops admitting everybody, whatever
# this says; turning it off here keeps .env honest.
set_env OPENBOT_SINGLE_USER false
green "  .env updated"

# ---------------------------------------------------------------------------
# 4. Restart and verify
# ---------------------------------------------------------------------------

step "4/4  Restart and verify"
SERVER_PORT="$(grep -E '^PORT=' .env | tail -1 | cut -d= -f2-)"
SERVER_PORT="${SERVER_PORT:-3001}"
systemctl restart openbot
READY=0
for _ in $(seq 1 45); do
  if curl -fsS --max-time 5 "http://localhost:$SERVER_PORT/api/capabilities" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

if [ "$READY" != "1" ]; then
  red "  openbot did not come back. A half-configured provider stops startup."
  red "  Debug with: journalctl -u openbot -n 100"
  exit 1
fi
green "  openbot is back up with sign-in on"

cat <<EOF

$(green "Sign-in is live.")

  Open:         https://$DOMAIN
  Provider:     $SIGNIN_PROVIDER (redirect URI: $CALLBACK)
  Administrators: $INITIAL_ADMIN_EMAILS

Sign in with one of the addresses above; it is promoted to administrator
automatically. Everybody else who signs in arrives as a plain user and is
listed under Admin -> People, where you decide who stays.

More providers later: re-run this script with another SIGNIN_PROVIDER, or
register SAML / OIDC at Admin -> Identity providers while signed in.
EOF
