# Evidencias del laboratorio LogiTrans

## Propósito y alcance

Este documento relaciona los registros de ejecución y las capturas existentes con los cinco criterios de evaluación del laboratorio. Los TXT contienen resultados de las pruebas y consultas, mientras que el informe ilustrado reúne capturas del funcionamiento y de la configuración. La interpretación de los resultados se desarrolla en [RESULTADOS.md](RESULTADOS.md).

El conjunto principal corresponde a la batería iniciada el 30 de octubre de 2026 a las 18:06:30 y completada a las 18:07:00, hora de Costa Rica. Los nombres de archivo usan hora local; las entradas de logs de Docker y PostgreSQL están en UTC. Las capturas del informe presentan consultas complementarias y la lectura del mismo reporte de pruebas, sin atribuirles la hora de creación de los TXT.

## Relación de archivos

| Evidencia disponible | Contenido y alcance |
|---|---|
| [entorno.txt](evidencias/entorno.txt) | Versiones Docker/Compose, puertos, proceso PostgreSQL en 5432, imagen y subred |
| [tests-20261030-180630.txt](evidencias/tests-20261030-180630.txt) | Última batería aprobada; valores comparados, IDs, resultados A–L y FINAL |
| [tests-20261030-180511.txt](evidencias/tests-20261030-180511.txt) | Batería completa anterior aprobada |
| [tests-20261030-180247.txt](evidencias/tests-20261030-180247.txt) | Intento inicial con cinco fallos del verificador |
| [containers-20261030-180630.txt](evidencias/containers-20261030-180630.txt) | Servicios healthy, imagen y asignaciones de puertos después de las pruebas |
| [state-central-db-20261030-180630.txt](evidencias/state-central-db-20261030-180630.txt) | Estado del primario, sender y slot físico, parámetros, roles, HBA, publicación y empleados |
| [state-regional-db-20261030-180630.txt](evidencias/state-regional-db-20261030-180630.txt) | Recuperación, receptor WAL, slot y conexión lógicos, publicación y empleados |
| [state-bi-db-20261030-180630.txt](evidencias/state-bi-db-20261030-180630.txt) | Empleados recibidos, suscripción sin contraseña, contadores y ausencia de entregas |
| [log-central-db-20261030-180630.txt](evidencias/log-central-db-20261030-180630.txt) | Actividad y reinicio del primario |
| [log-regional-db-20261030-180630.txt](evidencias/log-regional-db-20261030-180630.txt) | Recepción de WAL, emisión lógica y rechazo de escritura de la prueba K |
| [log-bi-db-20261030-180630.txt](evidencias/log-bi-db-20261030-180630.txt) | Actividad del proceso de aplicación y reconexión durante el reinicio |
| [revision-final.txt](evidencias/revision-final.txt) | Revisión de mensajes de error, cero errores de configuración, identificadores del sistema y contadores finales |
| [limpieza-intento-inicial.txt](evidencias/limpieza-intento-inicial.txt) | Resultado de la eliminación del registro residual del primer intento |
| [Evidencia_Uso_Lab.pdf](Evidencia_Uso_Lab.pdf) | Informe con ocho evidencias numeradas: estado, replicación, datos, seguridad, pruebas y configuración |
| [Evidencia_Uso_Lab.docx](Evidencia_Uso_Lab.docx) | Fuente editable del informe ilustrado |

También se conservan los estados, logs y listados de contenedores de las ejecuciones `20261030-180247` y `20261030-180511`. Los archivos `subscription.stdout.txt` y `subscription.stderr.txt` corresponden a la última invocación del script de suscripción y no contienen resultados sustantivos de su creación inicial.

## 1. Replicación física

**Respaldo:** estados de central y regional, reporte final de pruebas y evidencias 2 y 7 del PDF, páginas 2 y 7. La evidencia 1 de la página 2 complementa la disponibilidad de los nodos.

Las consultas registradas muestran `pg_is_in_recovery()=false` en central y `true` en regional. Central presenta la aplicación `regional-db` con cliente `172.30.84.3` en `streaming` y el slot físico `regional_physical` activo. Regional identifica `central-db` como emisor y conserva el mismo nombre de slot en su receptor WAL. Las pruebas B, C y K confirman los roles y el rechazo de escrituras.

La evidencia 7 muestra [config/postgresql.conf](config/postgresql.conf) y [scripts/standby.sh](scripts/standby.sh), incluidos `wal_level=logical`, `pg_basebackup -R -X stream -S regional_physical` y la comprobación de `standby.signal`. Esta captura documenta la configuración; el funcionamiento se respalda con las vistas y pruebas anteriores.

Comandos mostrados en el informe:

```powershell
docker compose exec -T -u postgres central-db psql -d logitrans -c "SELECT application_name,state FROM pg_stat_replication;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SELECT pg_is_in_recovery(); SELECT status,sender_host,slot_name FROM pg_stat_wal_receiver;"
Get-Content .\config\postgresql.conf
Get-Content .\scripts\standby.sh
```

## 2. Replicación lógica

**Respaldo:** estados de regional y BI, pruebas I y FINAL, y evidencias 3 y 8 del PDF, páginas 3 y 8.

La publicación `pub_empleados` contiene únicamente `public.empleados`. En regional se observa `bi_empleados` como slot lógico activo con plugin `pgoutput`, `synced=false` y conexión `bi-empleados` desde `172.30.84.4`. BI muestra `sub_empleados` habilitada, el slot esperado y `host=regional-db port=5432` como origen. Los contadores `apply_error_count` y `sync_error_count` son cero. Central solo registra el slot físico, lo que complementa la comprobación del origen lógico en regional.

