#!/bin/sh
# Creates a self-signed code-signing certificate named "MonitorKeys Local Signing" in your
# login keychain. build.sh uses it automatically. Because macOS ties privacy permissions
# (Accessibility, system audio) to the signing certificate, this keeps them valid across
# rebuilds; with plain ad-hoc signing every rebuild would need the permissions granted again.
#
# macOS asks for your login password once to trust the certificate. Nothing leaves your Mac.
set -eu
NAME="MonitorKeys Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Identity \"$NAME\" already exists."; exit 0
fi
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
subjectKeyIdentifier=hash
CFG
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -days 3650 -config "$DIR/cfg" 2>/dev/null
# The keychain importer needs the legacy PKCS#12 encoding.
openssl pkcs12 -export -legacy -out "$DIR/id.p12" -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -passout pass:tmp -name "$NAME" 2>/dev/null \
  || openssl pkcs12 -export -out "$DIR/id.p12" -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -passout pass:tmp -name "$NAME"
security import "$DIR/id.p12" -k "$KEYCHAIN" -P tmp -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"
echo "Created \"$NAME\". Rebuild with: sh build.sh"
echo "If MonitorKeys was already granted permissions under an ad-hoc signature, reset them once:"
echo "  tccutil reset Accessibility $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(dirname "$0")/../Info.plist")"
