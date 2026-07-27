# Verifying the B2 backups

This is the companion to `restore-procedure.md`, and the distinction
matters: that runbook is what I follow when something is *actually gone*
and I need the data back. This one is what I run on a healthy cluster to
find out whether that procedure would have worked. Non-destructive,
repeatable, and it never touches a live namespace.

Record the outcome in the test-restore table at the bottom of
`restore-procedure.md` when you finish a tier 4 run.

## The four tiers

Verification is a ladder. Each rung catches a failure class the one below
it can't see, so a pass at tier 2 says nothing about tier 4.

| Tier | What it proves | Cost | Cadence |
|---|---|---|---|
| 1 | The CronJob ran and restic wrote something | free | automatic, check when convenient |
| 2 | The repo is structurally sound and every referenced blob exists | seconds, no egress | monthly, or after anything weird |
| 3 | The stored bytes are actually intact and readable | B2 egress on the sampled fraction | quarterly |
| 4 | The data is *usable* — it loads, it opens, the app accepts it | egress + an hour of attention | quarterly, per service |

The gap between 3 and 4 is the one that bites. A repo can pass
`check --read-data` completely and still restore into an application that
refuses to start, because the bytes were always fine and the problem is a
missing extension, an ownership mismatch, or a schema the running version
no longer accepts.

---

## Tier 1 — did it run

```bash
kubectl get cronjobs -A
kubectl get jobs -A --sort-by=.metadata.creationTimestamp | tail -20
```

Look for a Complete job per service in the last 24h and a duration in the
normal range. A job that "succeeded" in 8 hours instead of 6 minutes has
usually been retrying against a fault, and is worth opening the log for.

This tier can't distinguish a good snapshot from a truncated one. Never
let it be the only thing you've run.

## Tier 2 — `restic check`

Structural validation: indexes, pack references, and the existence of
every blob each snapshot claims. Metadata only, so no meaningful egress
charge and it finishes in seconds. This is the tier that catches a bucket
that has been quietly rotting for six months.

Run it in-cluster against all four repos using the already-sealed
credentials — each namespace's `backup-credentials` carries its own repo
URL, so the same manifest works everywhere:

```bash
for ns in nextcloud gitea immich paperless; do
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: restic-verify, namespace: $ns}
spec:
  restartPolicy: Never
  containers:
  - name: v
    image: alpine:3.20
    command: ["/bin/sh","-c","apk add --no-cache --quiet restic && restic snapshots --latest 1 && restic check"]
    envFrom: [{secretRef: {name: backup-credentials}}]
    resources: {limits: {cpu: 500m, memory: 512Mi, ephemeral-storage: 2Gi}}
EOF
done

# then, once they've finished:
for ns in nextcloud gitea immich paperless; do
  echo "== $ns"; kubectl logs restic-verify -n $ns | tail -5
  kubectl delete pod restic-verify -n $ns
done
```

Wanted: `no errors were found`, and a latest snapshot dated last night.

## Tier 3 — `restic check --read-data-subset`

Tier 2 proves the blobs are *listed*. This proves they are *readable* —
restic downloads a sample of packs and verifies their content hashes.
Sample rather than doing the full `--read-data`, which pulls the entire
repo out of B2 and costs accordingly:

```bash
restic check --read-data-subset=10%
```

Same pod pattern as tier 2, just the different command. Give it a longer
timeout; it's doing real network work.

## Tier 4 — test restore into a scratch namespace

The only tier that proves the data is usable. The shape is always the
same, whatever the service:

1. Scratch namespace, never the live one.
2. Copy in `backup-credentials` *and* the app's own secret — you need the
   DB password, and it doesn't live in the backup secret.
3. Stand up a database on the **exact image the manifests pin**, not a
   convenient stock one.
4. Restore the DB snapshot, validate the dump, load it.
5. Compare the loaded DB against live: table count, extensions, row
   counts on the tables that matter.
6. Restore a **bounded** slice of the data volume and checksum it against
   live.
7. Tear the namespace down.

### 1–2. Namespace and secrets

```bash
NS=<app>-restore-test
kubectl create namespace $NS
for s in backup-credentials <app>-secrets; do
  kubectl get secret $s -n <app> -o json \
   | python3 -c "import json,sys; d=json.load(sys.stdin); d['metadata']={'name':d['metadata']['name'],'namespace':'$NS'}; print(json.dumps(d))" \
   | kubectl apply -f -
done
```

