#!/usr/bin/env bash
#
# One backup run for one host.
#
# Dumps every configured database and mirrors every configured object store into
# a single staging directory, then takes ONE Kopia snapshot of the whole thing.
#
# The single-snapshot part matters: a restore needs rows and the files they
# reference to come from the same moment. Restoring a database whose rows point
# at objects that no longer exist is a half-restore.
#
# Sources are discovered from the environment, so one image serves every host:
#
#   PG_SOURCE_<label>=postgres://user:pass@host:5432/dbname
#   RCLONE_SOURCE_<label>=<remote>:<path>
#
# e.g. PG_SOURCE_app=... and RCLONE_SOURCE_media=s3:example-media produce
# /staging/postgres/app.dump and /staging/files/media/.
#
# Invoked by run-scheduler.sh, which is the container's PID 1. Deliberately not
# Kopia's own snapshot actions: those are disabled unless --enable-actions is
# passed, and their five-minute default timeout is long enough to look fine in
# testing and short enough to silently truncate a real dump.
set -uo pipefail

STAGING="${STAGING_DIR:-/staging}"
KUMA="${KUMA_PUSH_URL:-}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

push() {  # push <up|down> <short-msg>
  [ -n "$KUMA" ] || return 0
  curl -fsS --max-time 10 "${KUMA}?status=$1&msg=$2" >/dev/null 2>&1 \
    || log "WARNING: could not reach Uptime Kuma"
}

# Direct Telegram alert, in addition to the Kuma push. Kuma tells you *that*
# something is down; this tells you *which source* and *why*, without opening a
# dashboard. Plain text, no parse_mode — error strings contain characters that
# would break HTML/Markdown parsing and silently drop the message.
telegram() {  # telegram <text>
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -fsS --max-time 15 -o /dev/null \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    ${TELEGRAM_THREAD_ID:+-d message_thread_id=${TELEGRAM_THREAD_ID}} \
    --data-urlencode "text=$1" \
    || log "WARNING: could not send Telegram alert"
}

HOST_LABEL="${KOPIA_HOSTNAME:-$(hostname)}"

fail() {   # only for conditions that make the whole run impossible
  log "FAILED: $*"
  push down "failed"
  telegram "🔴 Backup FAILED — ${HOST_LABEL}

Nothing was backed up.

$*"
  exit 1
}

# A single unreachable database must NOT cost the host its entire backup. Source
# failures are collected here; everything that did dump still gets snapshotted,
# and the run reports down at the end so the failure is visible rather than
# silently dropping one database from an otherwise green backup.
FAILED_SOURCES=""
FAILED_DETAIL=""

note_failure() {  # note_failure <label> <detail>
  log "  ERROR: $2"
  FAILED_SOURCES="$FAILED_SOURCES $1"
  FAILED_DETAIL="${FAILED_DETAIL}
• $2"
}

# --- connect (idempotent; config persists on the config volume) --------------
# Optional second repository, e.g. on Google Drive, so one provider failing
# (a B2 storage cap, an expired key) no longer means no backup at all:
#
#   MIRROR_RCLONE_PATH=gdrive:kopia/<host>     enables it (rclone remote:path)
#   MIRROR_KOPIA_PASSWORD=                     defaults to KOPIA_PASSWORD
#   RCLONE_CONFIG_GDRIVE_*                     defines the `gdrive` remote
#
# Each repository is snapshotted independently: one failing is reported as a
# partial run, and the run only fails outright when neither took a snapshot.
MIRROR_PATH="${MIRROR_RCLONE_PATH:-}"
MIRROR_CONFIG="$(dirname "${KOPIA_CONFIG_PATH:-/app/config/repository.config}")/mirror.config"
# The mirror needs its OWN cache directory, set through the environment and not
# only with --cache-directory. With the shared KOPIA_CACHE_DIRECTORY, kopia 0.23
# picks up the primary repository's cached blob config, including B2's
# COMPLIANCE object lock, and writes it into the new repository. Every write then
# fails on a backend without object lock ("blob-retention: unsupported put-blob
# option"). Verified 2026-11-07: an empty environment creates cleanly, and adding
# only KOPIA_CACHE_DIRECTORY=/cache reproduces the failure.
MIRROR_CACHE="${KOPIA_CACHE_DIRECTORY:-/cache}/mirror"
mirror() {
  KOPIA_PASSWORD="${MIRROR_KOPIA_PASSWORD:-${KOPIA_PASSWORD:-}}" \
  KOPIA_CACHE_DIRECTORY="$MIRROR_CACHE" \
    kopia --config-file="$MIRROR_CONFIG" "$@"
}

