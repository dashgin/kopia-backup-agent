# kopia-backup

One Kopia client image for a whole fleet. Deployed once per host; hosts differ
only by environment variables.

Each host dumps its own databases locally and uploads a deduplicated, compressed,
encrypted snapshot straight to object storage. There is no central backup server,
no inbound port, and nothing that has to be reachable for a backup to run.

## How it works

The container is the scheduler. It sleeps until `BACKUP_AT`, runs `snapshot.sh`,
and repeats. `snapshot.sh`:

1. connects to the repository if it isn't already (config persists on a volume)
2. refuses to start unless the staging volume has `MIN_FREE_MB` free
3. dumps every `PG_SOURCE_*` into `/staging/postgres/<label>.dump`
4. dumps every `PGALL_SOURCE_*` into `/staging/postgres/<label>.cluster.sql`
5. mirrors every `RCLONE_SOURCE_*` into `/staging/files/<label>/`
6. deletes anything in staging with no matching source
7. takes **one** Kopia snapshot of `/staging`
8. verifies the snapshot is listed, then reports to Uptime Kuma and Telegram

```
   databases ──► /staging ──► kopia snapshot ──► object storage
   (local net)     │                              chunked · zstd · AES-256
                   ├── postgres/<label>.dump      encrypted before it leaves
                   └── files/<label>/             the host
```

Everything lands in a single snapshot on purpose. A restore needs rows and the
files those rows reference to come from the same instant — a database restored
alongside stale objects is a half-restore.

## Why it is built this way

**The schedule lives in the container.** An earlier version was triggered by the
deployment platform's scheduler. That meant the control plane dying silently
stopped every backup in the fleet, while each container sat idle looking
perfectly healthy — and the monitoring that would have reported it lived on the
same host that had just disappeared. The scheduler runs as PID 1, so its output
and `snapshot.sh`'s land on the container's stdout and show up in `docker logs`
with no redirection tricks.

It also avoids Kopia's snapshot *actions*, which are disabled unless
`--enable-actions` is passed and whose `--action-command-timeout` defaults to
five minutes — long enough to look fine in testing and short enough to silently
truncate a real dump.

**The image is built once by CI, never on the host.** Building per host ties
every deploy to a Git provider. A provider scoped to the wrong organisation is
how one host ended up with no backup at all for five days, while the API
cheerfully reported that it had access.

**`pg_dump --compress=0`.** `-Fc` compresses by default, and compressed output
deduplicates terribly: a 1% data change rewrites essentially the whole byte
stream, so Kopia sees a new file and re-uploads all of it. Dump uncompressed and
let Kopia's zstd compress after content-defined chunking.

**`pg_dumpall` for multi-database servers.** Roles, grants and other cluster-wide
objects live in the globals. A restore without them comes back with no logins and
no permissions.

**Skipping tables you would never restore.** `PG_DUMP_ARGS_<label>` passes extra
flags to one source's `pg_dump` — usually `--exclude-table-data` for a large table
whose contents are scraped or derived and can simply be re-fetched. Use
`--exclude-table-data`, not `--exclude-table`: the first keeps the schema and drops
the rows, the second removes the table and breaks anything that references it.
Check for foreign keys pointing at the table before excluding it, or the restore
will fail on constraint violations. Only `PG_SOURCE_*` supports this —
`pg_dumpall` has no table filter.

**Persistent staging volume.** An earlier sidecar staged into `mktemp -d`, so
`rclone sync` re-downloaded the entire media bucket every night onto the
container's writable layer. It eventually filled the disk and died — silently,
because `set -e` aborted before the heartbeat fired. Staging is now a volume, the
sync is genuinely incremental, and a run that cannot finish refuses to start.

Persistence cuts both ways, so each run deletes the previous dump *before*
dumping (a failed dump must never leave yesterday's file looking current) and
prunes artefacts whose source is no longer configured.

**One dead source does not cost the host its backup.** Failures are collected,
everything that did dump is still snapshotted, and the run reports partial —
naming exactly which sources failed and why.

## Configuration

See [.env.example](.env.example). The only per-host differences are
`KOPIA_HOSTNAME`, `BACKUP_AT`, and which `PG_SOURCE_*` / `PGALL_SOURCE_*` /
`RCLONE_SOURCE_*` entries exist.

Verify a host's schedule without waiting a day:

```sh
docker compose exec kopia run-scheduler.sh --next
```

Run a backup by hand:

```sh
docker compose exec kopia snapshot.sh
```

## Deploying

The image is public. Pull it; do not build it.

```yaml
image: ghcr.io/dashgin/kopia-backup-agent:${IMAGE_TAG:-latest}
```

Pin `IMAGE_TAG` to a `sha-…` tag in each host's environment once you have one, so
a rebuild never silently changes what a host runs on its next redeploy.

## Restore

The repository is independent of every host, and of whatever deployed them. From
any machine with `kopia` installed:

```sh
export KOPIA_PASSWORD='<repository password>'

kopia repository connect s3 \
  --bucket=<bucket> \
  --endpoint=<s3 endpoint> \
  --region=<region> \
  --access-key=<key id> --secret-access-key=<application key>

kopia snapshot list --all                 # every host
kopia snapshot restore <snapshot-id> ./restored
```

Then load the database:

```sh
pg_restore --clean --if-exists --no-owner --no-privileges \
  -d 'postgresql://…' ./restored/postgres/<label>.dump
```

Objects go back with `rclone sync ./restored/files/<label> <remote>:<bucket>`.

You do **not** need any host, control plane, or UI to restore. The repository
password plus the storage key is sufficient — that is the whole point.

## Operational notes

- **`kopia.repository`** is a ~1 KB blob in the bucket holding the format and
  key-derivation parameters. Lose it and the bucket is unreadable *even with the
  correct password*. Keep a copy outside the bucket.
- **Retention is set on the repository, not here.** Every snapshot is
  independently restorable, so pruning an old one can never damage a newer one.
- **One maintenance owner.** Full maintenance (GC, blob deletion) runs from a
  single machine. Point it at something that is always on — if the owner is a
  laptop, space is only ever reclaimed when that laptop happens to be connected.
- **Never run `kopia snapshot verify --verify-files-percent=100`** against
  metered storage. It re-downloads every byte and can exhaust a daily cap,
  blocking all repository access including backups. Plain
  `kopia snapshot verify` checks structure with almost no egress.
- **Object Lock protects versions, not visibility.** A DELETE writes a delete
  marker that hides the current version; Kopia then reports the blob missing.
  Remove the marker to recover.

## Licence

MIT.
