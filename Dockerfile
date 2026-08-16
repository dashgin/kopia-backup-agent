# Kopia client image — one image for every host in the estate.
#
# kopia/kopia is Ubuntu 22.04 and already ships rclone at /usr/bin/rclone, so the
# only addition is the Postgres client.
#
# postgresql-client-17 comes from PGDG rather than jammy's default 14 because
# pg_dump must be >= the server it dumps, and the fleet runs Postgres 17.
# Change the major version here if yours differs.
FROM kopia/kopia:0.23.1

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg tzdata \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt jammy-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client-17 \
 && rm -rf /var/lib/apt/lists/*

COPY snapshot.sh run-scheduler.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/snapshot.sh /usr/local/bin/run-scheduler.sh

# The scheduler is PID 1: it sleeps until BACKUP_AT, runs snapshot.sh, repeats.
# Staying resident also keeps the Kopia cache warm, which is what makes
# subsequent runs fast.
ENTRYPOINT []
CMD ["/usr/local/bin/run-scheduler.sh"]