The python step strips the resourceVersion/uid/ownerRefs that make a
straight `kubectl get -o yaml | kubectl apply` fail.

### 3. Scratch database

Copy the container spec out of `k8s/apps/<app>/postgres.yaml` verbatim —
same image digest, same `POSTGRES_*` env, same `PGDATA`, same shm
emptyDir — and point it at a small fresh `longhorn` PVC. 5Gi is plenty
for a dump-sized database.

Using the pinned digest is the whole point for Immich: the dump carries
VectorChord-backed tables, and a vanilla `postgres:14` loads the data and
then fails on the extension. That's exactly the failure this tier exists
to catch, so don't "simplify" it away.

### 4. Restore and load the dump

Run this in a pod on the same major version as the dump (check
`k8s/apps/<app>/backup-cronjob.yaml` for the image the `pg_dump` ran in):

```bash
restic restore latest --tag <app>-db --target /tmp/dbr

# validate the archive before trusting it — catches truncation
pg_restore --list /tmp/dbr/dump/<app>_db.dump

export PGPASSWORD="$DB_PASSWORD"
psql -h postgres -U postgres -d postgres \
  -c "DROP DATABASE IF EXISTS <app>;" -c "CREATE DATABASE <app> OWNER postgres;"
pg_restore -h postgres -U postgres -d <app> --no-owner /tmp/dbr/dump/<app>_db.dump
```

Wanted: `pg_restore --list` exits 0 with a plausible TOC entry count, and
the load itself reports zero errors and zero warnings.

### 5. Compare against live

```bash
# table count, extensions, and row counts — run against both and diff
kubectl exec -n $NS   deploy/postgres -- psql -U postgres -d <app> -tAc \
  "select count(*) from information_schema.tables where table_schema='public';"
kubectl exec -n <app> deploy/postgres -- psql -U postgres -d <app> -tAc \
  "select count(*) from information_schema.tables where table_schema='public';"

# extensions must match exactly, including versions
... -tAc "select extname||' '||extversion from pg_extension order by 1;"
```

Then row counts on whichever tables carry the irreplaceable content
(`asset` and `smart_search` for Immich, documents for Paperless).

### 6. Bounded data restore and checksum

**The `--include` isn't optional.** A full library restore fills the
worker's root disk and the pod gets evicted mid-run; at the time of
writing worker1 had 7.5GiB free against a 22GiB Immich library. Pick a
subdirectory in the tens of megabytes, and always set an
`ephemeral-storage` limit as a second line of defence.

```bash
restic restore latest --tag <app>-data \
  --include /data/<some bounded subdir> \
  --target /tmp/lib
cd /tmp/lib/data && find . -type f | sort | xargs -r sha256sum | sed 's|\./||'
```

Take the same manifest from the live PVC via the app pod, sort both, and
`comm` them. Wanted: every file identical, **and an empty diff in both
directions**.

That second half matters more than it looks. Matching row counts and
checksums only prove anything if nothing was written between the snapshot
and the comparison — so confirm the live-only side is empty rather than
assuming it. A non-empty live-only diff is usually benign (files created
after the snapshot, as in the 2026-06-12 Nextcloud run) but you want to
have looked.

### 7. Teardown

```bash
kubectl delete namespace $NS --wait=true --timeout=180s
kubectl get volumes.longhorn.io -n longhorn-system   # back to the expected count, all healthy
```

---

## Gotchas worth knowing before you start

- **A pod in `Error` isn't necessarily a failed test.** The status
  reflects the exit code of the last command in the script, so a trailing
  `grep -c` that matches nothing marks the whole pod failed while the
  restore underneath it was clean. Read the log, not the phase.
- **Immich: `need 1 probes, but 0 probes provided`** when querying a
  restored `smart_search`. That's a VectorChord session GUC the Immich
  server sets for itself, not a corrupt index. `SET vchordrq.probes = 1;`
  and the ANN query works.
- **`s3:https://`**, always. Without the `s3:` prefix restic treats the
  URL as a local path and cheerfully "succeeds" into the pod's ephemeral
  storage. Documented in `restore-procedure.md` too, and worth repeating.
- **Check the worker's free disk before you begin**, not after the
  eviction:
  `kubectl get --raw /api/v1/nodes/k3s-worker1/proxy/stats/summary`.
- ArgoCD doesn't manage a namespace no Application references, so a
  scratch namespace is safe from both pruning and self-heal.
