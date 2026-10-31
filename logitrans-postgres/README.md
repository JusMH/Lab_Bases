# Laboratorio PostgreSQL LogiTrans S.A.

## Descripción y objetivo

Este laboratorio implementa una arquitectura de tres nodos PostgreSQL 18.6 para estudiar la combinación de replicación física y lógica. El objetivo es mantener una réplica completa del clúster operativo y distribuir exclusivamente los datos de empleados a una instancia de análisis, mediante una suscripción cuyo origen es el standby físico.

La solución utiliza Docker Compose, PowerShell, Bash y SQL. Los resultados de las pruebas se presentan en [RESULTADOS.md](RESULTADOS.md), y la relación de registros y capturas disponibles se encuentra en [EVIDENCIAS.md](EVIDENCIAS.md).

## Arquitectura

```text
central-db -- replicación física --> regional-db -- replicación lógica --> bi-db
```

| Nodo | Función | Puerto del host Windows | Puerto interno | Dirección en Docker | Tablas de logitrans |
|---|---|---|---|---|---|
| central-db | Primario | 15432 | 5432 | 172.30.84.2 | empleados y entregas |
| regional-db | Standby físico y emisor lógico | 5433 | 5432 | 172.30.84.3 | empleados y entregas |
| bi-db | Suscriptor lógico de BI | 5434 | 5432 | 172.30.84.4 | empleados |

Los servicios pertenecen a la red `172.30.84.0/24` y tienen volúmenes independientes. El puerto 5432 del host estaba ocupado por una instalación PostgreSQL existente, según [entorno.txt](evidencias/entorno.txt); por ello, el primario se publica en 15432. Esta asignación afecta únicamente al acceso desde Windows: las conexiones entre contenedores usan los nombres de servicio y el puerto interno 5432.

Los puertos se publican en `127.0.0.1`. Las reglas HBA rechazan las conexiones TCP administrativas; las consultas de administración se ejecutan dentro de cada contenedor, como usuario del sistema `postgres`, mediante socket Unix y autenticación `peer`.

## Modelo de datos

La base `logitrans` contiene las siguientes tablas en central-db y regional-db:

```sql
CREATE TABLE empleados (
    id_empleado SERIAL PRIMARY KEY,
    nombre TEXT NOT NULL,
    departamento TEXT,
    salario NUMERIC
);

CREATE TABLE entregas (
    id_entrega SERIAL PRIMARY KEY,
    fecha DATE,
    destino TEXT,
    id_empleado INT REFERENCES empleados(id_empleado)
);
```

[sql/central.sql](sql/central.sql) inicializa cuatro empleados y tres entregas. En BI, [sql/bi.sql](sql/bi.sql) crea únicamente `empleados`, con la misma estructura. La clave primaria proporciona la identidad de réplica necesaria para UPDATE y DELETE.

## Replicación física

El primario utiliza `wal_level=logical`, `max_wal_senders=10` y `max_replication_slots=10`. El nivel lógico de WAL es necesario para la decodificación posterior en el standby. La configuración compartida se encuentra en [config/postgresql.conf](config/postgresql.conf).

El rol `repl_fisica` tiene los atributos LOGIN y REPLICATION. [config/central.hba](config/central.hba) autoriza el protocolo de replicación física únicamente desde `172.30.84.3/32`, con SCRAM-SHA-256. El slot físico `regional_physical` se crea en central-db con reserva inicial de WAL.

[scripts/standby.sh](scripts/standby.sh) inicializa regional-db mediante el siguiente comando, dentro del contenedor:

```sh
pg_basebackup \
  --dbname='host=central-db user=repl_fisica application_name=regional-db passfile=/var/lib/postgresql/physical.pgpass' \
  -D "$PGDATA" -R -X stream -S regional_physical --checkpoint=fast --no-password
```

La opción `-R` genera `standby.signal` y añade `primary_conninfo` y `primary_slot_name` a `postgresql.auto.conf`. La contraseña se obtiene de un archivo de autenticación con permisos 0600. El directorio de datos es `/var/lib/postgresql/18/docker`, dentro del volumen montado en `/var/lib/postgresql`.

