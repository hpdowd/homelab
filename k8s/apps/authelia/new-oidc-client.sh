#!/usr/bin/env bash
# Mint one Authelia OIDC client secret.
#
#   ./new-oidc-client.sh <client_id> [<namespace> <secret-name> [<key>]]
#
# Prints two things that must go to two different places, and getting them the
# wrong way round is the single easiest mistake in step 5:
#
#   Digest    -> k8s/apps/authelia/configmap.yaml, as the client's
#                `client_secret`. It is a PBKDF2 hash, so it is safe in plain
#                git exactly like the argon2 password hashes in sealed-users.
#   Plaintext -> the CLIENT APPLICATION. Authelia never stores it and cannot
#                show it again; losing it means re-running this script and
#                updating both sides.
#
# With a namespace and secret name, the plaintext is also sealed into
# `sealed-oidc-client-<client_id>.yaml` for apps configured from git (grafana,
# paperless, argocd). Omit them for apps configured through their own UI or CLI
# (gitea, nextcloud, immich) — there the plaintext is typed into the app and
# there is no Kubernetes Secret to make.
#
# The sealed file is written HERE, but it does not belong here: move it into the
# consuming app's ArgoCD path, because that is what decides whether it is ever
# applied. k8s/apps/authelia is synced with `destination.namespace: authelia`,
# so a monitoring-namespace Secret left in this directory is dead yaml. Grafana's
# went to k8s/apps/monitoring/grafana-oidc-secret.sealed.yaml.
set -euo pipefail

cd "$(dirname "$0")"

CLIENT_ID="${1:-}"
NAMESPACE="${2:-}"
SECRET_NAME="${3:-}"
SECRET_KEY="${4:-client_secret}"

[ -n "$CLIENT_ID" ] || { echo "usage: $0 <client_id> [<namespace> <secret-name> [<key>]]" >&2; exit 1; }

IMAGE="$(sed -n 's|^ *image: \(docker.io/authelia/authelia:.*\)$|\1|p' deployment.yaml | head -1)"
[ -n "$IMAGE" ] || { echo "could not read the image tag out of deployment.yaml" >&2; exit 1; }

for c in docker; do command -v "$c" >/dev/null || { echo "missing required command: $c" >&2; exit 1; }; done

# --random mints the plaintext and hashes it in one step, so the plaintext never
# has to be passed on a command line where it would land in shell history.
OUT="$(docker run --rm "$IMAGE" authelia crypto hash generate pbkdf2 --random --variant sha512)"
PLAIN="$(printf '%s\n' "$OUT" | sed -n 's/^Random Password: //p')"
DIGEST="$(printf '%s\n' "$OUT" | sed -n 's/^Digest: //p')"

case "$DIGEST" in
  '$pbkdf2-sha512$'*) ;;
  *) echo "unexpected digest format: ${DIGEST:0:24}" >&2; exit 1 ;;
esac
[ -n "$PLAIN" ] || { echo "no plaintext produced" >&2; exit 1; }

if [ -n "$NAMESPACE" ] && [ -n "$SECRET_NAME" ]; then
  for c in kubectl kubeseal; do
    command -v "$c" >/dev/null || { echo "missing required command: $c" >&2; exit 1; }
  done
  OUTFILE="sealed-oidc-client-${CLIENT_ID}.yaml"
  [ -e "$OUTFILE" ] && { echo "$OUTFILE already exists; remove it first if you mean to rotate this client" >&2; exit 1; }
  kubeseal --fetch-cert >/dev/null || { echo "cannot reach the sealed-secrets controller" >&2; exit 1; }
  # Piping to /dev/stdin keeps the plaintext off the command line and out of
  # `ps`, which --from-literal would not. printf '%s' rather than a here-string
  # or echo: both append a newline, and a client secret with a trailing \n is
  # rejected by Authelia as simply wrong, with no hint as to why.
  printf '%s' "$PLAIN" \
    | kubectl create secret generic "$SECRET_NAME" --namespace "$NAMESPACE" \
        --from-file="$SECRET_KEY=/dev/stdin" --dry-run=client -o yaml \
    | kubeseal --controller-name sealed-secrets-controller \
        --controller-namespace kube-system -o yaml > "$OUTFILE"
  echo "Sealed the plaintext into $OUTFILE (Secret $NAMESPACE/$SECRET_NAME, key $SECRET_KEY)."
  echo
fi

echo "=============================================================="
echo " client_id: $CLIENT_ID"
echo
echo " Digest -> configmap.yaml client_secret (safe in git):"
echo "   $DIGEST"
echo
echo " Plaintext -> the client application AND the password manager:"
echo "   $PLAIN"
echo "=============================================================="
