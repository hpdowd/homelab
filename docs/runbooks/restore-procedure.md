# Restoring from the B2 backups

This is the runbook I'll be very glad exists if I ever need it. It covers
Nextcloud and Gitea, both backed up to Backblaze B2 by the daily restic
CronJobs.

## What you need before you start

- A working k3s cluster with Longhorn, ArgoCD, and Sealed Secrets installed,
  and the `backup-credentials` SealedSecret restored to the relevant
  namespace. (If the cluster itself is gone, build it first; everything
  except the secret bootstrapping is in this repo.)
- `RESTIC_PASSWORD` and the B2 keys from my password manager. **If the
  cluster is the thing you're recovering from, these are NOT in the cluster
  anymore.** That's the whole point of keeping them in the password manager.
- restic on your machine, OR a willingness to run it inside a throwaway pod
  (snippet below).

A note on which repo path to use: the restic repo URL ends in
`/nextcloud`, `/gitea`, `/immich`, or `/paperless`. Swap the suffix
depending on what you're restoring.
And the URL has to start with `s3:https://`, without the `s3:` prefix,
restic treats it as a local-disk path, "succeeds" writing to the pod's
ephemeral storage, and you get nothing. I learned this the painful way.

---

## Step 0: Get restic talking to B2

On a machine with restic installed:

```bash
export RESTIC_REPOSITORY="s3:https://s3.eu-central-003.backblazeb2.com/hpd.homelab/nextcloud"
export RESTIC_PASSWORD="<from password manager>"
export AWS_ACCESS_KEY_ID="<b2 key id>"
export AWS_SECRET_ACCESS_KEY="<b2 app key>"

restic snapshots   # should list snapshots — confirms you can read the repo
restic check       # checks the repo is internally consistent. Do this BEFORE relying on a restore.
```

`restic check` is the thing that catches "the bucket has been quietly
corrupted for 6 months and I never noticed". Run it now, not after you've
nuked the only good copy of the data.

If you don't have restic locally but the cluster is up, run it inside a
pod; the `backup-credentials` secret already has everything you need:

```bash
kubectl run restic-restore -n <namespace> --rm -it --restart=Never \
  --image=alpine:3.20 \
  --overrides='{"spec":{"containers":[{"name":"restic-restore","image":"alpine:3.20","command":["/bin/sh","-c","apk add --no-cache restic && exec sh"],"envFrom":[{"secretRef":{"name":"backup-credentials"}}],"stdin":true,"tty":true}]}}'
```

---

## Restoring Nextcloud

Two snapshots come out of each Nextcloud backup, tagged separately:

- `nextcloud-data`, the contents of the `/var/www/html` PVC (files, app
  state, `config.php`, the lot).
- `nextcloud-db`, a Postgres `pg_dump` in custom format.

You restore both. Order doesn't matter strictly but it's easier to do data
first then DB.

### 1. Bring the app up empty, then take it offline

Let ArgoCD deploy Nextcloud + Postgres + Redis so the PVCs and Postgres
actually exist. Then scale Nextcloud to 0, you don't want it writing while
you're restoring underneath it:

```bash
kubectl scale deployment nextcloud -n nextcloud --replicas=0
```

Leave Postgres running (you need it for the DB import in step 3).

### 2. Restore the data into the PVC

Spin up a temporary pod that mounts the `nextcloud-data` PVC and run
`restic restore` into it. Pseudocode:

```bash
restic snapshots --tag nextcloud-data    # find the snapshot you want (usually 'latest')
restic restore latest --tag nextcloud-data --target /restore-target
# The snapshot's /data maps to the PVC's contents.
```

Make sure ownership ends up as `www-data` (UID 33), Nextcloud will refuse
to read files it doesn't own. `chown -R 33:33 /restore-target` if you need
to.

### 3. Restore the database

```bash
restic restore latest --tag nextcloud-db --target /tmp/db-restore
# yields /tmp/db-restore/dump/nextcloud_db.dump

# Drop and recreate the DB, then load the dump:
PGPASSWORD=<db_pass> psql -h <postgres> -U nextcloud -d postgres \
  -c "DROP DATABASE nextcloud_database;" \
  -c "CREATE DATABASE nextcloud_database OWNER nextcloud;"

PGPASSWORD=<db_pass> pg_restore -h <postgres> -U nextcloud \
  -d nextcloud_database --no-owner --role=nextcloud \
  /tmp/db-restore/dump/nextcloud_db.dump
```