La copia base se realiza únicamente sobre un directorio vacío sin `PG_VERSION`. Un directorio parcialmente inicializado requiere revisión manual. En los arranques siguientes se reutiliza el volumen y se exige la presencia de `standby.signal`, manteniendo la función de standby.

## Replicación lógica desde el standby

La publicación `pub_empleados` se define en **central-db** mediante `CREATE PUBLICATION pub_empleados FOR TABLE public.empleados`. La replicación física lleva su definición y los datos hasta regional-db. Esta ubicación del DDL responde al carácter de solo lectura del standby; regional-db es el servidor que decodifica y transmite los cambios al suscriptor.

[scripts/subscribe.sh](scripts/subscribe.sh) crea en bi-db la suscripción `sub_empleados`, con `host=regional-db port=5432 dbname=logitrans user=repl_logica`, `copy_data=true`, slot `bi_empleados` y `failover=false`. La copia inicial incluye los registros existentes. Los cambios posteriores de `empleados` se transmiten mediante `pgoutput`; `entregas` queda fuera de la publicación y del esquema de BI.

En PostgreSQL 18 es posible crear un slot lógico local en un standby. Regional-db utiliza `hot_standby_feedback=on` y el slot físico del enlace ascendente para proteger los catálogos necesarios para decodificar. Si el primario está inactivo, la creación del slot puede esperar información sobre las transacciones; el controlador emite `pg_log_standby_snapshot()` en central-db durante la creación y sincronización inicial. Estas condiciones se describen en la [documentación de decodificación lógica](https://www.postgresql.org/docs/18/logicaldecoding-explanation.html).

`sync_replication_slots` no se habilita: sincroniza slots de failover procedentes del primario y no es necesario para el slot local de este laboratorio. Los slots con `synced=true` no pueden utilizarse para decodificación mientras el nodo está en recuperación, según la [vista pg_replication_slots](https://www.postgresql.org/docs/18/view-pg-replication-slots.html).

El origen efectivo se verifica relacionando el slot activo de regional-db con `pg_stat_replication`, la dirección de BI `172.30.84.4` y la aplicación `bi-empleados`. También se comprueba la conexión de la suscripción y la ausencia de slots lógicos en central-db.

## Configuración y seguridad

| Componente | Configuración |
|---|---|
| Rol físico | repl_fisica: LOGIN y REPLICATION; acceso físico desde regional-db |
| Rol lógico | repl_logica: LOGIN y REPLICATION; CONNECT a logitrans, USAGE en public y SELECT sobre empleados |
| Privilegios restringidos | Ambos roles sin SUPERUSER, CREATEDB, CREATEROLE ni BYPASSRLS; repl_logica sin permisos DML ni SELECT sobre entregas |
| Acceso lógico | [config/regional.hba](config/regional.hba): logitrans, repl_logica, origen 172.30.84.4/32 y SCRAM-SHA-256 |
| Administración | Usuario postgres local con peer; propietario de la suscripción en BI |
| Acceso restante | Rechazo TCP en los tres nodos; sin reglas trust ni MD5 |
| Privilegios de PUBLIC | Se revocan CONNECT y TEMPORARY sobre logitrans y CREATE sobre public |

El arranque genera tres credenciales aleatorias independientes de 256 bits en `.secrets/`, si no existen, y restringe la ACL de Windows al usuario actual y SYSTEM. Docker las monta como archivos. `.env` y `.secrets/` están excluidos de Git; deben conservarse con los volúmenes, ya que regenerar archivos de credenciales no cambia las contraseñas de un clúster inicializado.

La contraseña de la conexión lógica se almacena en el catálogo de suscripciones. Las consultas documentadas muestran solo el tramo del conninfo anterior a `password`, conforme al formato construido por el script, y omiten los verificadores de contraseña.

## Requisitos

Se requiere Windows con PowerShell 5.1 o posterior, Docker Desktop con motor Linux, Docker Compose con soporte para `up --wait --wait-timeout` y acceso a Docker Hub. `psql` se ejecuta en los contenedores; no es necesario instalar PostgreSQL, Python ni paquetes adicionales en Windows. Las versiones utilizadas constan en [entorno.txt](evidencias/entorno.txt).

La máquina debe disponer de memoria y almacenamiento para tres clústeres y sus registros WAL. Antes del primer arranque, los puertos 15432, 5433 y 5434 deben estar libres, el nombre de proyecto `logitrans_lab` debe estar disponible y la red `172.30.84.0/24` no debe solaparse con otras redes de Docker o del host. Las IP estáticas, las reglas HBA y las verificaciones están coordinadas; cambiar únicamente `LAB_SUBNET` no constituye una adaptación válida de la red.

## Instalación y ejecución

Los siguientes comandos se ejecutan desde PowerShell. La ruta corresponde a la ubicación del proyecto en el entorno documentado; en otra máquina debe sustituirse por la carpeta de la copia local.

```powershell
Set-Location C:\Users\Justin\Desktop\Lab_Bases\logitrans-postgres
docker version
docker compose version
Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 15432,5433,5434
docker network ls
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Start
```

`Start` copia [.env.example](.env.example) si falta `.env`, prepara las credenciales, levanta los servicios y espera su disponibilidad. El archivo de ejemplo fija la imagen por digest. La suscripción solo se crea si no existe. A continuación se ejecuta la batería completa, **incluido el reinicio de los tres contenedores**.

Los scripts SQL de inicialización se aplican únicamente al crear volúmenes vacíos. Los arranques ordinarios reutilizan los datos y no duplican las semillas. Las comprobaciones asíncronas utilizan sondeo de 500 ms, plazos de 90 segundos por defecto y consultas con `statement_timeout=15000`. La creación de la suscripción y la espera de sincronización inicial tienen límites de 120 segundos por fase; Compose dispone de un límite de disponibilidad de 180 segundos.

| Acción de lab.ps1 | Comportamiento |
|---|---|
| Start | Preparar, iniciar y ejecutar todas las pruebas |
| Test | Ejecutar las pruebas sobre los servicios existentes; incluye escrituras de prueba y reinicio |
| Status | Consultar los contenedores y exportar estados y logs |
| Restart | Reiniciar los contenedores y esperar disponibilidad |
| Stop | Detener los servicios conservando los volúmenes |

Para repetir las pruebas y consultar su reporte:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Test
Get-ChildItem .\evidencias\tests-*.txt | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Encoding UTF8
```

## Consultas de verificación

Estas consultas son de lectura y permiten revisar disponibilidad, flujo de WAL, publicación, suscripción y separación de tablas:

```powershell
docker compose ps
docker compose exec -T -u postgres central-db psql -d logitrans -c "SELECT pg_is_in_recovery(); SELECT application_name,client_addr,state,flush_lsn,replay_lsn FROM pg_stat_replication;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SELECT pg_is_in_recovery(); SELECT status,sender_host,slot_name,flushed_lsn FROM pg_stat_wal_receiver;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SELECT * FROM pg_publication_tables; SELECT slot_name,slot_type,plugin,active,synced,invalidation_reason FROM pg_replication_slots; SELECT application_name,client_addr,state FROM pg_stat_replication;"
docker compose exec -T -u postgres bi-db psql -d logitrans -c "SELECT subname,subenabled,subslotname,subpublications,split_part(subconninfo,' password=',1) AS origen FROM pg_subscription; SELECT subname,apply_error_count,sync_error_count FROM pg_stat_subscription_stats;"
docker compose exec -T -u postgres bi-db psql -d logitrans -c "TABLE empleados; SELECT to_regclass('public.entregas') IS NULL AS entregas_ausente;"
docker compose logs --tail 80 central-db regional-db bi-db
```

## Resultados generales

Las ejecuciones conservadas del 30 de octubre de 2026 a las 18:05 y 18:06 aprobaron las pruebas A–L y la comprobación final. La última concluyó a las 18:07:00, hora de Costa Rica, con `failures=0`. Verificó INSERT, UPDATE y DELETE mediante un identificador y un marcador únicos, la separación de tablas y la continuidad de la replicación después del reinicio. El detalle se encuentra en [RESULTADOS.md](RESULTADOS.md) y en el [reporte final de pruebas](evidencias/tests-20261030-180630.txt).

Cada comprobación registra PASS o FAIL; la batería devuelve error si falla alguna. El intento inicial y sus cinco fallos se conservan como antecedente de una incidencia del verificador, descrita en el informe de resultados. Las evidencias representan el estado observado durante esas ejecuciones.

## Reinicio y parada

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Restart
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Stop
# Reanudar y validar el laboratorio:
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Start
```

`Restart` y `Stop` conservan los volúmenes. `docker compose down` también conserva los volúmenes nombrados si se ejecuta sin `-v`; la opción `-v` elimina esos datos. Las credenciales existentes deben mantenerse para los arranques siguientes. Durante un reinicio pueden aparecer cierres administrativos y rechazos transitorios de conexión hasta que el emisor esté disponible.

## Limitaciones técnicas

La replicación es asíncrona y no ofrece una garantía de pérdida cero ante fallos del primario. No se implementan promoción ni failover automático. La autenticación utiliza SCRAM-SHA-256 en una red Docker local, sin TLS; el tráfico de replicación no está cifrado.

La replicación lógica no sincroniza DDL ni secuencias. BI se utiliza para consultas; su secuencia SERIAL no sigue el valor del primario. Los cambios futuros de esquema requieren coordinación entre emisor y suscriptor.

`max_slot_wal_keep_size=1GB` limita el WAL retenido por slots al evaluarse los checkpoints; no representa un límite total de uso de disco. Una interrupción prolongada puede invalidar un slot. `hot_standby_feedback` protege información necesaria para decodificar, pero puede aumentar la acumulación de versiones de filas en el primario. El almacenamiento y los retrasos requieren supervisión.

Las pruebas eliminan sus registros temporales por ID y marcador. Un fallo parcial puede dejar registros `TEST_`; las secuencias avanzan entre ejecuciones. Las semillas no se vuelven a cargar sobre un volumen existente.

## Organización de la entrega

| Ruta | Contenido |
|---|---|
| [compose.yaml](compose.yaml) y [.env.example](.env.example) | Servicios, imagen, red, puertos, volúmenes y variables |
| [lab.ps1](lab.ps1) | Arranque, pruebas, consultas y recopilación de registros |
| config/ | Parámetros de PostgreSQL y HBA por nodo |
| sql/ | Esquema, datos iniciales, roles y publicación |
| scripts/ | Inicialización del primario, copia base y suscripción |
| evidencias/ | Reportes de pruebas, estados y logs de ejecución |
| [RESULTADOS.md](RESULTADOS.md) y [EVIDENCIAS.md](EVIDENCIAS.md) | Informe de validación e índice de respaldo |
| [Evidencia_Uso_Lab.pdf](Evidencia_Uso_Lab.pdf) y [Evidencia_Uso_Lab.docx](Evidencia_Uso_Lab.docx) | Informe ilustrado y fuente editable |

Los TXT de `evidencias/` están excluidos de Git por la configuración del proyecto, aunque forman parte de la entrega local. Una copia del repositorio por sí sola puede no contener los registros históricos; los comandos anteriores permiten generar nuevos reportes.

## Referencias oficiales

* PostgreSQL 18. [Decodificación lógica, slots en standby y snapshots WAL](https://www.postgresql.org/docs/18/logicaldecoding-explanation.html).
* PostgreSQL 18. [pg_basebackup y preparación del standby](https://www.postgresql.org/docs/18/app-pgbasebackup.html).
* PostgreSQL 18. [Parámetros de replicación](https://www.postgresql.org/docs/18/runtime-config-replication.html).
* PostgreSQL 18. [Seguridad de la replicación lógica](https://www.postgresql.org/docs/18/logical-replication-security.html).
* PostgreSQL 18. [CREATE SUBSCRIPTION](https://www.postgresql.org/docs/18/sql-createsubscription.html).
* PostgreSQL 18. [Vista pg_replication_slots](https://www.postgresql.org/docs/18/view-pg-replication-slots.html).
