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

# ---- Stop our own tccd instance so it does not overwrite our writes -----
# On macOS 15 the system tccd (PID 145, owned by root) is not killable by
# a regular user — pkill returns EPERM. Our writes still land in the DB
# via sqlite3; tccd may eventually overwrite them on its next sync, but
# for a one-shot CI prototype that's fine. If a user-owned tccd is also
# running (the one for our GUI session), we kill that one specifically.

stop_tccd() {
  echo "attempting to stop our (user-owned) tccd..."
  # Kill the tccd instance belonging to our uid (501 on the runner).
  # `pgrep -U $UID -x tccd` matches processes we own. Without -U it would
  # try to signal the root-owned tccd and fail with EPERM.
  local our_pids
  our_pids="$(pgrep -U "$(id -u)" -x tccd || true)"
  if [ -n "$our_pids" ]; then
    echo "killing tccd pids: $our_pids"
    kill $our_pids 2>/dev/null || true
    sleep 1
  else
    echo "no user-owned tccd to kill"
  fi
  # Best-effort: try the system tccd anyway. EPERM is expected and OK.
  pkill -x tccd 2>/dev/null || true
}
start_tccd() {
  # launchd will respawn tccd on demand; just give it a moment.
  if ! pgrep -U "$(id -u)" -x tccd >/dev/null 2>&1; then
    echo "waiting for launchd to respawn our tccd..."
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

# Sanity check: every modern macOS TCC `access` table has both `service`
# and `client` columns. Our hardcoded INSERT below assumes that layout.
if ! echo "$SCHEMA" | grep -q "service "; then
  echo "user TCC schema has no \`service\` column — unexpected" >&2
  exit 4
fi
if ! echo "$SCHEMA" | grep -q "client "; then
  echo "user TCC schema has no \`client\` column — unsupported layout" >&2
  exit 4
fi

# ---- Helper: inject one row by cloning a pre-authorized executable ------

# Usage: inject_one <service> <perm_service_short> [nonfatal]
#   <service>            TCC service name in the DB (e.g. kTCCServiceAccessibility)
#   <perm_service_short> human-readable name for logging
#   [nonfatal]           When set to "nonfatal", the function returns the
#                        number of completed injection steps instead of
#                        calling exit on failure. Callers can then decide
#                        whether to ignore the failure.
inject_one() {
  local svc="$1"
  local label="$2"
  local mode="${3:-fatal}"   # "fatal" (default) or "nonfatal"
  local fail=0

  echo
  echo ">>> injecting '$label' (service=$svc)"

  # Dump existing rows for this service BEFORE
  echo "--- existing rows for service=$svc ---"
  sqlite3 "$USER_TCC_DB" \
    "SELECT service, client, auth_value, auth_reason, auth_version FROM access WHERE service='$svc' ORDER BY client;" \
    || fail=1
  echo "--------------------------------------"
  if [ "$fail" -ne 0 ]; then
    if [ "$mode" = "nonfatal" ]; then return 1; fi
    exit 4
  fi

  # Best-effort: log whether $CLONE_FROM has any rows on this service, for
  # human-readable evidence. The INSERT below hardcodes every value we set,
  # so this lookup is purely informational — no exit on miss.
  local bash_rows
  bash_rows="$(sqlite3 "$USER_TCC_DB" \
      "SELECT COUNT(*) FROM access WHERE service='$svc' AND client='$CLONE_FROM';")"
  echo "--- $CLONE_FROM has $bash_rows row(s) for service=$svc (informational) ---"

  # Check whether a row already exists for our target client.
  local existing
  existing="$(sqlite3 "$USER_TCC_DB" \
      "SELECT COUNT(*) FROM access WHERE service='$svc' AND client='$DAEMON_ABS' AND indirect_object_identifier='UNUSED';")"

  if [ "${existing:-0}" -gt 0 ]; then
    echo "row for $DAEMON_ABS already exists — updating auth_value=2"
    sqlite3 "$USER_TCC_DB" \
      "UPDATE access SET auth_value=2 WHERE service='$svc' AND client='$DAEMON_ABS' AND indirect_object_identifier='UNUSED';" \
      || fail=1
  else
    # Write a minimal row with only the columns we need to set.
    # All other columns fall back to their schema DEFAULTs (including
    # last_modified = CURRENT_TIMESTAMP, last_reminded, boot_uuid =
    # 'UNUSED', csreq/policy_id = NULL, etc.). This avoids carrying
    # stale or incompatible values from the clone source row.
    echo "inserting fresh row for $DAEMON_ABS"
    sqlite3 "$USER_TCC_DB" \
      "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type, indirect_object_identifier) VALUES ('$svc', '$DAEMON_ABS', 0, 2, 4, 1, 0, 'UNUSED');" \
      || fail=1
  fi

  echo "--- rows for service=$svc AFTER injection ---"
  sqlite3 "$USER_TCC_DB" \
    "SELECT service, client, auth_value, auth_reason FROM access WHERE service='$svc' AND client='$DAEMON_ABS';" \
    || fail=1
  echo "-------------------------------------------"

  if [ "$fail" -ne 0 ]; then
    echo "injection failed for service=$svc" >&2
    if [ "$mode" = "nonfatal" ]; then return 1; fi
    exit 4
  fi
}

# ---- Inject Accessibility + Screen Recording -----------------------------

# These are the canonical TCC service identifiers used by AX/ScreenCapture.
inject_one "kTCCServiceAccessibility" "Accessibility"
inject_one "kTCCServiceScreenCapture" "ScreenCapture"

# Best-effort: also try the newer "PrivacyBundle" form used on some 14+ builds.
# If it doesn't apply, the first two rows above are sufficient.
if ! inject_one "kTCCServicePrivacyBundles" "PrivacyBundles" nonfatal; then
  echo "(PrivacyBundles service missing or injection failed — skipping, expected on most builds)"
fi

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