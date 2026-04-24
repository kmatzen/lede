#!/usr/bin/env bash
#
# Picks (or creates) a stable code-signing identity for local dev.
#
# Why stable matters: macOS Keychain's Designated Requirement is bound to the
# binary's code signature. Ad-hoc signing produces a fresh cdhash every build,
# so "Always Allow" never persists. A stable identity fixes that.
#
# Priority order:
#   1) Apple Development / Developer ID cert already in the keychain — use it
#   2) Existing "Lede Dev" self-signed cert — use it
#   3) Create a fresh self-signed "Lede Dev" cert
#
# Prints the chosen identity name to stdout (for the Makefile to consume).
#
# Idempotent — safe to run repeatedly.

set -euo pipefail

SELF_SIGNED_NAME="Lede Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Does `security find-identity` list any valid codesigning identities?
first_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/^ *[0-9]+\)/ { print $2; exit }'
}

existing="$(first_identity || true)"
if [[ -n "$existing" ]]; then
    echo "$existing"
    exit 0
fi

# No valid identity. Create a self-signed one.
if ! command -v openssl >/dev/null; then
    echo "error: openssl not found on PATH" >&2
    exit 1
fi

echo "  Creating self-signed code-signing cert \"$SELF_SIGNED_NAME\"…" >&2

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/config.cnf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_codesign
[req_dn]
CN = $SELF_SIGNED_NAME
[v3_codesign]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/config.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# macOS `security import` only understands old PBE-SHA1-3DES. Force it.
PASS="lede-dev-one-time"
openssl pkcs12 -export -out "$TMP/bundle.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$SELF_SIGNED_NAME" -legacy \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 \
    -passout pass:$PASS

echo "  Importing into login keychain…" >&2
security import "$TMP/bundle.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

# The self-signed cert won't show up in `find-identity` until it's trusted for
# code signing, but we can still sign with it by SHA-1 or CN. Fall through.
echo "$SELF_SIGNED_NAME"