# PRIMARY_REPO=off skips the B2 repository entirely, for a host whose data
# should live only in the mirror. Example: Praxis media is too big for the B2
# free tier. Off needs a mirror, otherwise nothing would be backed up.
PRIMARY_READY=1
if [ "${PRIMARY_REPO:-on}" = "off" ]; then
  [ -n "$MIRROR_PATH" ] || fail "PRIMARY_REPO=off but no MIRROR_RCLONE_PATH: nothing would be backed up"
  log "primary repository disabled (PRIMARY_REPO=off); mirror only"
  PRIMARY_READY=0
elif ! kopia repository status >/dev/null 2>&1; then
  log "connecting to repository"
  if ! kopia repository connect s3 \
      --bucket="$B2_BUCKET" \
      --endpoint="$B2_ENDPOINT" \
      --region="$B2_REGION" \
      --access-key="$B2_KEY_ID" \
      --secret-access-key="$B2_APP_KEY"; then
    [ -n "$MIRROR_PATH" ] || fail "could not connect to repository"
    note_failure primary-repo "could not connect to the primary (B2) repository"
    PRIMARY_READY=0
  fi
fi

MIRROR_READY=0
if [ -n "$MIRROR_PATH" ]; then
  MIRROR_READY=1
  if ! mirror repository status >/dev/null 2>&1; then
    log "connecting to mirror repository: $MIRROR_PATH"
    # Connect first; create only when there is nothing there yet. `create`
    # refuses to overwrite an existing repository, so a connect that failed for
    # a transient reason cannot clobber one.
    if ! mirror repository connect rclone --remote-path="$MIRROR_PATH" \
          --cache-directory="$MIRROR_CACHE" >/dev/null 2>&1 \
       && ! mirror repository create rclone --remote-path="$MIRROR_PATH" \
          --cache-directory="$MIRROR_CACHE"; then
      note_failure mirror-repo "could not connect to or create the mirror repository at $MIRROR_PATH"
      MIRROR_READY=0
    fi
  fi
fi
[ "$PRIMARY_READY" = 1 ] || [ "$MIRROR_READY" = 1 ] || fail "no repository is reachable"

# --- preflight ---------------------------------------------------------------
# The restic sidecar this replaces staged into `mktemp -d` on the container's
# writable layer, so every run re-downloaded the entire bucket and eventually hit
# "no space left on device" — silently, because set -e aborted before the
# heartbeat fired. Staging is a persistent volume now, and we refuse to start a
# run that cannot finish rather than dying halfway through it.
mkdir -p "$STAGING/postgres" "$STAGING/files" || fail "cannot write to $STAGING"
MIN_FREE_MB="${MIN_FREE_MB:-2048}"
FREE_MB=$(df -Pm "$STAGING" | awk 'NR==2 {print $4}')
log "free space in $STAGING: ${FREE_MB}MB (minimum ${MIN_FREE_MB}MB)"
[ "${FREE_MB:-0}" -ge "$MIN_FREE_MB" ] \
  || fail "insufficient disk: ${FREE_MB}MB free, need ${MIN_FREE_MB}MB"

FOUND=0

# --- databases ---------------------------------------------------------------
# --compress=0 is deliberate. pg_dump -Fc compresses by default, and compressed
# output deduplicates terribly: a 1% data change rewrites essentially the whole
# byte stream, so Kopia sees a brand-new file and re-uploads all of it. Dump
# uncompressed and let Kopia's zstd compress after content-defined chunking.
for var in $(env | sed -n 's/^\(PG_SOURCE_[A-Za-z0-9_]*\)=.*/\1/p' | sort); do
  label="${var#PG_SOURCE_}"
  url="${!var}"
  [ -n "$url" ] || continue
  log "dumping postgres: $label"
  target="${STAGING}/postgres/${label}.dump"

  # Optional extra pg_dump flags for this source, e.g.
  #   PG_DUMP_ARGS_shop=--exclude-table-data=public.scraped_listings
  #
  # The usual reason is a large table whose contents are derived from somewhere
  # else and can simply be re-fetched, where backing it up nightly costs real
  # money for data you would never restore.
  #
  # Prefer --exclude-table-data over --exclude-table: it keeps the table's
  # definition, indexes and constraints and drops only the rows, so the restored
  # database still has a schema the application can start against. Excluding the
  # table outright leaves anything referencing it broken.
  #
  # Deliberately unquoted below so multiple flags word-split into separate
  # arguments. Keep values free of spaces and shell metacharacters.
  args_var="PG_DUMP_ARGS_${label}"
  extra_args="${!args_var:-}"
  [ -n "$extra_args" ] && log "  extra pg_dump args: ${extra_args}"

  # Remove the previous dump FIRST. Staging is persistent, so a failed dump
  # would otherwise leave yesterday's file in place and the snapshot would
  # quietly present stale data as though it were current — the worst kind of
  # backup bug, because it looks like success.
  rm -f "$target"

  # shellcheck disable=SC2086
  if ! pg_dump --format=custom --compress=0 --no-owner --no-privileges \
       $extra_args --file="$target" "$url" 2>"${STAGING}/postgres/.${label}.err"; then
    note_failure "$label" "pg_dump failed for $label: $(tail -1 "${STAGING}/postgres/.${label}.err")"
    rm -f "$target" "${STAGING}/postgres/.${label}.err"
    continue
  fi
  rm -f "${STAGING}/postgres/.${label}.err"
  log "  -> $(du -h "$target" | cut -f1)"
  FOUND=$((FOUND + 1))
