#!/usr/bin/env bash
#
# Bootstrap: get from "two k3s nodes exist" to "ArgoCD is reconciling this
# repo". Everything after that point is ArgoCD's job.
#
# This replaces cluster-rebuild.md §4–6, which was a sequence of commands to
# copy by hand, three of which installed from moving upstream pointers
# (`releases/latest`, `stable`, `main`). See README.md in this directory.
#
#   ./bootstrap.sh --check     # preflight only, changes nothing
#   ./bootstrap.sh
#
# Idempotent: safe to re-run. Every step checks for its own result first, so
# a run that dies halfway can simply be re-run.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=versions.env
source ./versions.env

CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

# Where the two bootstrap secrets come from. Neither is in this repo and
# neither can be: the master key IS the trust root for everything that is,
# and the repo token is what fetches the repo in the first place.
MASTER_KEY="${MASTER_KEY:-}"          # path to sealed-secrets master key yaml
REPO_TOKEN="${REPO_TOKEN:-}"          # Gitea token, repo read scope

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────
# Preflight. Fail here rather than halfway through, when half the cluster
# is up and the failure is ambiguous.
# ─────────────────────────────────────────────────────────────────────────
info "Preflight"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null || die "$bin not found in PATH"
done
ok "kubectl and helm present"

kubectl cluster-info >/dev/null 2>&1 || die "cannot reach the cluster — check ~/.kube/config"
ok "cluster reachable"

not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv ' Ready ' || true)
[[ "$not_ready" -eq 0 ]] || die "$not_ready node(s) not Ready — fix that before bootstrapping"
ok "all nodes Ready"

# The master key check is the one that matters most. Installing the
# controller without restoring the key lets it generate a FRESH keypair, at
# which point every SealedSecret in this repo is encrypted against a key
# that no longer exists anywhere. There is no recovery from that except
# re-sealing every secret by hand from the password manager.
if [[ -z "$MASTER_KEY" ]]; then
  die "MASTER_KEY is unset.

  Set it to the path of the backed-up sealed-secrets master key:
    MASTER_KEY=~/secure/sealed-secrets-master-key.yaml ./bootstrap.sh

  If you genuinely do not have it, STOP and read
  docs/runbooks/cluster-rebuild.md §0 before continuing. Bootstrapping
  without it means re-sealing every secret in this repo from the password
  manager, and it is much easier to do that deliberately than to discover
  it halfway through."
fi
[[ -f "$MASTER_KEY" ]] || die "MASTER_KEY is set to '$MASTER_KEY', which does not exist"
grep -q 'sealedsecrets.bitnami.com/sealed-secrets-key' "$MASTER_KEY" \
  || die "'$MASTER_KEY' does not look like a sealed-secrets key backup (missing the key label)"
ok "master key present and looks right"

[[ -n "$REPO_TOKEN" ]] || die "REPO_TOKEN is unset — Gitea token with repo read scope, from the password manager"
ok "repo token present"

[[ -f argocd-cm-patch.yaml ]] || die "argocd-cm-patch.yaml missing from $(pwd)"
[[ -f ../k8s/argocd/root-app.yaml ]] || die "../k8s/argocd/root-app.yaml missing — is this a full clone?"
ok "manifests present"

if $CHECK_ONLY; then
  info "Preflight passed. --check was set, so nothing was changed."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────
# 1. Sealed Secrets, BEFORE ArgoCD.
#
# Order is load-bearing. ArgoCD starts syncing apps the moment root-app
# lands, and most of those apps have a SealedSecret they cannot start
# without. The controller and its restored key have to be in place first.
# ─────────────────────────────────────────────────────────────────────────
info "Sealed Secrets (chart $SEALED_SECRETS_CHART_VERSION)"

if helm status sealed-secrets -n "$SEALED_SECRETS_NAMESPACE" >/dev/null 2>&1; then
  ok "release already exists, leaving it alone"
else
  helm repo add sealed-secrets "$SEALED_SECRETS_REPO" >/dev/null 2>&1 || true
  helm repo update sealed-secrets >/dev/null
  # Fail loudly here rather than at `helm install`. A chart repo that has
  # moved returns a 404 on index.yaml, and the install error underneath it
  # is much less obvious than this one.
  helm search repo sealed-secrets/sealed-secrets \
    --version "$SEALED_SECRETS_CHART_VERSION" 2>/dev/null | grep -q sealed-secrets \
    || die "chart sealed-secrets $SEALED_SECRETS_CHART_VERSION not found at $SEALED_SECRETS_REPO
  The repo may have moved again. Check versions.env."
  # fullnameOverride matches the live install and every runbook reference;
  # without it the chart names the Deployment `sealed-secrets` and kubeseal's
  # defaults stop lining up.
  helm install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace "$SEALED_SECRETS_NAMESPACE" \
    --version "$SEALED_SECRETS_CHART_VERSION" \
    --set fullnameOverride=sealed-secrets-controller \
    --wait
  ok "controller installed"