`--no-owner --role=nextcloud` makes pg_restore ignore the ownership baked
into the dump (which references the old AIO role `oc_nextcloud`) and just
own everything as `nextcloud`. Without this you get GRANT errors.

### 4. Start Nextcloud and check it's actually OK

```bash
kubectl scale deployment nextcloud -n nextcloud --replicas=1

POD=$(kubectl get pod -n nextcloud -l app=nextcloud -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n nextcloud $POD -- su -s /bin/sh www-data -c "php occ maintenance:mode --off"
kubectl exec -n nextcloud $POD -- su -s /bin/sh www-data -c "php occ files:scan --all"
kubectl exec -n nextcloud $POD -- su -s /bin/sh www-data -c "php occ status"
```

`occ files:scan --all` reconciles the filesystem with the database, if any
files weren't tracked in the DB (or the DB references files that aren't
there) this rebuilds the index.

**Important:** the `instanceid` / `secret` / `passwordsalt` values in
`config.php` must match the DB you just restored. They're held in the
SealedSecret. If you rebuilt the cluster, make sure that SealedSecret was
restored before Nextcloud started, otherwise every encrypted field
(passwords, share tokens) is unreadable and looks like data corruption.

---

## Restoring Gitea

One snapshot: `gitea-data`, the whole `/data` volume. That has the SQLite
database, the repos, LFS objects, hooks, and config inside it.

### 1. Bring it up, scale to 0

```bash
kubectl scale deployment gitea -n gitea --replicas=0
```

### 2. Restore the volume

Same pattern as Nextcloud, pod that mounts `gitea-data`, then:

```bash
restic snapshots --tag gitea-data
restic restore latest --tag gitea-data --target /restore-target
# The snapshot's /data maps to the PVC root.
```

### 3. Regenerate git hooks: DO NOT SKIP

A raw-volume restore brings back the data files but the per-repo git hooks
have absolute paths and assumptions baked in. If anything changed (image
version, install path), pushes will silently fail or behave weirdly until
you regenerate them:

```bash
kubectl scale deployment gitea -n gitea --replicas=1

POD=$(kubectl get pod -n gitea -l app=gitea -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n gitea $POD -- su git -c "/usr/local/bin/gitea admin regenerate hooks"

# If something's still off:
kubectl exec -n gitea $POD -- su git -c "/usr/local/bin/gitea doctor check --all"
```

### 4. Verify

Open Gitea, browse a repo, do a `git clone` + `git push` from somewhere
else against it. If the push completes and the commits show in the UI,
you're back.

---

## Restoring Immich

Two snapshots per night, same shape as Nextcloud:

- `immich-data`, the library PVC (`/data` in the pod: originals under
  `upload/` and `library/`, profile pictures, server-side backups).
  `thumbs/` and `encoded-video/` are NOT in the backup, Immich
  regenerates them, see below.
- `immich-db`, `pg_dump` of the `immich` database in custom format.

### 1. Bring it up empty, scale the server to 0

Let ArgoCD create the namespace, PVCs, Postgres and Redis, then:

```bash
kubectl scale deployment immich-server -n immich --replicas=0
```

Leave Postgres running for step 3.

### 2. Restore the library into the PVC

Pod that mounts `immich-library`, then:

```bash
restic snapshots --tag immich-data
restic restore latest --tag immich-data --target /restore-target
# The snapshot's /data maps to the PVC root.
```

### 3. Restore the database

```bash
restic restore latest --tag immich-db --target /tmp/db-restore
# yields /tmp/db-restore/dump/immich_db.dump

PGPASSWORD=<db_pass> psql -h postgres.immich -U postgres -d postgres \
  -c "DROP DATABASE immich;" \
  -c "CREATE DATABASE immich OWNER postgres;"

PGPASSWORD=<db_pass> pg_restore -h postgres.immich -U postgres \
  -d immich /tmp/db-restore/dump/immich_db.dump
```

The DB password is in the `immich-secrets` SealedSecret (and the password
manager). Postgres must be the same paired image from the manifests,
the dump carries VectorChord-backed tables, a vanilla postgres won't
load the extension.

### 4. Start the server, regenerate derivatives

```bash
kubectl scale deployment immich-server -n immich --replicas=1
```

Log in, confirm the timeline shows assets. Thumbnails will be missing,
queue the regeneration jobs in the admin UI (Administration → Jobs →
"Generate Thumbnails", and "Transcode Videos" if needed). The library is
usable while they grind through.