done

# --- whole Postgres clusters -------------------------------------------------
# For a server hosting several databases, pg_dump per database is not enough:
# roles, grants and other cluster-wide objects live in the globals, and a
# restore without them comes back with no logins and no permissions.
# pg_dumpall captures every database plus the globals.
#
# Output is plain SQL, which is uncompressed and therefore dedups well — the
# same reason PG_SOURCE_* passes --compress=0.
for var in $(env | sed -n 's/^\(PGALL_SOURCE_[A-Za-z0-9_]*\)=.*/\1/p' | sort); do
  label="${var#PGALL_SOURCE_}"
  url="${!var}"
  [ -n "$url" ] || continue
  log "dumping whole cluster: $label"
  out="${STAGING}/postgres/${label}.cluster.sql"
  err="${STAGING}/postgres/.${label}.err"

  # pg_dumpall opens a NEW connection for every database it finds, and those
  # connections do not inherit the password from --dbname. Without PGPASSWORD it
  # fails on the first one with "fe_sendauth: no password supplied".
  PGPASSWORD=$(printf '%s' "$url" | sed -n 's|^[a-z]*://[^:/]*:\([^@]*\)@.*|\1|p')
  export PGPASSWORD

  # Stale-data guard, same as above: clear the previous dump before trying.
  rm -f "$out"

  # Prefer a dump *with* role passwords — without them the restored roles
  # cannot authenticate, which turns a restore into a manual credential reset.
  # Reading them needs superuser, so fall back rather than give up.
  if ! pg_dumpall --dbname="$url" > "$out" 2>"$err"; then
    log "  full dump refused ($(tail -1 "$err")); retrying without role passwords"
    if ! pg_dumpall --dbname="$url" --no-role-passwords > "$out" 2>"$err"; then
      note_failure "$label" "pg_dumpall failed for $label: $(tail -1 "$err")"
      rm -f "$out" "$err"
      unset PGPASSWORD
      continue
    fi
    log "  WARNING: role passwords are NOT in this dump — a restore will need them reset"
  fi
  unset PGPASSWORD
  rm -f "$err"
  log "  -> $(du -h "$out" | cut -f1)"
  FOUND=$((FOUND + 1))
done

# --- object stores -----------------------------------------------------------
# Incremental against the persistent volume: only changed objects transfer.
for var in $(env | sed -n 's/^\(RCLONE_SOURCE_[A-Za-z0-9_]*\)=.*/\1/p' | sort); do
  label="${var#RCLONE_SOURCE_}"
  src="${!var}"
  [ -n "$src" ] || continue
  log "syncing $src -> files/$label"
  # Not removed beforehand, unlike the dumps: rclone sync is incremental against
  # the existing mirror, and a partial sync still leaves a coherent tree.
  if ! rclone sync "$src" "${STAGING}/files/${label}" \
       --transfers 8 --checkers 16 --stats=0 --progress=false 2>"${STAGING}/files/.${label}.err"; then
    note_failure "$label" "rclone sync failed for $label: $(tail -1 "${STAGING}/files/.${label}.err")"
    rm -f "${STAGING}/files/.${label}.err"
    continue
  fi
  rm -f "${STAGING}/files/.${label}.err"
  log "  -> $(du -sh "${STAGING}/files/${label}" | cut -f1)"
  FOUND=$((FOUND + 1))
done

# Nothing at all succeeded — there is no point snapshotting an empty or entirely
# stale staging directory, and a run that backs up nothing must never report
# success. Misconfigured env is the likeliest way this becomes a silent no-op.
if [ "$FOUND" -eq 0 ]; then
  fail "no source produced a backup (failed:${FAILED_SOURCES:- none configured})"
fi

