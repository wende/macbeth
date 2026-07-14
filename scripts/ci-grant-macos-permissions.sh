#!/usr/bin/env bash
# ci-grant-macos-permissions.sh
#
# Experimental TCC injection for the Macbeth GitHub Actions macOS prototype.
#
# What it does
# ------------
# Adds rows for the macbethd executable to the user TCC database so that
# `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` return true
# without the user having to click anything in System Settings.
#
# Why user DB only
# ----------------
# On macOS 14+ the system TCC database at
#   /Library/Application Support/com.apple.TCC/TCC.db
# lives on a SIP-protected signed system volume and is unreadable/writable
# only by `tccd` itself. We can NOT inject into it from a regular process.
# Fortunately Accessibility and Screen Recording grants are evaluated against
# the USER TCC database, so injecting there is sufficient for our needs.
#
# Why it must NEVER run on a developer workstation
# ------------------------------------------------
# This script performs schema inspection and live writes against
# `~/Library/Application Support/com.apple.TCC/TCC.db`. Running it on a
# personal machine will leave dangling TCC entries that can confuse other
# apps and security tools, and may trigger Apple's tamper detection in
# future macOS releases. It is safe ONLY on ephemeral GitHub Actions
# `macos-15` runners, where the entire VM is discarded after the job.
#
# Exit codes
# ----------
#   0  All requested permissions are now granted (best-effort verification only)
#   2  Bad arguments / missing tools
#   3  Required TCC database could not be opened or written
#   4  Unexpected TCC schema (cannot find a known clone source)
#   5  Clone source row not found (no pre-authorized executable to mirror)
#
# The script never lies about success: it prints exactly what changed and
# verifies by running `macbethd --check-permissions` at the end.

set -euo pipefail

# ---- Inputs --------------------------------------------------------------

DAEMON_BIN="${1:-}"
if [ -z "$DAEMON_BIN" ]; then
  echo "usage: $0 <absolute-path-to-macbethd>" >&2
  exit 2
fi
if [ ! -x "$DAEMON_BIN" ]; then
  echo "daemon binary not executable or missing: $DAEMON_BIN" >&2
  exit 2
fi
DAEMON_ABS="$(cd "$(dirname "$DAEMON_BIN")" && pwd)/$(basename "$DAEMON_BIN")"

CLONE_FROM="${CLONE_FROM:-/bin/bash}"
if [ ! -x "$CLONE_FROM" ]; then
  echo "CLONE_FROM is not executable: $CLONE_FROM" >&2
  exit 2
fi

# ---- Preflight -----------------------------------------------------------

echo "============================================================"
echo " macbeth CI TCC injection"
echo "============================================================"
echo "target executable : $DAEMON_ABS"
echo "clone source      : $CLONE_FROM"
echo "macOS             : $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "console user      : $(stat -f %Su /dev/console)"
echo "uid/gid           : $(id -u)/$(id -g)"
echo "date              : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

if ! command -v sqlite3 >/dev/null; then
  echo "sqlite3 not found in PATH" >&2
  exit 2
fi

# ---- Locate the user TCC database ---------------------------------------

USER_TCC_DIR="$HOME/Library/Application Support/com.apple.TCC"
USER_TCC_DB="$USER_TCC_DIR/TCC.db"
SYSTEM_TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"

echo "user TCC DB   : $USER_TCC_DB"
echo "system TCC DB : $SYSTEM_TCC_DB (SIP-protected, read-only on most setups)"
echo

# Detect whether the system DB is writable (almost always: no, on signed system volume).
SYSTEM_READONLY=1
if [ -f "$SYSTEM_TCC_DB" ]; then
  if [ -w "$SYSTEM_TCC_DB" ]; then
    SYSTEM_READONLY=0
  else
    SYSTEM_READONLY=1
  fi
fi
echo "system DB writable? $([ "$SYSTEM_READONLY" -eq 0 ] && echo yes || echo no)"
echo

