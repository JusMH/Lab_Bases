#!/bin/bash
set -Eeuo pipefail
mkdir -p "$PGDATA"
chown postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"
# Password file is outside PGDATA and regenerated at every start; no secret in conninfo.
printf 'central-db:5432:replication:repl_fisica:%s\n' "$(cat /run/secrets/physical)" > /var/lib/postgresql/physical.pgpass
chown postgres:postgres /var/lib/postgresql/physical.pgpass
chmod 600 /var/lib/postgresql/physical.pgpass
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  if [ -n "$(ls -A "$PGDATA")" ]; then
    echo 'Incomplete PGDATA: manual review required; refusing to delete files.' >&2
    exit 1
  fi
  gosu postgres pg_basebackup \
    --dbname='host=central-db user=repl_fisica application_name=regional-db passfile=/var/lib/postgresql/physical.pgpass' \
    -D "$PGDATA" -R -X stream -S regional_physical --checkpoint=fast --no-password
fi
test -f "$PGDATA/standby.signal" || { echo 'standby.signal missing; refusing writable startup' >&2; exit 1; }
exec /usr/local/bin/docker-entrypoint.sh "$@"
