#!/bin/bash
# Creates a self-signed code-signing identity named "Steward Local" in your login keychain, once.
# scripts/build.sh then signs with it, which keeps the app's signature stable across rebuilds so
# macOS remembers its Accessibility / Screen Recording / Microphone grants.
#
# What to expect:
#   - No sudo. The certificate is not added to any trust store; it only signs this app on this Mac.
#   - The first build after this may show a keychain dialog ("codesign wants to sign using key
#     Steward Local"). Choose "Always Allow".
#   - To remove it: Keychain Access > login > My Certificates > delete "Steward Local".
set -euo pipefail

NAME="${STEWARD_SIGN_IDENTITY:-Steward Local}"
KEYCHAIN="${STEWARD_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$NAME\""; then
  echo "\"$NAME\" already exists in $KEYCHAIN"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(uuidgen)"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# /usr/bin/openssl (LibreSSL) writes a PKCS#12 that `security import` accepts; OpenSSL 3 defaults do not.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASS"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$NAME\""; then
  echo "Created \"$NAME\". Run scripts/build.sh; allow the keychain prompt once if it appears."
else
  echo "Import finished but \"$NAME\" is not listed as a code-signing identity." >&2
  exit 1
fi
