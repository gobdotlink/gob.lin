#!/bin/bash
set -euo pipefail

identity='gob.lin Local Development'
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$keychain" | grep -Fq "\"$identity\""; then
    printf 'Signing identity already available: %s\n' "$identity"
    exit 0
fi
if security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
    printf 'The gob.lin certificate exists but is not a valid signing identity. Unlock the keychain or repair its trust before continuing.\n' >&2
    exit 1
fi

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
chmod 700 "$temporary"
export GOBLIN_CERT_PASSWORD
GOBLIN_CERT_PASSWORD=$(/usr/bin/openssl rand -hex 24)

/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -subj "/CN=$identity/" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=critical,codeSigning' \
    -keyout "$temporary/key.pem" -out "$temporary/certificate.pem" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -name "$identity" \
    -inkey "$temporary/key.pem" -in "$temporary/certificate.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -out "$temporary/identity.p12" -passout env:GOBLIN_CERT_PASSWORD
security import "$temporary/identity.p12" -k "$keychain" -P "$GOBLIN_CERT_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$temporary/certificate.pem"

if ! security find-identity -v -p codesigning "$keychain" | grep -Fq "\"$identity\""; then
    printf 'The signing identity was imported, but trust could not be verified. Check Keychain Access.\n' >&2
    exit 1
fi
printf 'Created stable signing identity: %s\n' "$identity"
