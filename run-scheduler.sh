#!/usr/bin/env bash
#
# Container entrypoint. Sleeps until BACKUP_AT, runs snapshot.sh, repeats.
#
# This exists so a backup run does not depend on anything outside the host. The
# previous design was triggered by a Dokploy schedule, which meant the control
# plane dying silently stopped every backup in the estate while each container
# sat idle looking healthy.
#
# Runs as PID 1, so everything it prints — including snapshot.sh's own output —
# lands on the container's stdout and is visible via `docker logs` and Dokploy's
# log view. No `> /proc/1/fd/1` redirection needed.
#
#   BACKUP_AT=HH:MM   time of day in UTC (default 03:00)
#
# `run-scheduler.sh --next` prints the next scheduled run and exits, so the
# schedule can be verified without waiting a day for it.
set -uo pipefail

BACKUP_AT="${BACKUP_AT:-03:00}"
SNAPSHOT_CMD="${SNAPSHOT_CMD:-/usr/local/bin/snapshot.sh}"

# How long a single sleep lasts. Bash only runs traps between commands, so one
# long `sleep 86400` would ignore SIGTERM for the rest of the day and make every
# redeploy wait for the kill timeout. Short naps in a loop stay responsive and
# re-read the clock, which also means a host clock correction cannot strand the
# scheduler at a stale wake-up time.
NAP_SECONDS=60

log() { printf '[%s] scheduler: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$*"; }

trap 'log "termination signal received, exiting"; exit 0' TERM INT

if ! printf '%s' "$BACKUP_AT" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
  log "FATAL: BACKUP_AT='${BACKUP_AT}' is not HH:MM in the range 00:00-23:59"
  exit 1
fi

# Next occurrence of BACKUP_AT, as a UTC epoch. Built from an explicit date so
# the string handed to `date -d` is unambiguous ("2026-08-16 03:00"); relative
# phrasings like "today 03:00" are parsed inconsistently.
next_epoch() {
  local now today tomorrow next
  now=$(date -u +%s)
  today=$(date -u '+%F')
  next=$(date -u -d "${today} ${BACKUP_AT}" +%s) || return 1
  if [ "$next" -le "$now" ]; then
    tomorrow=$(date -u -d 'tomorrow' '+%F') || return 1
    next=$(date -u -d "${tomorrow} ${BACKUP_AT}" +%s) || return 1
  fi
  printf '%s' "$next"
}

human() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S UTC'; }

if [ "${1:-}" = "--next" ]; then
  next=$(next_epoch) || { echo "cannot compute next run time" >&2; exit 1; }
  human "$next"
  exit 0
fi

if [ ! -x "$SNAPSHOT_CMD" ]; then
  log "FATAL: ${SNAPSHOT_CMD} is missing or not executable"
  exit 1
fi

log "started — backups run daily at ${BACKUP_AT} UTC"

while true; do
  next=$(next_epoch) || { log "FATAL: cannot compute next run time"; exit 1; }
  log "next run at $(human "$next") (in $(( (next - $(date -u +%s) + 59) / 60 )) min)"

  while :; do
    remaining=$(( next - $(date -u +%s) ))
    [ "$remaining" -le 0 ] && break
    if [ "$remaining" -gt "$NAP_SECONDS" ]; then sleep "$NAP_SECONDS"; else sleep "$remaining"; fi
  done

  log "starting backup run"
  "$SNAPSHOT_CMD"
  rc=$?
  # A non-zero exit means this run failed or was partial. snapshot.sh has
  # already reported that to Uptime Kuma and Telegram, and the next run is still
  # due tomorrow — so the scheduler logs it and carries on rather than dying and
  # taking every future run with it.
  if [ "$rc" -eq 0 ]; then
    log "run finished successfully"
  else
    log "run FAILED with exit code ${rc} — already reported; scheduling next run anyway"
  fi
done
