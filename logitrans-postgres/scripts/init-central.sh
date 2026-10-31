#!/bin/bash
set -Eeuo pipefail
psql -X -v ON_ERROR_STOP=1 --username postgres --dbname logitrans \
  --set=physical="$(cat /run/secrets/physical)" \
  --set=logical="$(cat /run/secrets/logical)" -f /lab/sql/central.sql