# --- prune artefacts of sources that no longer exist --------------------------
# Removing a source from the environment does not remove its last dump, and
# staging is persistent — so that file would be snapshotted every night forever,
# presenting data frozen on the day the source was dropped as though it were
# current. Caught in the wild: after a database migrated to another server and
# its source was removed, that host's snapshot stayed 162.8 MB, still carrying a
# 150 MB dump of data that had moved. Nothing in the output looked wrong — the
# run reported three sources backed up, and green.
EXPECTED=""
for var in $(env | sed -n 's/^\(PG_SOURCE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  [ -n "${!var}" ] && EXPECTED="$EXPECTED ${var#PG_SOURCE_}.dump"
done
for var in $(env | sed -n 's/^\(PGALL_SOURCE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  [ -n "${!var}" ] && EXPECTED="$EXPECTED ${var#PGALL_SOURCE_}.cluster.sql"
done
for var in $(env | sed -n 's/^\(RCLONE_SOURCE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  [ -n "${!var}" ] && EXPECTED="$EXPECTED ${var#RCLONE_SOURCE_}"
done

for path in "$STAGING"/postgres/* "$STAGING"/files/*; do
  [ -e "$path" ] || continue
  base=$(basename "$path")
  case " $EXPECTED " in
    *" $base "*) ;;
    *) log "pruning orphaned artefact: $base (no matching source configured)"
       rm -rf "$path" ;;
  esac
done

# --- snapshot ----------------------------------------------------------------
# Reached whenever at least one source worked, so a single dead database costs
# only that database rather than the whole host's backup.
#
# Prove each snapshot exists before counting it. A job that reports success
# without checking is how the previous backup stayed broken for four days.
SNAPSHOTS_OK=0

if [ "$PRIMARY_READY" = 1 ]; then
  log "creating snapshot of $STAGING (primary)"
  if kopia snapshot create "$STAGING" --description "${SNAPSHOT_DESCRIPTION:-nightly}"; then
    COUNT=$(kopia snapshot list "$STAGING" --json 2>/dev/null | grep -c '"startTime"' || echo 0)
    if [ "${COUNT:-0}" -gt 0 ]; then
      log "primary: snapshots for this source: $COUNT"
      SNAPSHOTS_OK=$((SNAPSHOTS_OK + 1))
    else
      [ -n "$MIRROR_PATH" ] || fail "snapshot command succeeded but none is listed"
      note_failure primary-repo "primary snapshot succeeded but none is listed"
    fi
  else
    [ -n "$MIRROR_PATH" ] || fail "kopia snapshot failed"
    note_failure primary-repo "kopia snapshot to the primary (B2) repository failed"
  fi
fi

if [ "$MIRROR_READY" = 1 ]; then
  log "creating snapshot of $STAGING (mirror: $MIRROR_PATH)"
  if mirror snapshot create "$STAGING" --description "${SNAPSHOT_DESCRIPTION:-nightly}"; then
    COUNT=$(mirror snapshot list "$STAGING" --json 2>/dev/null | grep -c '"startTime"' || echo 0)
    if [ "${COUNT:-0}" -gt 0 ]; then
      log "mirror: snapshots for this source: $COUNT"
      SNAPSHOTS_OK=$((SNAPSHOTS_OK + 1))
    else
      note_failure mirror-repo "mirror snapshot succeeded but none is listed"
    fi
  else
    note_failure mirror-repo "kopia snapshot to the mirror repository failed"
  fi
fi

[ "$SNAPSHOTS_OK" -gt 0 ] || fail "no repository accepted the snapshot"

# --- report ------------------------------------------------------------------
if [ -n "$FAILED_SOURCES" ]; then
  # Labels come from env-var names, so they are already [A-Za-z0-9_] and safe in
  # a URL. Kuma passes msg through to Telegram, so the alert names exactly which
  # sources failed instead of just saying something went wrong.
  list=$(printf '%s' "$FAILED_SOURCES" | tr -s ' ' ',' | sed 's/^,//')
  log "PARTIAL: snapshot taken, but these sources failed: $list"
  log "         everything that did dump is in the snapshot"
  push down "FAILED:${list}%20(${FOUND}%20ok)"
  telegram "🟠 Backup PARTIAL — ${HOST_LABEL}

Failed: ${list}
Succeeded: ${FOUND} source(s)

A snapshot WAS taken in at least one repository and contains everything that
did dump. A failed source is absent from it, not stale; a failed *-repo means
that repository has no snapshot from this run.
${FAILED_DETAIL}"
  exit 1
fi

log "done — backed up $FOUND source(s)"
push up "ok:${FOUND}%20sources"
