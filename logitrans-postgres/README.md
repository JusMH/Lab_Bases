# Laboratorio PostgreSQL — LogiTrans S.A.

Laboratorio aislado de tres instancias PostgreSQL 18.6, ejecutado y verificado, con volúmenes independientes. El resumen de la ejecución está en `RESULTADOS.md`:

```text
central-db (172.30.84.2:5432)  -- física --> regional-db (172.30.84.3:5432)
                                                  |
                                             lógica pgoutput
                                                  v
                                         bi-db (172.30.84.4:5432)
```

| Servicio | Puerto Windows, solo loopback | Función y datos |
|---|---|---|
| central-db | 15432 | Primario; empleados y entregas |
| regional-db | 5433 | Standby físico de solo lectura; ambas tablas; emisor lógico |
| bi-db | 5434 | Suscriptor; solamente empleados |

**Diferencia necesaria:** 5432 ya estaba ocupado por un proceso PostgreSQL de Windows (PID 7852 durante la inspección). No se detuvo ni modificó. Se utiliza 15432 para el primario. Los puertos internos siguen siendo 5432. Los puertos publicados están reservados al laboratorio, pero HBA rechaza las conexiones TCP administrativas: la administración autorizada se hace con `docker compose exec -u postgres`, mediante socket Unix y autenticación peer.

## Requisitos y puesta en marcha

Windows con PowerShell 5.1 o posterior, Docker Desktop con motor Linux y Compose v2 o posterior. Acceso a Docker Hub para descargar la imagen. No requiere instalar psql, Python ni PostgreSQL en Windows. Reservar al menos 2 GB de memoria y espacio para tres clústeres y WAL. Entorno comprobado: Docker Engine 29.7.2, Compose v5.3.1. La imagen se fija mediante digest en `.env.example`, para que todos los nodos utilicen exactamente el mismo contenido.

Desde PowerShell:

```powershell
Set-Location C:\Users\Justin\Desktop\Lab_Bases\logitrans-postgres
docker version
docker compose version
Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 15432,5433,5434
docker network ls
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Start
```

`Start` genera `.env` y tres contraseñas aleatorias de 256 bits en `.secrets/` si no existen, limita la ACL local al usuario actual y SYSTEM, levanta los servicios, espera disponibilidad, configura la suscripción si no existe y ejecuta **todas las pruebas, incluido el reinicio**. `.env` no contiene contraseñas. Docker monta los secretos como archivos; no se publican en el repositorio. Conservarlos junto con los volúmenes: regenerarlos no cambia las contraseñas guardadas dentro de clústeres existentes. No compartir `.secrets/`, dumps de catálogos sensibles ni `docker inspect` sin revisar.

Antes del primer arranque en otra máquina, comprobar que no exista un proyecto Compose llamado `logitrans_lab` y que `172.30.84.0/24` no se solape con otra red, VPN o ruta. Si existe un conflicto, cambiar `COMPOSE_PROJECT_NAME` en `.env`. Para cambiar la red hay que actualizar **juntos** el subnet en `.env`, las tres IP estáticas de `compose.yaml` y las IP de HBA y las comprobaciones en `lab.ps1`. No cambiar solo `LAB_SUBNET`. Para puertos ocupados basta cambiar `CENTRAL_PORT`, `REGIONAL_PORT` o `BI_PORT`; no cambiar los puertos del conninfo entre servicios.

## Inicialización física

`sql/central.sql` se ejecuta únicamente durante la inicialización de un volumen vacío del primario. Crea el modelo solicitado, cuatro empleados y tres entregas, roles y publicación. La tabla tiene su PK como identidad de réplica para UPDATE/DELETE. El rol `repl_fisica` tiene LOGIN y REPLICATION, sin SUPERUSER, CREATEDB, CREATEROLE ni BYPASSRLS.

`config/postgresql.conf` establece `wal_level=logical`, diez WAL senders y diez slots en todos los nodos. El primario permite por TCP únicamente el protocolo de replicación física desde la IP del standby y con SCRAM-SHA-256.

El primario crea `regional_physical`, con reserva inicial de WAL. `scripts/standby.sh` genera un passfile con modo 0600 y usa:

```sh
pg_basebackup --dbname='host=central-db user=repl_fisica application_name=regional-db passfile=/var/lib/postgresql/physical.pgpass' \
  -D "$PGDATA" -R -X stream -S regional_physical --checkpoint=fast --no-password
```

`-R` genera `standby.signal` y `primary_conninfo`/`primary_slot_name` en `postgresql.auto.conf`. El passfile evita incluir contraseñas en conninfo. El standby utiliza HBA propio y `hot_standby_feedback=on`. Solo se clona si no existe PG_VERSION y el directorio está vacío. Ante una copia incompleta el script se detiene para revisión; no borra datos. Si desaparece `standby.signal`, rechaza el arranque para evitar un nodo escribible accidental. PGDATA está en `/var/lib/postgresql/18/docker`, dentro del volumen montado en `/var/lib/postgresql`, conforme a la organización de la imagen PostgreSQL 18.