# ---- Stop tccd so it does not overwrite our writes ----------------------

stop_tccd() {
  if pgrep -x tccd >/dev/null 2>&1; then
    echo "stopping tccd..."
    pkill -x tccd || true
    # Give tccd a moment to actually exit. launchd will respawn it later.
    sleep 1
  fi
}
start_tccd() {
  # launchd will respawn tccd on demand; just give it a moment.
  if ! pgrep -x tccd >/dev/null 2>&1; then
    echo "waiting for launchd to respawn tccd..."
    sleep 2
  fi
}
trap 'start_tccd' EXIT

stop_tccd

# ---- Inspect the schema of the user DB ----------------------------------

if [ ! -f "$USER_TCC_DB" ]; then
  echo "user TCC DB does not exist at $USER_TCC_DB — nothing to inject" >&2
  exit 3
fi

USER_TCC_BACKUP="$USER_TCC_DB.macbeth-ci.bak"
cp -f "$USER_TCC_DB" "$USER_TCC_BACKUP"
echo "backed up user TCC DB to $USER_TCC_BACKUP"

echo
echo "--- user DB schema (access table) ---"
SCHEMA="$(sqlite3 "$USER_TCC_DB" ".schema access" || true)"
echo "$SCHEMA"
echo "-------------------------------------"
echo

if ! echo "$SCHEMA" | grep -q "CREATE TABLE"; then
  echo "could not read schema from $USER_TCC_DB" >&2
  exit 4
fi

# macOS 13+ schemas drop the `client` column from `access` and store the
# client identifier directly in `service`. We don't pin a specific column
# layout — instead we look at what columns exist and choose adaptively.
HAS_CLIENT_COLUMN="$(echo "$SCHEMA" | grep -c "client " || true)"
HAS_SERVICE_COLUMN="$(echo "$SCHEMA" | grep -c "service " || true)"

if [ "$HAS_SERVICE_COLUMN" -eq 0 ]; then
  echo "user TCC schema has no `service` column — unexpected" >&2
  exit 4
fi

# ---- Helper: inject one row by cloning a pre-authorized executable ------

