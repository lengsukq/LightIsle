#!/usr/bin/env bash
# Create and register a persistent local macOS code-signing identity
# ("LightIsle Local Dev") in the user's login Keychain so local rebuilds and
# reinstalls of LightIsle.app and LightIsle Client.app preserve a stable
# certificate anchor instead of rotating ad-hoc CDHashes on every build.
#
# Uses only Apple's standard /usr/bin/openssl and /usr/bin/security CLI tools
# and never bypasses macOS user authorization prompts.
#
# Usage:
#   bash scripts/setup-macos-signing.sh           # Create/import if missing; prompt trust when interactive
#   bash scripts/setup-macos-signing.sh --check   # Exit 0 if valid signing identity exists, 1 otherwise
#   bash scripts/setup-macos-signing.sh --trust   # Trigger macOS trust confirmation for existing cert
#   bash scripts/setup-macos-signing.sh --no-trust # Import keypair only; print manual trust command
set -euo pipefail

CERT_NAME="LightIsle Local Dev"
CONFIG_DIR="${HOME}/.config/lightisle"
PUBLIC_CER="${CONFIG_DIR}/LightIsle-Local-Dev.cer"
OPENSSL_BIN="/usr/bin/openssl"
SECURITY_BIN="/usr/bin/security"

MODE="setup"
AUTO_TRUST="auto"

usage() {
  cat <<'EOF'
Usage: bash scripts/setup-macos-signing.sh [--check | --trust | --no-trust | --help]

Options:
  --check      Verify whether "LightIsle Local Dev" is a valid code-signing identity (non-mutating).
  --trust      Run the macOS user trust confirmation step for "LightIsle Local Dev".
  --no-trust   Create/import the certificate into the login Keychain without opening the trust dialog.
  -h, --help   Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --trust)
      AUTO_TRUST="always"
      shift
      ;;
    --no-trust)
      AUTO_TRUST="never"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "setup-macos-signing.sh requires macOS (Darwin)." >&2
  exit 1
fi

if [[ ! -x "$OPENSSL_BIN" ]]; then
  OPENSSL_BIN="$(command -v openssl || true)"
fi
if [[ -z "$OPENSSL_BIN" || ! -x "$SECURITY_BIN" ]]; then
  echo "Required macOS tools (/usr/bin/openssl and /usr/bin/security) were not found." >&2
  exit 1
fi

resolve_login_keychain() {
  local kc=""
  kc="$("$SECURITY_BIN" default-keychain -d user 2>/dev/null | tr -d '"[:space:]' || true)"
  if [[ -z "$kc" || ! -f "$kc" ]]; then
    kc="${HOME}/Library/Keychains/login.keychain-db"
  fi
  printf '%s\n' "$kc"
}

has_valid_signing_identity() {
  "$SECURITY_BIN" find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"${CERT_NAME}\""
}

has_cert_in_keychain() {
  local kc="$1"
  "$SECURITY_BIN" find-certificate -c "$CERT_NAME" "$kc" >/dev/null 2>&1
}

LOGIN_KEYCHAIN="$(resolve_login_keychain)"

if [[ "$MODE" == "check" ]]; then
  if has_valid_signing_identity; then
    echo "READY: Valid code-signing identity \"${CERT_NAME}\" is active in Keychain."
    exit 0
  fi
  if has_cert_in_keychain "$LOGIN_KEYCHAIN"; then
    echo "PENDING_TRUST: Certificate \"${CERT_NAME}\" exists in ${LOGIN_KEYCHAIN}, but is not yet trusted for Code Signing."
  else
    echo "MISSING: Certificate \"${CERT_NAME}\" has not been created yet. Run: bash scripts/setup-macos-signing.sh"
  fi
  exit 1
fi

if has_valid_signing_identity && [[ "$AUTO_TRUST" != "always" ]]; then
  echo "Reusing existing trusted macOS local signing identity: \"${CERT_NAME}\" (no key rotation)."
  exit 0
fi

umask 077
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lightisle-signing.XXXXXXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
chmod 700 "$TMP_DIR"

if has_cert_in_keychain "$LOGIN_KEYCHAIN"; then
  echo "Certificate \"${CERT_NAME}\" already exists in ${LOGIN_KEYCHAIN}; skipping key generation."
  "$SECURITY_BIN" find-certificate -c "$CERT_NAME" -p "$LOGIN_KEYCHAIN" > "$PUBLIC_CER"
  chmod 600 "$PUBLIC_CER"