La evidencia 8 muestra la publicación creada en [sql/central.sql](sql/central.sql) y la suscripción de [scripts/subscribe.sh](scripts/subscribe.sh). La definición de la publicación llega al standby por replicación física; la suscripción se conecta a ese standby.

Comandos mostrados en el informe:

```powershell
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SELECT * FROM pg_publication_tables; SELECT slot_name,slot_type,active FROM pg_replication_slots;"
docker compose exec -T -u postgres bi-db psql -d logitrans -c "SELECT subname,subenabled,subslotname,subpublications,split_part(subconninfo,' password=',1) AS origen FROM pg_subscription; SELECT subname,apply_error_count,sync_error_count FROM pg_stat_subscription_stats;"
Get-Content .\sql\central.sql
Get-Content .\scripts\subscribe.sh
```

El recorte de la conexión omite la contraseña conforme al orden de campos del script. Los mensajes de reconexión registrados durante el reinicio se analizan en [RESULTADOS.md](RESULTADOS.md#incidencias-técnicas-relevantes).

## 3. Roles y seguridad

**Respaldo:** parámetros, atributos y reglas HBA de los estados exportados; prueba J; logs de autenticación; evidencia 5 del PDF, página 5; y [revision-final.txt](evidencias/revision-final.txt).

Los roles `repl_fisica` y `repl_logica` tienen REPLICATION y carecen de SUPERUSER. La prueba J añade la comprobación de LOGIN, restricciones de atributos, verificadores SCRAM y permisos sobre tablas y esquema. Las reglas exportadas autorizan el enlace físico solo desde regional y el lógico solo desde BI, mediante direcciones /32 y SCRAM-SHA-256. Las conexiones administrativas locales utilizan `peer`.

Comandos mostrados en el informe:

```powershell
docker compose exec -T -u postgres central-db psql -d logitrans -c "SELECT rolname,rolreplication,rolsuper FROM pg_roles WHERE rolname IN ('repl_fisica','repl_logica'); SHOW password_encryption;"
Get-Content .\config\central.hba
Get-Content .\config\regional.hba
```

La configuración observada es `password_encryption=scram-sha-256`, sin reglas `trust` o `md5` ni errores HBA detectados por J. La revisión final registra cero errores en `pg_file_settings` en los tres nodos. Las evidencias muestran atributos y resultados de verificaciones, sin reproducir contraseñas ni verificadores almacenados.

## 4. Validación de datos replicados

**Respaldo:** [reporte final de pruebas](evidencias/tests-20261030-180630.txt), estados de los tres nodos y evidencia 4 del PDF, página 4.

Las capturas muestran cuatro empleados en los tres nodos, tres entregas en central y regional y `entregas_ausente=true` en BI. El reporte añade la validación de operaciones sucesivas sobre el empleado ID 7 y la entrega ID 5. El salario se comprobó en 1234.56 tras INSERT, 9876.54 tras UPDATE y 9999.99 tras una nueva actualización posterior al reinicio. El marcador UUID y los identificadores concretos vinculan cada comprobación con su registro de prueba.

F registra la ausencia del empleado eliminado en los tres nodos y comprueba la eliminación de la entrega en regional. H e I respaldan la separación de tablas. L verifica persistencia y continuidad de replicación tras el reinicio.

Comandos mostrados en el informe:

```powershell
docker compose exec -T -u postgres central-db psql -d logitrans -c "TABLE empleados; TABLE entregas;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "TABLE empleados; TABLE entregas;"
docker compose exec -T -u postgres bi-db psql -d logitrans -c "TABLE empleados; SELECT to_regclass('public.entregas') IS NULL AS entregas_ausente;"
```

## 5. Documentación y reproducibilidad

**Respaldo:** [README.md](README.md), [RESULTADOS.md](RESULTADOS.md), [compose.yaml](compose.yaml), [lab.ps1](lab.ps1), configuración y scripts; reportes de las dos baterías aprobadas; evidencia 6 del PDF, página 6. Las evidencias 7 y 8 documentan los archivos de configuración física y lógica.

Las baterías `180511` y `180630` concluyen con `failures=0`, incluidas las pruebas de reinicio. El informe muestra la lectura del reporte `180630`, con los mismos IDs, marcador y valores que el archivo local. Los volúmenes nombrados y la inicialización condicional permiten reutilizar el entorno sin volver a cargar las semillas; la comprobación L demuestra conservación de datos y nuevas operaciones replicadas.

La evidencia 6 muestra el siguiente comando:

```powershell
Get-Content .\evidencias\tests-20261030-180630.txt
```

El intento inicial con cinco fallos y el resultado de su limpieza permanecen disponibles. El informe de resultados distingue ese antecedente de las dos validaciones finales aprobadas. Los TXT están excluidos de Git por [.gitignore](.gitignore); su disponibilidad como evidencia corresponde a la entrega local.

## Reproducción de las verificaciones

Los procedimientos de esta sección permiten obtener un nuevo estado o repetir la batería. Se distinguen de los archivos históricos relacionados anteriormente.

Desde la carpeta local del laboratorio, las consultas de las secciones 1–4 permiten revisar el estado sin escribir en las tablas. El siguiente comando exporta estados y logs con una nueva marca temporal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Status
```

Para repetir A–L y FINAL sobre los servicios disponibles:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Test
Get-ChildItem .\evidencias\tests-*.txt | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Encoding UTF8
```

`Test` inserta, modifica y elimina registros temporales, y reinicia los tres contenedores conservando sus volúmenes. `Start` prepara o reanuda el entorno y ejecuta esa misma batería. Las instrucciones completas y los requisitos se encuentran en [README.md](README.md#instalación-y-ejecución).
