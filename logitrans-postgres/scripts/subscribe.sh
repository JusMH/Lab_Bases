#!/bin/bash
set -Eeuo pipefail
if [ "$(psql -XAt -U postgres -d logitrans -c "SELECT count(*) FROM pg_subscription WHERE subname='sub_empleados'")" = 0 ]; then
  # Feed through stdin; never echo conninfo or include it in process arguments.
  psql -X -v ON_ERROR_STOP=1 -U postgres -d logitrans <<SQL
CREATE SUBSCRIPTION sub_empleados
 CONNECTION 'host=regional-db port=5432 dbname=logitrans user=repl_logica password=$(cat /run/secrets/logical) application_name=bi-empleados connect_timeout=5 options=-crow_security=off'
 PUBLICATION pub_empleados WITH (copy_data=true, slot_name='bi_empleados', failover=false);
SQL
fi