## Replicación lógica desde regional-db

La publicación `pub_empleados FOR TABLE public.empleados` se crea en **central-db**. Sus catálogos y tablas llegan al standby mediante replicación física. Nunca se crean tablas, bases ni publicaciones escribiendo en regional-db.

En BI se crea localmente solo la tabla `empleados`. `scripts/subscribe.sh`, ejecutado como postgres, crea `sub_empleados` con `host=regional-db port=5432 dbname=logitrans user=repl_logica`, publicación `pub_empleados`, `copy_data=true` y slot `bi_empleados`. El secreto se introduce por stdin, sin imprimir el conninfo. PostgreSQL almacena ese secreto en su catálogo de suscripciones, accesible al administrador; no debe volcarse dicho catálogo completo en evidencias. El propietario de la suscripción es postgres local; el usuario remoto tiene privilegios mínimos para leer la tabla publicada.

El slot lógico **se crea y se consume en el standby** usando `pgoutput`; no hay slot lógico en central-db. La conexión real se comprueba mediante el PID del slot unido a `pg_stat_replication`, cliente `172.30.84.4` y aplicación `bi-empleados`, además del conninfo de la suscripción. No basta con verificar el nombre DNS en un archivo.

Durante la creación y la copia inicial, el controlador emite `pg_log_standby_snapshot()` en el primario hasta completar cada fase, con límite de 120 segundos. Esto resuelve la espera de metadatos de transacciones cuando el primario está inactivo. El resto de comprobaciones tiene plazos de 90 segundos, consultas limitadas a 15 segundos y sondeo de 500 ms; una espera no se interpreta como éxito.

No se activa `sync_replication_slots`: esa opción copia slots de failover del primario al standby y **no es necesaria para un slot local decodificando en un standby**. Los slots sincronizados con `synced=true` no pueden utilizarse para decodificar mientras el servidor sigue en recuperación. Este laboratorio no incluye promoción, failover automático ni cambio de origen.

La replicación lógica no replica DDL, secuencias ni la tabla entregas. Por eso BI tiene su esquema propio y no se usa para insertar empleados; su secuencia SERIAL no se sincroniza. Una modificación futura de esquema debe aplicarse de manera coordinada. La réplica física sí reproduce todo el clúster, incluidos roles y catálogos.

## Seguridad y límites del entorno

* `repl_logica`: LOGIN y REPLICATION; CONNECT a logitrans, USAGE en public y SELECT exclusivamente sobre empleados. Sin SELECT sobre entregas ni permisos DML. PUBLIC no tiene CREATE sobre public ni CONNECT/TEMP sobre logitrans.
* `repl_fisica`: protocolo físico solo desde la IP del standby; no se le concede acceso ordinario a logitrans.
* HBA permite peer para el administrador postgres por socket; SCRAM para cada conexión de replicación autorizada y rechaza el resto del TCP. No hay trust ni MD5.
* Contraseñas diferentes para administrador, réplica física y réplica lógica. `.secrets/` y `.env` están ignorados por Git. Los scripts ordinarios no borran volúmenes ni datos preexistentes.
* Red de laboratorio Docker y puertos publicados exclusivamente en 127.0.0.1. SCRAM autentica, pero no cifra el WAL: no hay TLS. Para uso entre hosts se necesitarían TLS y reglas de infraestructura adicionales. Este laboratorio no es un despliegue de producción.
* `max_slot_wal_keep_size=1GB` limita retención por slots. Una interrupción suficientemente larga puede invalidar un slot; revisar `invalidation_reason`, almacenamiento y retrasos. `hot_standby_feedback` puede aumentar bloat en el primario. No hay garantía de cero pérdida frente a una caída del primario: las réplicas son asíncronas.

