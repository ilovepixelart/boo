#!/bin/bash
# Generate the project's stable RELEASE signing certificate and print the two
# GitHub secrets release.yml consumes. Run ONCE for the project; store the
# secrets; keep the .p12 somewhere safe (if it and the secret are lost, a
# regenerated cert has a new identity and every user must re-grant once).
#
# Free, self-signed. It makes end users' Accessibility/Automation grants persist
# across Boo updates (every release then carries the same code-signing identity).
# It does NOT satisfy Gatekeeper, that needs paid Apple notarization; a
# downloaded, un-notarized build still needs one right-click > Open.
#
# Never commit the .p12 or its base64.
set -euo pipefail

OUT="${1:-$HOME/boo-release-cert}"
CN="Boo Release Signing"
PW="$(openssl rand -hex 16)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat >"$WORK/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/ext.cnf" 2>/dev/null
# -legacy: macOS `security import` cannot read openssl 3's default PKCS12 MAC.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CN" -out "$OUT.p12" -passout "pass:$PW" 2>/dev/null
base64 <"$OUT.p12" >"$OUT.p12.base64"

cat <<MSG

Release signing certificate written to:
  $OUT.p12          (back this up; do NOT commit it)
  $OUT.p12.base64

Add the two GitHub secrets (repo Settings > Secrets and variables > Actions),
or with the gh CLI:

  gh secret set BOO_SIGN_CERT_P12 < "$OUT.p12.base64"
  gh secret set BOO_SIGN_CERT_PASSWORD --body '$PW'

The next tagged release then signs with this certificate; end users keep their
Accessibility grant across updates from that release on.
MSG