fi

info "Restoring the master key"
# Applied unconditionally: it is the same key every time, so re-applying is
# a no-op, and getting this wrong is unrecoverable. Cheap insurance.
kubectl apply -f "$MASTER_KEY"
kubectl -n "$SEALED_SECRETS_NAMESPACE" rollout restart deployment sealed-secrets-controller
kubectl -n "$SEALED_SECRETS_NAMESPACE" rollout status deployment sealed-secrets-controller --timeout=120s
ok "key restored, controller restarted"

warn "Verify the controller is serving the key you expect, before trusting any sync:"
warn "  kubeseal --fetch-cert | diff - <your-backed-up-cert>"

# ─────────────────────────────────────────────────────────────────────────
# 2. ArgoCD
# ─────────────────────────────────────────────────────────────────────────
info "ArgoCD $ARGOCD_VERSION"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Tagged manifest, not `stable`. `stable` is a branch that moves, so two
# rebuilds a month apart would install two different ArgoCDs.
kubectl apply -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl -n argocd rollout status deployment argocd-server --timeout=300s
ok "installed"

# Must land before root-app, or the EndpointSlices that point Traefik at the
# LXC services are silently dropped. See argocd-cm-patch.yaml.
info "Applying the argocd-cm exclusions patch"
kubectl patch configmap argocd-cm -n argocd --type merge \
  --patch-file argocd-cm-patch.yaml
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server --timeout=300s
ok "patched and restarted"

# ─────────────────────────────────────────────────────────────────────────
# 3. Repo credentials
#
# A bootstrap object by nature: it lives only in the cluster, never in git,
# because it is what lets the cluster read git at all.
#
# --insecure-skip-server-verification is deliberate. With Technitium as LAN
# DNS the cluster reaches git.henrydowd.dev through Traefik, and at this
# point cert-manager does not exist yet, so Traefik is still on its
# self-signed default cert.
# ─────────────────────────────────────────────────────────────────────────
# Field-for-field what `argocd repo add` produces today (that CLI names the
# Secret by a hash of the URL, `repo-3439803332`; this uses a readable name,
# which ArgoCD does not care about — it finds repos by the label below).
info "Registering repo credentials"
kubectl -n argocd create secret generic homelab-repo \
  --from-literal=name=homelab \
  --from-literal=project=default \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$REPO_USER" \
  --from-literal=password="$REPO_TOKEN" \
  --from-literal=insecure=true \
  --dry-run=client -o yaml \
  | kubectl label -f - --local -o yaml --dry-run=client \
      argocd.argoproj.io/secret-type=repository \
  | kubectl apply -f -
ok "credentials registered"

# ─────────────────────────────────────────────────────────────────────────
# 4. Hand over to ArgoCD
# ─────────────────────────────────────────────────────────────────────────
info "Applying root-app"
kubectl apply -f ../k8s/argocd/root-app.yaml
ok "root-app applied — ArgoCD owns the cluster from here"

# argocd-cmd-params-cm arrives via the argocd-ingress app and sets
# server.insecure=true, but a ConfigMap change does not restart anything.
# Until argocd-server is restarted again it stays in TLS mode and the
# argocd.lan ingress does not work. This is the step most often missed.
info "Waiting for argocd-cmd-params-cm to sync, then restarting argocd-server"
for _ in $(seq 1 60); do
  if kubectl -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}' 2>/dev/null | grep -q true; then
    break
  fi
  sleep 5
done

if kubectl -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}' 2>/dev/null | grep -q true; then
  kubectl -n argocd rollout restart deployment argocd-server
  kubectl -n argocd rollout status deployment argocd-server --timeout=300s
  ok "argocd-server restarted in insecure mode — argocd.lan should work once Traefik is up"
else
  warn "argocd-cmd-params-cm has not synced yet. Once root-app settles, run:"
  warn "  kubectl -n argocd rollout restart deployment argocd-server"
  warn "Without it argocd.lan will not work, though everything else will."
fi

# ─────────────────────────────────────────────────────────────────────────
info "Bootstrap complete"
cat <<'EOF'

    Watch the sync settle. During a fresh bootstrap the argocd.lan ingress
    does not exist yet, so port-forward is correct here, not drift:

      kubectl port-forward svc/argocd-server -n argocd 8080:443
      # https://localhost:8080  user: admin
      # kubectl -n argocd get secret argocd-initial-admin-secret \
      #   -o jsonpath='{.data.password}' | base64 -d

    Expected order: metallb-config → traefik (takes 192.168.1.200) →
    cloudflared → cert-manager → apps.

    `longhorn` and `sealed-secrets` will show OutOfSync. That is correct —
    both are manual-sync by design. Do NOT "Sync All". Read the headers in
    k8s/infrastructure/{longhorn,sealed-secrets}.yaml first.

    Then continue at cluster-rebuild.md §7.
EOF
