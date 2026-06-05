# Restore Procedure — restic / Backblaze B2

> Disaster recovery for the homelab k3s services backed up to Backblaze B2 via restic.
> Covers Nextcloud and Gitea. Assumes a working (or rebuilt) k3s cluster with
> Longhorn, ArgoCD, and Sealed Secrets installed, and the backup-credentials
> secret restored to each namespace.
>
> Prerequisite: restic installed on your recovery machine, OR run via a throwaway
> pod as shown below. Either way you need the RESTIC_PASSWORD and B2 credentials —
> these live in your password manager (NOT in the cluster if the cluster is gone).

---

## 0. Set up restic access

On a recovery machine with restic installed:

```bash
export RESTIC_REPOSITORY="s3:https://s3.eu-central-003.backblazeb2.com/hpd.homelab/nextcloud"
export RESTIC_PASSWORD="<from password manager>"
export AWS_ACCESS_KEY_ID="<b2 key id>"
export AWS_SECRET_ACCESS_KEY="<b2 app key>"

restic snapshots          # confirm access
restic check              # confirm integrity before relying on a restore
```

Swap the repository path's final segment (`/nextcloud` ↔ `/gitea`) for each service.

If you have a cluster but no local restic, run any restic command via a pod:

```bash
kubectl run restic-restore -n <namespace> --rm -it --restart=Never \
  --image=alpine:3.20 \
  --overrides='{"spec":{"containers":[{"name":"restic-restore","image":"alpine:3.20","command":["/bin/sh","-c","apk add --no-cache restic && exec sh"],"envFrom":[{"secretRef":{"name":"backup-credentials"}}],"stdin":true,"tty":true}]}}'
```

---

## Nextcloud restore

Nextcloud backup consists of two snapshots: `nextcloud-data` (the /var/www/html
PVC contents) and `nextcloud-db` (a Postgres custom-format dump).

### 1. Restore the data

Bring up the Nextcloud stack via ArgoCD so the PVCs and Postgres exist, then
scale Nextcloud to 0 so nothing writes during restore:

```bash
kubectl scale deployment nextcloud -n nextcloud --replicas=0
```

Restore the data snapshot into the data PVC. Easiest is a temporary pod that
mounts the PVC and runs restic restore:

```bash
# Identify the data snapshot
restic snapshots --tag nextcloud-data

# Restore into a pod that mounts nextcloud-data at /restore-target
# (run restic restore latest --tag nextcloud-data --target /restore-target)
# The snapshot's /data maps to /var/www/html contents.
```

### 2. Restore the database

```bash
restic restore latest --tag nextcloud-db --target /tmp/db-restore
# yields /tmp/db-restore/dump/nextcloud_db.dump

# Drop and recreate the DB, then restore:
PGPASSWORD=<db_pass> psql -h <postgres> -U nextcloud -d postgres \
  -c "DROP DATABASE nextcloud_database;" -c "CREATE DATABASE nextcloud_database OWNER nextcloud;"
PGPASSWORD=<db_pass> pg_restore -h <postgres> -U nextcloud \
  -d nextcloud_database --no-owner --role=nextcloud /tmp/db-restore/dump/nextcloud_db.dump
```

### 3. Bring it back up and verify

```bash
kubectl scale deployment nextcloud -n nextcloud --replicas=1

# Once running:
POD=$(kubectl get pod -n nextcloud -l app=nextcloud -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n nextcloud $POD -- su -s /bin/sh www-data -c "php occ maintenance:mode --off"
kubectl exec -n nextcloud $POD -- su -s /bin/sh www-data -c "php occ files:scan --all"
kubectl exec -n nextcloud $POD -- su -s /bin/sh www-data -c "php occ status"
```

Note: `config.php` identity values (instanceid / secret / passwordsalt) must match
the restored database. They're held in the sealed secret — if you rebuilt the
cluster, restore that sealed secret first so the values line up with the DB.

---

## Gitea restore

Gitea backup is a single `gitea-data` snapshot of the /data volume, which on this
deployment contains the SQLite database, repositories, config, and LFS objects.

### 1. Restore the data

Bring up Gitea via ArgoCD so the PVC exists, then scale to 0:

```bash
kubectl scale deployment gitea -n gitea --replicas=0
```

Restore the snapshot into the gitea-data PVC (via a pod mounting it):

```bash
restic snapshots --tag gitea-data
restic restore latest --tag gitea-data --target /restore-target
# snapshot's /data maps to the PVC root
```

### 2. Regenerate hooks — REQUIRED

A raw-volume restore does NOT restore working git hooks if the install path or
method changed. After restoring, regenerate them or pushes will fail:

```bash
kubectl scale deployment gitea -n gitea --replicas=1

POD=$(kubectl get pod -n gitea -l app=gitea -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n gitea $POD -- su git -c "/usr/local/bin/gitea admin regenerate hooks"
# If issues persist:
kubectl exec -n gitea $POD -- su git -c "/usr/local/bin/gitea doctor check --all"
```

### 3. Verify

Browse a repo, confirm commits are present, and test a push to confirm hooks work.

---

## Partial restore (single file / repo)

restic can mount a repository as a filesystem to cherry-pick files without a
full restore:

```bash
restic mount /mnt/restic       # browse snapshots/ as a directory tree
# copy out what you need, then unmount
```

---

## Restore testing cadence

A backup is only real if a restore has been verified. Recommended:
- `restic check` after every cluster rebuild (cheap, run it).
- A full test restore of each service into a scratch namespace once a quarter.
- Document the date of the last successful test restore here:

| Service   | Last test restore | Result |
|-----------|-------------------|--------|
| Nextcloud | (pending)         |        |
| Gitea     | (pending)         |        |
