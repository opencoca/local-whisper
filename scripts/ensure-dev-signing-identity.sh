#!/usr/bin/env bash
#
# Ensures a persistent self-signed code-signing identity named
# "LocalWhisper Dev" exists in the user's login keychain. Idempotent —
# re-running is a no-op if the identity is already present.
#
# Why: macOS keys TCC entries (Accessibility, Microphone, etc.) by the
# cryptographic signing identity, NOT by bundle id or path. Ad-hoc signing
# (`codesign --sign -`) generates a fresh identity on every build, so each
# `make app` produces a binary macOS treats as a brand-new app and the
# previously granted Accessibility row is orphaned. Signing with a
# persistent identity makes TCC entries stick across rebuilds.
#
# The cert is per-machine and not committed to git. Each contributor runs
# this once via `make setup`.

set -euo pipefail

IDENTITY_NAME="LocalWhisper Dev"
KEYCHAIN="login.keychain"

# Idempotency: if a code-signing identity with this CN already exists,
# we're done. Note: `find-identity -v` filters to "valid" (chain-trusted)
# identities, which excludes self-signed certs — so we must NOT pass -v
# here, or we'd recreate the cert on every run and accumulate duplicates.
# The output format is one match per line:
#   2) ABCDEF1234... "LocalWhisper Dev" (CSSMERR_TP_NOT_TRUSTED)
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -q "\"$IDENTITY_NAME\""; then
    echo "  ✓ '$IDENTITY_NAME' already in $KEYCHAIN"
    exit 0
fi

echo "  Creating '$IDENTITY_NAME' (self-signed, 10-year, code-signing EKU)..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# OpenSSL config — extendedKeyUsage=codeSigning is what codesign actually
# checks. basicConstraints=CA:false keeps this a leaf cert.
cat > "$TMPDIR/csr.conf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt             = no
x509_extensions    = v3_codesign

[ req_distinguished_name ]
CN = $IDENTITY_NAME

[ v3_codesign ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

# Generate key + self-signed X.509 cert.
openssl req -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR/key.pem" \
    -x509 -days 3650 \
    -out "$TMPDIR/cert.pem" \
    -config "$TMPDIR/csr.conf" \
    -extensions v3_codesign \
    >/dev/null 2>&1

# Bundle into PKCS#12 for import. Two compatibility quirks here:
#   1. `-legacy` selects the older RC2/SHA1 algorithm set. OpenSSL 3.x
#      defaults to PBKDF2 parameters that macOS `security` rejects with
#      "MAC verification failed during PKCS12 import".
#   2. macOS `security import` refuses PKCS#12 files with empty passwords.
#      Use a dummy non-empty password — its strength is irrelevant because
#      the file lives in $TMPDIR for milliseconds before being deleted.
P12_PASS="lwd-transient-passphrase"
openssl pkcs12 -export -legacy \
    -in "$TMPDIR/cert.pem" \
    -inkey "$TMPDIR/key.pem" \
    -out "$TMPDIR/identity.p12" \
    -name "$IDENTITY_NAME" \
    -passout "pass:$P12_PASS" \
    >/dev/null 2>&1

# Import into login keychain. `-A` allows any application to use the
# private key without an ACL prompt (avoids codesign hanging on a "Sign in
# to use this key" dialog on every build). `-T /usr/bin/codesign` would
# scope it more tightly but combined with -A it's redundant.
security import "$TMPDIR/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -A \
    >/dev/null

# Best-effort partition-list update — on Sierra+ this is required for
# non-prompting key access. Requires the user's keychain password. We
# don't know it, so attempt with empty password; failure is non-fatal
# (codesign will prompt once, the user clicks Always Allow, and it's
# fine forever after).
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" \
    >/dev/null 2>&1 || true

echo "  ✓ '$IDENTITY_NAME' created. If codesign prompts for keychain"
echo "    access on first run, click 'Always Allow' once."