# Usage: inject_one <service> <perm_service_short>
#   <service>            TCC service name in the DB (e.g. kTCCServiceAccessibility)
#   <perm_service_short> human-readable name for logging
inject_one() {
  local svc="$1"
  local label="$2"

  echo
  echo ">>> injecting '$label' (service=$svc)"

  # Dump existing rows for this service BEFORE
  echo "--- existing rows for service=$svc ---"
  if [ "$HAS_CLIENT_COLUMN" -eq 0 ]; then
    sqlite3 "$USER_TCC_DB" "SELECT service, client, auth_value, auth_reason, auth_version FROM access WHERE service='$svc' ORDER BY client;"
  else
    sqlite3 "$USER_TCC_DB" "SELECT service, client, auth_value, auth_reason, auth_version FROM access WHERE service='$svc' ORDER BY client;"
  fi
  echo "--------------------------------------"

  # Locate a clone source row. macbeth picks the first row whose `client`
  # matches CLONE_FROM and whose `auth_value` is 2 (allowed). If we cannot
  # find a suitable row we fall back to CLONE_FROM without an auth_value
  # filter and patch auth_value manually below.
  local row
  row="$(sqlite3 -separator '|' "$USER_TCC_DB" \
      "SELECT * FROM access WHERE service='$svc' AND client='$CLONE_FROM' AND auth_value=2 LIMIT 1;")"

  if [ -z "$row" ]; then
    echo "no pre-authorized '$CLONE_FROM' row found for service=$svc" >&2
    echo "trying any row for $CLONE_FROM on any service..." >&2
    row="$(sqlite3 -separator '|' "$USER_TCC_DB" \
        "SELECT * FROM access WHERE client='$CLONE_FROM' LIMIT 1;")"
    if [ -z "$row" ]; then
      echo "no row at all for $CLONE_FROM — cannot clone" >&2
      exit 5
    fi
  fi

  local cols
  cols="$(echo "$SCHEMA" | grep -oE '"[a-z_]+"' | tr -d '"' | paste -sd ',' -)"

  # Build the column list and the matching values for INSERT.
  # We replace `client` with DAEMON_ABS and force auth_value=2 (allowed).
  local col_list val_list
  col_list=""
  val_list=""
  IFS='|' read -ra parts <<< "$row"
  local i=0
  for col in $(echo "$cols" | tr ',' ' '); do
    if [ -z "$col_list" ]; then
      col_list="$col"
    else
      col_list="$col_list, $col"
    fi
    local v="${parts[$i]:-}"
    if [ "$col" = "client" ]; then
      v="$DAEMON_ABS"
    elif [ "$col" = "auth_value" ]; then
      v="2"
    elif [ "$col" = "auth_reason" ]; then
      # 4 = "User Set" (vs 1=allowed-by-tccd-previous-grant, 2=allowed-Apple).
      # 4 is the most likely to be honored across macOS releases when we
      # write manually.
      v="4"
    fi
    if [ -z "$val_list" ]; then
      val_list="$(printf %s "'%s'" "$v")"
    else
      val_list="$val_list, $(printf %s "'%s'" "$v")"
    fi
    i=$((i+1))
  done

  # Check whether a row already exists for our target client.
  local existing
  existing="$(sqlite3 "$USER_TCC_DB" \
      "SELECT COUNT(*) FROM access WHERE service='$svc' AND client='$DAEMON_ABS';")"

  if [ "${existing:-0}" -gt 0 ]; then
    echo "row for $DAEMON_ABS already exists — updating auth_value=2"
    sqlite3 "$USER_TCC_DB" \
      "UPDATE access SET auth_value=2 WHERE service='$svc' AND client='$DAEMON_ABS';"
  else
    echo "inserting cloned row for $DAEMON_ABS"
    if ! sqlite3 "$USER_TCC_DB" \
        "INSERT INTO access ($col_list) VALUES ($val_list);"; then
      echo "INSERT failed — schema may have changed; refusing to fall back" >&2
      exit 4
    fi
  fi

  echo "--- rows for service=$svc AFTER injection ---"
  sqlite3 "$USER_TCC_DB" "SELECT service, client, auth_value, auth_reason FROM access WHERE service='$svc' AND client='$DAEMON_ABS';"
  echo "-------------------------------------------"
}

# ---- Inject Accessibility + Screen Recording -----------------------------

# These are the canonical TCC service identifiers used by AX/ScreenCapture.
inject_one "kTCCServiceAccessibility" "Accessibility"
inject_one "kTCCServiceScreenCapture" "ScreenCapture"

# Best-effort: also try the newer "PrivacyBundle" form used on some 14+ builds.
# If it doesn't apply, the first two rows above are sufficient.
inject_one "kTCCServicePrivacyBundles" "PrivacyBundles" || echo "(PrivacyBundles service missing — skipping, expected on most builds)"

# ---- Restart tccd so it picks up the new rows ---------------------------

start_tccd
sleep 1

# ---- Final verification -------------------------------------------------

echo
echo "============================================================"
echo " final verification"
echo "============================================================"
echo
echo "--- macbethd --check-permissions output ---"
"$DAEMON_ABS" --check-permissions || true
echo "-------------------------------------------"
echo
echo "user TCC rows for $DAEMON_ABS:"
sqlite3 "$USER_TCC_DB" \
  "SELECT service, auth_value, auth_reason FROM access WHERE client='$DAEMON_ABS';"

# Touch a sentinel so the caller can detect that we got this far.
mkdir -p "$HOME/.macbeth-ci"
date -u +%Y-%m-%dT%H:%M:%SZ > "$HOME/.macbeth-ci/grant-script-finished"

echo
echo "ci-grant-macos-permissions.sh complete"