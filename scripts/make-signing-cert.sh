#!/bin/bash
# Create a stable self-signed code-signing certificate so macOS remembers Boo's
# Accessibility grant across rebuilds.
#
# The problem: ad-hoc signing keys the app's identity to the binary hash, which
# changes on every build, so macOS treats each rebuild as a new app and the
# "Boo would like to control this computer" grant is lost every time. A fixed
# certificate keys the identity to the certificate instead (the code signature's
# Designated Requirement becomes `identifier "com.boo.app" and certificate
# leaf = H"..."`), which is stable across rebuilds. bundle.sh uses this cert
# automatically once it exists.
#
# Free, no Apple Developer account. It does NOT fix Gatekeeper (a downloaded,
# un-notarized build still needs one right-click > Open); it only makes the
# Accessibility (and Automation) grants persist. Run once:
#
#   ./scripts/make-signing-cert.sh
#   ./bundle.sh
#
# Then grant Accessibility one last time; it will stick from then on.
set -euo pipefail

CERT_NAME="${1:-Boo Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate '$CERT_NAME' already exists; nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

# Self-signed key + certificate with the codeSigning extended key usage.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/ext.cnf" 2>/dev/null

# -legacy: openssl 3 defaults to a PKCS12 MAC that macOS `security` cannot read.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CERT_NAME" -out "$WORK/cert.p12" -passout pass:boo 2>/dev/null

# -T /usr/bin/codesign adds codesign to the private key's ACL so signing does
# not pop a keychain prompt on every build.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P boo -T /usr/bin/codesign

# On newer macOS the ACL alone is not enough; the key's partition list must also
# allow the Apple tools. Needs the login-keychain password, so it is best-effort:
# if it does not run, codesign simply asks once and you click "Always Allow".
if [ -n "${BOO_KEYCHAIN_PASSWORD:-}" ]; then
    security set-key-partition-list -S apple-tool:,apple: \
        -k "$BOO_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
fi

echo "Created '$CERT_NAME' in the login keychain."
echo "Next: ./bundle.sh   (it now signs with this certificate)"
echo "Then grant Accessibility once more; the grant will persist across rebuilds."
