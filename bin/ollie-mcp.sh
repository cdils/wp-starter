#!/usr/bin/env bash
#
# ollie-mcp.sh — register a project's Ollie MCP server with Claude Code.
#
# Run from a Lando WordPress project root. Ensures the MCP Adapter plugin and
# Ollie Pro's "Ollie AI MCP" extension are in place, mints and verifies a
# WordPress application password, then registers the MCP server at --scope local
# so the registration is bound to this project directory only.
#
# The credential is never echoed. It is rotated on every run, since WordPress
# only reveals an application password once and an unrecoverable one is useless.
#
# The MCP Adapter is not on wordpress.org. Rather than hard-coding a download
# URL, this script asks Ollie Pro to install it — Ollie Pro carries the release
# URL in its own plugin map, so the source stays correct across Ollie updates.
#
# Usage:
#   cd ~/Sites/myproject && ~/Sites/ollie-mcp.sh
#   OLLIE_MCP_USER=cdils ~/Sites/ollie-mcp.sh   # skip the account prompt
#   MCP_ADAPTER_ZIP=/path/to.zip ~/Sites/ollie-mcp.sh   # fallback when no Ollie Pro
#
# Requires: lando (running), wp-cli via lando, claude, curl.

set -euo pipefail

PASSWORD_LABEL="Claude Code MCP"
SERVER_NAME="ollie"

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

# Strip WP-CLI deprecation noise that lando surfaces on stdout.
#
# stdin is redirected from /dev/null because `lando wp` otherwise inherits and
# drains it — which would leave the account prompt below reading at EOF.
wpcli() { lando wp "$@" </dev/null 2>/dev/null | grep -v '^Deprecated:' || true; }

# Boolean form. wpcli() ends in `|| true` to swallow grep's exit status, which
# makes it useless for success/failure tests — use this instead.
wpq() { lando wp "$@" </dev/null >/dev/null 2>&1; }

# Prompt that fails loudly instead of tripping `set -e` silently at EOF.
ask() {
  local __prompt="$1" __var="$2" __reply
  if ! read -rp "$__prompt" __reply; then
    die "No input available (stdin closed). Run interactively, or set OLLIE_MCP_USER."
  fi
  printf -v "$__var" '%s' "$__reply"
}

# --- Preflight ---------------------------------------------------------------

[ -f .lando.yml ] || die "No .lando.yml here. Run this from a Lando project root."
command -v claude >/dev/null 2>&1 || die "'claude' CLI not found in PATH."

wpq core is-installed || die "WordPress isn't responding. Is 'lando start' done?"

# REST lives on home_url(), not site_url() — this is what makes /cms installs work.
HOME_URL=$(wpcli option get home | tail -1 | tr -d '[:space:]')
[ -n "$HOME_URL" ] || die "Could not determine the site's home URL."

MCP_URL="${HOME_URL}/wp-json/mcp/mcp-adapter-default-server"

# --- Choose the account ------------------------------------------------------
# Done early: the plugin install below runs as this user, so the choice must be
# deliberate before anything is installed. Never inferred — on a site whose
# database was pulled from production, the lowest-ID admin is likely a client's.

ADMINS=()
while IFS= read -r line; do
  [ -n "$line" ] && ADMINS+=("$line")
done < <(wpcli user list --role=administrator --fields=user_login,user_email --format=csv | tail -n +2)

[ "${#ADMINS[@]}" -gt 0 ] || die "No administrators found on this site."

if [ -n "${OLLIE_MCP_USER:-}" ]; then
  MCP_USER="$OLLIE_MCP_USER"
else
  echo "Administrators on ${HOME_URL}:"
  i=1
  for entry in "${ADMINS[@]}"; do
    printf '  %d) %s\n' "$i" "$(echo "$entry" | tr ',' '\t')"
    i=$((i + 1))
  done
  echo

  # Only offer a default when there is exactly one candidate. With several
  # accounts a blind Enter could silently target a client's user.
  if [ "${#ADMINS[@]}" -eq 1 ]; then
    ask "Create the MCP application password for which user? [1] " CHOICE
    CHOICE="${CHOICE:-1}"
  else
    ask "Create the MCP application password for which user? " CHOICE
  fi

  case "$CHOICE" in
    ''|*[!0-9]*) die "Invalid selection." ;;
  esac
  [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#ADMINS[@]}" ] || die "Selection out of range."

  MCP_USER=$(echo "${ADMINS[$((CHOICE - 1))]}" | cut -d, -f1)
fi

# The login is interpolated into PHP below; keep it to characters that can't
# break out of a single-quoted string.
case "$MCP_USER" in
  *[!A-Za-z0-9._@-]*) die "Unexpected characters in username '$MCP_USER'." ;;
esac

wpq user get "$MCP_USER" --field=ID || die "User '$MCP_USER' not found on this site."

# An application password inherits the user's capabilities; the Ollie Abilities
# need manage_options, and installing the adapter needs install_plugins.
wpcli user get "$MCP_USER" --field=roles | grep -q administrator \
  || die "'$MCP_USER' is not an administrator — the Ollie Abilities would fail."

echo "Using account: $MCP_USER"

# --- Ollie Pro: enable the Ollie AI MCP extension ----------------------------
# The ollie/* Abilities come from Ollie Pro's 'abilities' extension, labelled
# "Ollie AI MCP" in the admin UI. It defaults to OFF, so a fresh Ollie Pro
# install always needs this flipped.

