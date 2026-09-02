#!/usr/bin/env bash
# One-time bring-up: generate Authelia's secrets and seal them into this repo.
#
# This is step 1 of docs/plans/phase-8-authelia.md. It is a script rather than
# a block of runbook prose for the reason ADR 017 gives: it is an ordered
# sequence with six chances to make a silent mistake, and a mistake here is a
# pod that crashloops while gating four services.
#
# It produces two files, both safe to commit:
#   k8s/apps/authelia/sealed-secrets.yaml   jwt / session / storage-encryption / smtp
#   k8s/apps/authelia/sealed-users.yaml     users.yml, argon2 hashes
#
# It writes NO plaintext to the repo, and its temp dir is removed on exit
# (including on failure). The generated values are printed ONCE at the end so
# they can go into the password manager, which is not optional — see the loss
# policy at the bottom of this file.
#
# Not idempotent by design: re-running generates NEW secrets, which invalidates
# every existing session and makes the existing db.sqlite3 unreadable. It
# refuses to overwrite unless you pass --force.
set -euo pipefail

cd "$(dirname "$0")"
FORCE="${1:-}"

# Keep the image tag in lockstep with what the pod actually runs, so the argon2
# parameters and the CLI flags used below are the ones that version ships.
IMAGE="$(sed -n 's|^ *image: \(docker.io/authelia/authelia:.*\)$|\1|p' deployment.yaml | head -1)"
[ -n "$IMAGE" ] || { echo "could not read the image tag out of deployment.yaml" >&2; exit 1; }
echo "Using $IMAGE (read from deployment.yaml)"

for c in kubectl kubeseal docker; do
  command -v "$c" >/dev/null || { echo "missing required command: $c" >&2; exit 1; }
done

if [ "$FORCE" != "--force" ]; then
  for f in sealed-secrets.yaml sealed-users.yaml; do
    [ -e "$f" ] && { echo "$f already exists. Re-running rotates every secret and orphans the existing TOTP database. Pass --force if that is really what you want." >&2; exit 1; }
  done
fi

# The controller has to be reachable, and its key has to be the one this repo's
# other SealedSecrets were sealed against. If this cert is unexpected, STOP:
# sealing against a fresh key produces files nothing in the cluster can decrypt.
kubeseal --fetch-cert >/dev/null || { echo "cannot reach the sealed-secrets controller" >&2; exit 1; }
echo "Sealed Secrets controller reachable."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

# Reuse the SAME Brevo key Alertmanager already uses, read straight from the
# live cluster rather than retyped. Brevo only accepts senders verified on the
# account, which is also why configuration.yml sends as homelab-monitor@.
echo "Reading the Brevo SMTP key from the alertmanager-smtp secret..."
kubectl -n monitoring get secret alertmanager-smtp \
  -o jsonpath='{.data.smtp_password}' | base64 -d > "$TMP/smtp_password"
[ -s "$TMP/smtp_password" ] || { echo "alertmanager-smtp/smtp_password was empty" >&2; exit 1; }

# Authelia's own generator, so this script needs no openssl (which is not
# installed on the workstation this was written on).
gen() { docker run --rm "$IMAGE" authelia crypto rand --length 64 --charset alphanumeric \
          | sed -n 's/^Random Value: //p' | tr -d '\n'; }
echo "Generating secrets..."
gen > "$TMP/jwt_secret"
gen > "$TMP/session_secret"
gen > "$TMP/storage_encryption_key"
for f in jwt_secret session_secret storage_encryption_key; do
  [ "$(wc -c < "$TMP/$f")" -eq 64 ] || { echo "generation failed for $f" >&2; exit 1; }
done

# Interactive, and never echoed. This is the password used to log in at
# auth.henrydowd.dev, so pick something a human can actually type.
echo
read -r -s -p "Password for the 'henry' Authelia login: " PW1; echo
read -r -s -p "Again: " PW2; echo
[ "$PW1" = "$PW2" ] || { echo "passwords did not match" >&2; exit 1; }
[ -n "$PW1" ] || { echo "empty password" >&2; exit 1; }

echo "Hashing (argon2id, this is deliberately slow)..."
HASH="$(docker run --rm "$IMAGE" authelia crypto hash generate argon2 --password "$PW1" \
        | sed -n 's/^Digest: //p')"
unset PW1 PW2
case "$HASH" in
  '$argon2id$'*) ;;
  *) echo "unexpected hash format: ${HASH:0:24}" >&2; exit 1 ;;
esac

cat > "$TMP/users.yml" <<EOF
users:
  henry:
    disabled: false
    displayname: 'Henry'
    password: '$HASH'
    email: henry@dowd.ie
    groups:
      - admins
EOF

echo "Sealing..."
kubectl create secret generic authelia-secrets --namespace authelia \
  --from-file=jwt_secret="$TMP/jwt_secret" \
  --from-file=session_secret="$TMP/session_secret" \
  --from-file=storage_encryption_key="$TMP/storage_encryption_key" \
  --from-file=smtp_password="$TMP/smtp_password" \
  --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets-controller \
      --controller-namespace kube-system -o yaml > sealed-secrets.yaml

kubectl create secret generic authelia-users --namespace authelia \
  --from-file=users.yml="$TMP/users.yml" \
  --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets-controller \
      --controller-namespace kube-system -o yaml > sealed-users.yaml

echo
echo "Wrote sealed-secrets.yaml and sealed-users.yaml (safe to commit)."
echo
echo "=============================================================="
echo " COPY THESE INTO THE PASSWORD MANAGER NOW. They are not"
echo " recoverable from the sealed files, and are printed only here."
echo
echo " storage_encryption_key is the one that matters most: without"
echo " it db.sqlite3 is unreadable and every TOTP enrolment is lost."
echo "=============================================================="
echo "  storage_encryption_key: $(cat "$TMP/storage_encryption_key")"
echo "  session_secret:         $(cat "$TMP/session_secret")"
echo "  jwt_secret:             $(cat "$TMP/jwt_secret")"
echo "  (smtp_password is the existing Brevo key, already stored)"
echo "  (the login password is the one you just typed)"
echo "=============================================================="
