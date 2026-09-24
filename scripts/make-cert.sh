#!/bin/bash
set -euo pipefail
NAME="Dabber Dev"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "identity '$NAME' already exists"
  exit 0
fi
while security delete-certificate -c "$NAME" >/dev/null 2>&1; do :; done
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 3650 -config "$T/cfg"
/usr/bin/openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/c.p12" -passout pass:dabber -name "$NAME"
security import "$T/c.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P dabber -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$T/c.pem"
security find-identity -v -p codesigning | grep -q "$NAME"
echo "imported '$NAME'"
