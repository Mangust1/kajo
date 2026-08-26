#!/usr/bin/env bash
# Kajo installer — build from source, sign, install to /Applications, register kajo://.
#
# Kajo is source-distributed (swiftc, no Xcode) and code-signed so macOS TCC grants
# (Bluetooth / Location / Calendar / Spotify automation) survive rebuilds. This script
# automates the prereq checks + build + install that the README otherwise hands to
# Claude Code.
#
# Usage:
#   ./install.sh                 # auto: use existing "Kajo Self-Signed" cert, else ad-hoc
#   ./install.sh --self-signed   # create the self-signed cert (TCC persists across rebuilds)
#   ./install.sh --adhoc         # ad-hoc sign ("-"); simplest, but re-approve TCC each rebuild
#
set -euo pipefail

CERT="Kajo Self-Signed"
MODE="auto"
for arg in "$@"; do
  case "$arg" in
    --self-signed) MODE="cert" ;;
    --adhoc)       MODE="adhoc" ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;33m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

cd "$(dirname "$0")"

# 1. Prereqs -----------------------------------------------------------------
say "Checking prerequisites…"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "macOS 14+ required (found $(sw_vers -productVersion))."
command -v make >/dev/null || die "'make' not found."
if ! xcode-select -p >/dev/null 2>&1; then
  say "Xcode Command Line Tools missing — launching installer…"
  xcode-select --install || true
  die "Re-run this script once the Command Line Tools finish installing."
fi
command -v swiftc >/dev/null || die "swiftc not found (Command Line Tools incomplete)."
ok "macOS $(sw_vers -productVersion), make + swiftc present."

# 2. Signing identity --------------------------------------------------------
cert_exists() { security find-certificate -c "$CERT" >/dev/null 2>&1; }

create_cert() {
  say "Creating self-signed code-signing certificate '$CERT'…"
  local tmp; tmp=$(mktemp -d)
  cat > "$tmp/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
      -days 3650 -nodes -config "$tmp/cfg" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -out "$tmp/kajo.p12" -passout pass: -name "$CERT" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  # Import into the login keychain and allow codesign to use the key without prompting.
  security import "$tmp/kajo.p12" -P "" -T /usr/bin/codesign >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  local kc; kc=$(security default-keychain | tr -d ' "')
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$kc" >/dev/null 2>&1 || \
    say "(couldn't set key partition list — codesign may prompt once for keychain access; that's fine)"
  rm -rf "$tmp"
}

SIGN_ID="$CERT"
case "$MODE" in
  adhoc) SIGN_ID="-"; say "Ad-hoc signing (TCC permissions reset on each rebuild)." ;;
  cert)  cert_exists || create_cert || die "Certificate creation failed — try: ./install.sh --adhoc" ;;
  auto)
    if cert_exists; then
      ok "Found existing '$CERT' — using it (TCC persists)."
    else
      SIGN_ID="-"
      say "No '$CERT' cert — ad-hoc signing. (Re-run with --self-signed for persistent TCC grants.)"
    fi ;;
esac

# 3. Build + install ---------------------------------------------------------
say "Building and installing…"
make install SIGN_ID="$SIGN_ID"

[ -d /Applications/Kajo.app ] || die "Install failed — /Applications/Kajo.app not found."
ok "Installed /Applications/Kajo.app (signed: $SIGN_ID)."

# 4. Done --------------------------------------------------------------------
cat <<'EOF'

──────────────────────────────────────────────────────────────
Kajo is installed. A menu-bar icon (▦) appears on launch — click
it for the tab list and Settings.

  • Summon a tab:   open "kajo://tab/calendar"   (music, network, system, …)
  • Open settings:  open "kajo://config"         (or the menu-bar Settings… item)
  • Configure:      the Settings window edits ~/.config/kajo/*.json with templates.

First run will prompt for Bluetooth / Location / Calendar / Spotify as you open
those tabs — approve them. The Network "Wi-Fi priority" toggle additionally needs
a sudoers rule; skip it unless you want that silent switch.
──────────────────────────────────────────────────────────────
EOF
open "kajo://tab/calendar" 2>/dev/null || true