---

## Restoring Paperless

Two snapshots per night, same shape as Immich:

- `paperless-media`, the `media` PVC — the irreplaceable originals plus the
  OCR'd archive. This is what actually matters.
- `paperless-db`, `pg_dump` of the `paperless` database in custom format
  (holds tags, correspondents, document metadata, the user table).

The search index lives on the `data` PVC and is NOT backed up — it's
regenerable from the documents (`document_index reindex`), see step 4.

### 1. Bring it up empty, scale the app to 0

Let ArgoCD create the namespace, PVCs, Postgres and Valkey, then:

```bash
kubectl scale deployment paperless -n paperless --replicas=0
```

Leave Postgres running for step 3.

### 2. Restore the media into the PVC

Pod that mounts `paperless-media`, then:

```bash
restic snapshots --tag paperless-media
restic restore latest --tag paperless-media --target /restore-target
# The snapshot's /media maps to the PVC root.
```

### 3. Restore the database

```bash
restic restore latest --tag paperless-db --target /tmp/db-restore
# yields /tmp/db-restore/dump/paperless_db.dump

PGPASSWORD=<db_pass> psql -h postgres.paperless -U paperless -d postgres \
  -c "DROP DATABASE paperless;" \
  -c "CREATE DATABASE paperless OWNER paperless;"

PGPASSWORD=<db_pass> pg_restore -h postgres.paperless -U paperless \
  -d paperless /tmp/db-restore/dump/paperless_db.dump
```

The DB password (`PAPERLESS_DBPASS`) is in the `paperless-secrets`
SealedSecret and the password manager. Stock `postgres:18-alpine` is fine —
no extension to reload (unlike Immich's VectorChord).

### 4. Start the app, rebuild the search index

```bash
kubectl scale deployment paperless -n paperless --replicas=1
# once it's up, rebuild the Tantivy index from the restored documents:
POD=$(kubectl get pod -n paperless -l app=paperless -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n paperless "$POD" -- document_index reindex
```

Log in, confirm documents list and that full-text search returns hits (the
index rebuild is what makes search work again — the documents restore
without it, but you can't search until reindex completes).

### The version-portable export (the better insurance)

The pg_dump + media restore above ties you to the same Paperless schema.
For a restore that survives a major-version jump, Paperless' own
`document_exporter` writes a portable `manifest.json` + originals that
`document_importer` reads back. It's NOT in the nightly cron (the `media`
PVC is RWO, so a second writer can't mount it live). Run it periodically by
hand into the media PVC and let the nightly restic sweep it up:

```bash
POD=$(kubectl get pod -n paperless -l app=paperless -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n paperless "$POD" -- document_exporter ../media/export
```

To restore from it instead of the pg_dump: `document_importer ../media/export`
into a freshly bootstrapped instance.

---

## Pulling out a single file

You don't always need a full restore. restic can mount the repo as a
filesystem so you can copy specific things out:

```bash
restic mount /mnt/restic
# /mnt/restic/snapshots/<id>/... — browse like a normal directory tree
# copy what you need
fusermount -u /mnt/restic
```

---

## When did I actually test this?

A backup that's never been restored is a hope, not a backup. I should run a
full test restore into a scratch namespace once a quarter and update the
table below. (If both rows say "pending" and you're reading this, go do
one.)

| Service   | Last test restore | Result |
|-----------|-------------------|--------|
| Nextcloud | 2026-06-12        | OK — `restic check` clean, 10% read-data clean (182 packs), DB dump restored + `pg_restore --list` valid (1642 TOC entries, PG 18.4), config + sample dirs restored from B2 sha256-identical to live. One dir "missing" turned out to be created an hour *after* the snapshot — expected. |
| Gitea     | 2026-06-12        | OK — `restic check --read-data` clean (100% of packs), full restore, `PRAGMA integrity_check` = ok on the restored SQLite DB, all 12 repos present in `/data/git/henry/`. |
| Immich    | (pending)         | Repo seeded + first snapshot verified on deploy day (2026-06-12), but no test restore yet — do one once the library has real photos in it. |

Notes from the 2026-06-12 run: in-cluster throwaway pods with each
namespace's `backup-credentials` (the pattern in operations.md) work fine
for this. Give the pod an `ephemeral-storage` limit, a full restore of
the Nextcloud data set fills the worker's root disk and gets the pod
evicted. Restore a bounded `--include` instead.