else
  echo "Generating 10-year local code-signing certificate \"${CERT_NAME}\"..."
  OPENSSL_CNF="${TMP_DIR}/codesign.cnf"
  KEY_PEM="${TMP_DIR}/dev-key.pem"
  CERT_PEM="${TMP_DIR}/dev-cert.pem"
  P12_FILE="${TMP_DIR}/dev-identity.p12"
  P12_PASS="$("$OPENSSL_BIN" rand -hex 24)"

  cat > "$OPENSSL_CNF" <<EOF
[ req ]
default_bits       = 3072
distinguished_name = req_dn
x509_extensions    = codesign_ext
prompt             = no
utf8               = yes

[ req_dn ]
CN = ${CERT_NAME}
O  = LightIsle Local Development

[ codesign_ext ]
basicConstraints = critical, CA:FALSE
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

  "$OPENSSL_BIN" req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -config "$OPENSSL_CNF" \
    -keyout "$KEY_PEM" \
    -out "$CERT_PEM" >/dev/null 2>&1

  # LibreSSL (macOS /usr/bin/openssl) creates standard PKCS#12; OpenSSL 3+ needs -legacy for macOS SecImport.
  if "$OPENSSL_BIN" version 2>/dev/null | grep -Eq '^OpenSSL 3\.'; then
    "$OPENSSL_BIN" pkcs12 -export -legacy \
      -inkey "$KEY_PEM" \
      -in "$CERT_PEM" \
      -name "$CERT_NAME" \
      -passout "pass:${P12_PASS}" \
      -out "$P12_FILE" >/dev/null 2>&1
  else
    "$OPENSSL_BIN" pkcs12 -export \
      -inkey "$KEY_PEM" \
      -in "$CERT_PEM" \
      -name "$CERT_NAME" \
      -passout "pass:${P12_PASS}" \
      -out "$P12_FILE" >/dev/null 2>&1
  fi

  cp "$CERT_PEM" "$PUBLIC_CER"
  chmod 600 "$PUBLIC_CER"

  echo "Importing \"${CERT_NAME}\" into login Keychain (${LOGIN_KEYCHAIN})..."
  "$SECURITY_BIN" import "$P12_FILE" \
    -k "$LOGIN_KEYCHAIN" \
    -P "$P12_PASS" \
    -f pkcs12 \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null
fi

print_manual_trust_guide() {
  cat <<EOF

One-time macOS user trust confirmation required:
  Option A (Terminal — triggers standard macOS Touch ID / password dialog):
    /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "${LOGIN_KEYCHAIN}" "${PUBLIC_CER}"

  Option B (Keychain Access GUI):
    1. Open "Keychain Access" -> "login" -> "Certificates"
    2. Double-click "${CERT_NAME}" -> expand "Trust"
    3. Set "Code Signing" to "Always Trust" and close the window to confirm with Touch ID / password.

Once trusted, scripts/build-macos.sh and scripts/dev-macos-runner.py will automatically sign
LightIsle.app with "${CERT_NAME}" so rebuilds preserve your Keychain ACLs.
EOF
}

SHOULD_PROMPT_TRUST=0
if [[ "$AUTO_TRUST" == "always" ]]; then
  SHOULD_PROMPT_TRUST=1
elif [[ "$AUTO_TRUST" == "auto" && -t 0 && -t 1 ]]; then
  SHOULD_PROMPT_TRUST=1
fi

if [[ "$SHOULD_PROMPT_TRUST" -eq 1 ]]; then
  echo "Requesting one-time macOS Code Signing trust confirmation for \"${CERT_NAME}\"..."
  if "$SECURITY_BIN" add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$PUBLIC_CER"; then
    if has_valid_signing_identity; then
      echo "SUCCESS: \"${CERT_NAME}\" is now an active code-signing identity."
      exit 0
    fi
  fi
  echo "Trust confirmation was not completed yet." >&2
  print_manual_trust_guide
  exit 1
fi

if has_valid_signing_identity; then
  echo "SUCCESS: \"${CERT_NAME}\" is active for local code signing."
  exit 0
fi

print_manual_trust_guide