## Pruebas y resultados

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Test
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Status
Get-ChildItem .\evidencias\tests-*.txt | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content
```

Cada prueba muestra PASS o FAIL, conserva los fallos y devuelve error si alguna comprobación falla. Los archivos `tests-*.txt` registran la ejecución real. No interpretar la existencia de archivos SQL como una prueba aprobada.

| Prueba | Validación |
|---|---|
| A | Tres nodos disponibles con la misma versión 18.x |
| B | Primario fuera de recuperación, regional en recuperación |
| C | Sender físico streaming y receptor WAL con slot y origen correctos |
| D | Copia inicial con valores exactos; INSERT con marcador UUID e ID retornado |
| E | Cambio exacto de departamento y salario en ambos destinos |
| F | DELETE del ID probado, después del reinicio, en los tres nodos |
| G | Entrega con ID, fecha, destino y empleado exactos en regional |
| H | Ausencia comprobada de public.entregas en BI |
| I | Única tabla publicada; conninfo, slot local y conexión real regional → BI |
| J | Roles, privilegios mínimos, hashes SCRAM sin mostrarlos, HBA y parámetros |
| K | transaction_read_only=on y CREATE TABLE realmente rechazado |
| L | Reinicio de los tres contenedores, persistencia de datos y UPDATE nuevo replicado |
| FINAL | Apply worker activo, contadores de errores en cero y enlace físico restaurado |

G se ejecuta antes de F para respetar la FK. Los empleados y entregas temporales se identifican con UUID y se eliminan por ID y marcador, nunca por conteos globales. Solo las secuencias aumentan entre ejecuciones. En un fallo parcial puede quedar un registro TEST_; revisarlo por ID antes de retirarlo. El script no vacía tablas ni reinicializa volúmenes para hacer pasar una prueba.

## Consultas de administración

```powershell
docker compose ps
docker compose exec -T -u postgres central-db psql -d logitrans -c "SELECT application_name,client_addr,state,flush_lsn,replay_lsn FROM pg_stat_replication;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SELECT pg_is_in_recovery(); SELECT status,sender_host,slot_name,flushed_lsn FROM pg_stat_wal_receiver;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SELECT slot_name,slot_type,plugin,active,synced,invalidation_reason FROM pg_replication_slots; SELECT application_name,client_addr,state FROM pg_stat_replication;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SELECT * FROM pg_publication_tables;"
docker compose exec -T -u postgres bi-db psql -d logitrans -c "SELECT subname,subenabled,subslotname,subpublications,split_part(subconninfo,' password=',1) AS safe_endpoint FROM pg_subscription; SELECT * FROM pg_stat_subscription_stats;"
docker compose exec -T -u postgres bi-db psql -d logitrans -c "SELECT * FROM empleados ORDER BY id_empleado; SELECT to_regclass('public.entregas');"
docker compose logs --tail 80 central-db regional-db bi-db
```

El recorte de conninfo es seguro para el formato construido por este laboratorio (password aparece después de user). Si se cambia su formato, revisar también la exportación de evidencias. No usar `SELECT * FROM pg_subscription` ni consultar `pg_authid.rolpassword` al compartir resultados.

## Reiniciar y detener conservando datos

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Restart
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Test
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Stop
# Reanudar y validar:
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Start
```

También se puede usar `docker compose stop` y `docker compose up -d --wait`. `docker compose down` retira contenedores/red pero conserva volúmenes; no usar `down -v`, `volume prune` ni borrar `.secrets/` para una operación ordinaria. El proyecto no realiza esas operaciones. Nunca promover regional-db para resolver un fallo de arranque: cambiaría la topología requerida.

## Problemas encontrados y soluciones

1. Puerto 5432 ocupado por una instalación ajena: asignado 15432 solo al primario del laboratorio.
2. PowerShell 5.1 interpreta mensajes normales de progreso de Docker en stderr como errores: el envoltorio recoge ambos canales y decide por código de salida.
3. Lectura de ExitCode con Start-Process no fue fiable en el controlador inicial: se cambió a System.Diagnostics.Process y WaitForExit; la suscripción se había creado correctamente y no se duplicó.
4. Healthcheck iniciado como root chocaba con peer: se ejecuta `gosu postgres pg_isready`.
5. En la primera ejecución del verificador, una variable local ocultaba el ID guardado y produjo un falso fallo de espera aunque el dato sí se había replicado: se corrigió el ámbito de la variable y se repitió la batería. Los reportes fallidos se conservan como historial real.
6. Si un slot tarda en crearse con primario inactivo, se emiten snapshots WAL desde central. No se cambia el origen de la suscripción.

Los logs de reinicio pueden mostrar cierre de conexiones, reconexiones o `the database system is shutting down`; K genera deliberadamente un error de escritura de solo lectura. En la última ejecución se observó también un `Connection refused` del apply worker mientras regional todavía arrancaba: PostgreSQL reconectó automáticamente, el UPDATE y DELETE posteriores se replicaron y los contadores apply/sync permanecieron en cero. Se debe distinguir esas entradas transitorias de errores persistentes. Consultar `RESULTADOS.md`, `evidencias/revision-final.txt` y `EVIDENCIAS.md`.

## Referencias técnicas oficiales

* [Decodificación en standby y snapshots WAL](https://www.postgresql.org/docs/18/logicaldecoding-explanation.html)
* [Parámetros de replicación](https://www.postgresql.org/docs/18/runtime-config-replication.html)
* [Seguridad de replicación lógica](https://www.postgresql.org/docs/18/logical-replication-security.html)
* [CREATE SUBSCRIPTION](https://www.postgresql.org/docs/18/sql-createsubscription.html)
* [pg_basebackup](https://www.postgresql.org/docs/18/app-pgbasebackup.html)
* [Vista de slots: restricciones de synced en hot standby](https://www.postgresql.org/docs/18/view-pg-replication-slots.html)

## Archivos

`compose.yaml`, `.env.example`, `.gitignore`, `lab.ps1`; `config/` para parámetros y HBA por nodo; `sql/` para modelo y semillas; `scripts/` para inicialización, basebackup y suscripción; `evidencias/` para resultados reales, estados y logs. Las evidencias se conservan localmente e ignoran por defecto en Git para evitar publicar información operativa sin revisión. No se han realizado commits ni push.