OLLIE_PRO_ACTIVE=false
if wpq plugin is-active ollie-pro; then
  OLLIE_PRO_ACTIVE=true
  wpq option patch update ollie extensions abilities true --format=json \
    || die "Failed to enable the Ollie AI MCP extension."
  echo "Ollie AI MCP extension: enabled"
else
  echo "Ollie Pro: not active — no ollie/* tools will be exposed."
fi

# --- MCP Adapter -------------------------------------------------------------
# Serves /wp-json/mcp/... by exposing registered Abilities as MCP tools. It is
# NOT on wordpress.org, so `wp plugin install mcp-adapter` cannot resolve it.
#
# Ollie Pro's /ollie/v1/install-plugins endpoint carries the correct release URL
# in its own plugin map and handles download + activation, so we delegate to it
# instead of duplicating a URL that would go stale.

install_adapter_via_ollie() {
  local snippet
  snippet=$(cat <<PHP
\$user = get_user_by( 'login', '${MCP_USER}' );
if ( ! \$user ) { exit( 1 ); }
wp_set_current_user( \$user->ID );
\$req = new WP_REST_Request( 'POST', '/ollie/v1/install-plugins' );
\$req->set_param( 'plugins', array( 'mcp-adapter' ) );
\$res = rest_do_request( \$req );
exit( \$res->is_error() ? 1 : 0 );
PHP
  )
  lando wp eval "$snippet" </dev/null >/dev/null 2>&1
}

if wpq plugin is-active mcp-adapter; then
  echo "MCP Adapter: active"
elif wpq plugin is-installed mcp-adapter; then
  echo "MCP Adapter: installed but inactive — activating..."
  wpq plugin activate mcp-adapter || die "Failed to activate mcp-adapter."
elif [ -n "${MCP_ADAPTER_ZIP:-}" ]; then
  echo "MCP Adapter: installing from \$MCP_ADAPTER_ZIP..."
  wpq plugin install "$MCP_ADAPTER_ZIP" --activate \
    || die "Failed to install mcp-adapter from $MCP_ADAPTER_ZIP"
elif [ "$OLLIE_PRO_ACTIVE" = true ]; then
  echo "MCP Adapter: not installed — asking Ollie Pro to install it..."
  install_adapter_via_ollie || true
  # Trust the observable outcome rather than the endpoint's payload.
  wpq plugin is-active mcp-adapter \
    || die "Ollie Pro could not install the MCP Adapter. Install it manually from
https://github.com/WordPress/mcp-adapter, or point this script at a zip:

  MCP_ADAPTER_ZIP=/path/to/mcp-adapter.zip $(basename "$0")"
  echo "MCP Adapter: installed and activated"
else
  die "The MCP Adapter plugin is not installed, and Ollie Pro isn't active to
supply its download URL. Install it from https://github.com/WordPress/mcp-adapter,
or point this script at a zip you trust:

  MCP_ADAPTER_ZIP=/path/to/mcp-adapter.zip $(basename "$0")"
fi

if [ "$OLLIE_PRO_ACTIVE" != true ]; then
  echo "  Note: without Ollie Pro the server registers, but exposes no ollie/* tools."
fi

# --- Rotate the application password -----------------------------------------

OLD_UUID=$(wpcli user application-password list "$MCP_USER" --fields=uuid,name --format=csv \
  | awk -F, -v label="$PASSWORD_LABEL" '$2 == label || $2 == "\""label"\"" { print $1; exit }')

if [ -n "$OLD_UUID" ]; then
  echo "Revoking previous '$PASSWORD_LABEL' credential..."
  wpcli user application-password delete "$MCP_USER" "$OLD_UUID" >/dev/null
fi

PW=$(lando wp user application-password create "$MCP_USER" "$PASSWORD_LABEL" --porcelain </dev/null 2>/dev/null \
  | grep -v '^Deprecated:' | tail -1 | tr -d '[:space:]')
[ -n "$PW" ] || die "Failed to create an application password."

# --- Verify before registering -----------------------------------------------
# This separates "bad credential" from "bad header/transport". Skipping it is
# what turns a five-second setup into an hour of guessing.

CODE=$(curl -sk -o /dev/null -w '%{http_code}' -u "${MCP_USER}:${PW}" "${HOME_URL}/wp-json/wp/v2/users/me")
if [ "$CODE" != "200" ]; then
  echo "Auth check failed (HTTP $CODE). Not registering." >&2
  echo "Common causes:" >&2
  echo "  - nginx not forwarding the Authorization header to PHP" >&2
  echo "      (add: fastcgi_param HTTP_AUTHORIZATION \$http_authorization;)" >&2
  echo "  - WP_ENVIRONMENT_TYPE undefined, so core reports 'production' and" >&2
  echo "      disables Application Passwords outside real TLS" >&2
  exit 1
fi
echo "Auth check: HTTP 200"

AUTH=$(printf '%s:%s' "$MCP_USER" "$PW" | base64 | tr -d '\n')

# --- Register with Claude Code -----------------------------------------------

claude mcp remove "$SERVER_NAME" >/dev/null 2>&1 || true
claude mcp add --scope local --transport http "$SERVER_NAME" "$MCP_URL" \
  --header "Authorization: Basic ${AUTH}" >/dev/null

echo
echo "Registered '${SERVER_NAME}' -> ${MCP_URL}"
echo "Scope: local (bound to $(pwd))"
echo "Restart your Claude Code session to load the tools."
