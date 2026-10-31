# Guía de evidencias — LogiTrans S.A.

Los TXT dentro de `evidencias/` proceden de ejecuciones reales. Las capturas indicadas aquí deben tomarse de la terminal al ejecutar estos comandos; no se incluyen imágenes simuladas ni se afirma haber tomado capturas gráficas. Los TXT permiten revisar resultados sin depender de imágenes.

Ubicarse en la carpeta del laboratorio:

```powershell
Set-Location C:\Users\Justin\Desktop\Lab_Bases\logitrans-postgres
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Test
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Status
```

El archivo `tests-FECHA-HORA.txt` muestra PASS/FAIL por comprobación, ID y UUID. Los estados y logs tienen la misma marca temporal. Las fechas del nombre de archivo son hora local de Costa Rica; las fechas de Docker/PostgreSQL en los logs se expresan en UTC.

## 1. Configuración completa de replicación física

```powershell
docker compose ps
Get-Content .\scripts\standby.sh
docker compose exec -T -u postgres central-db psql -d logitrans -c "SELECT pg_is_in_recovery(); SELECT application_name,client_addr,state,flush_lsn,replay_lsn FROM pg_stat_replication; SELECT slot_name,slot_type,active FROM pg_replication_slots;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SELECT pg_is_in_recovery(); SHOW primary_slot_name; SELECT status,sender_host,slot_name,flushed_lsn FROM pg_stat_wal_receiver;"
docker compose exec -T -u postgres regional-db bash -c 'test -f "$PGDATA/standby.signal" && echo standby.signal=present'
```

Captura: tres servicios healthy, primario false, standby true, slot físico activo, sender streaming y receiver desde central-db. Mostrar `pg_basebackup -R` en el script y `standby.signal=present`. Archivos de soporte: `containers-*`, `state-central-db-*`, `state-regional-db-*`, pruebas A/B/C/K.

## 2. Configuración y funcionamiento de replicación lógica

```powershell
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SELECT * FROM pg_publication_tables; SELECT s.slot_name,s.slot_type,s.plugin,s.synced,r.application_name,r.client_addr,r.state FROM pg_replication_slots s JOIN pg_stat_replication r ON r.pid=s.active_pid;"
docker compose exec -T -u postgres bi-db psql -d logitrans -c "SELECT subname,subenabled,subslotname,subpublications,split_part(subconninfo,' password=',1) AS safe_endpoint FROM pg_subscription; SELECT srrelid::regclass,srsubstate FROM pg_subscription_rel; SELECT subname,worker_type,pid,received_lsn FROM pg_stat_subscription; SELECT * FROM pg_stat_subscription_stats;"
docker compose exec -T -u postgres central-db psql -d logitrans -c "SELECT slot_name,slot_type FROM pg_replication_slots;"
```

Captura: publicación solo public.empleados, slot lógico local en regional con pgoutput, synced=false, cliente BI 172.30.84.4, conninfo regional-db, estado de tabla r, apply activo y errores cero. Central solo tiene slot físico. Archivos: `state-regional-db-*`, `state-bi-db-*`, prueba I y FINAL. No mostrar el conninfo completo.

## 3. Roles y parámetros de seguridad

```powershell
Get-Content .\config\*.hba
docker compose exec -T -u postgres central-db psql -d logitrans -c "SELECT rolname,rolcanlogin,rolreplication,rolsuper,rolcreatedb,rolcreaterole,rolbypassrls,rolpassword LIKE 'SCRAM-SHA-256$%' AS scram FROM pg_authid WHERE rolname IN ('repl_fisica','repl_logica'); SELECT has_table_privilege('repl_logica','empleados','SELECT') AS lee_empleados,has_table_privilege('repl_logica','entregas','SELECT') AS lee_entregas; SHOW password_encryption; SHOW wal_level; SHOW max_wal_senders; SHOW max_replication_slots;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "SHOW hot_standby_feedback; SHOW transaction_read_only; SELECT * FROM pg_hba_file_rules;"
```

Captura: atributos limitados, SCRAM true sin exponer hashes, permisos SELECT separados, HBA /32, parámetros y readonly. Soporte: prueba J/K y estados. Las entradas de autenticación de los logs prueban el método SCRAM usado por cada replicador.

## 4. Datos replicados y separación BI

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Test
docker compose exec -T -u postgres central-db psql -d logitrans -c "TABLE empleados; TABLE entregas;"
docker compose exec -T -u postgres regional-db psql -d logitrans -c "TABLE empleados; TABLE entregas;"
docker compose exec -T -u postgres bi-db psql -d logitrans -c "TABLE empleados; SELECT to_regclass('public.entregas') IS NULL AS entregas_ausente;"
Get-ChildItem .\evidencias\tests-*.txt | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content
```

Captura: PASS D/E/F/G/H/L, ID y UUID, y datos iniciales idénticos. La prueba compara cada valor concreto del empleado insertado y modificado y cada campo de la entrega, y verifica ausencia del ID tras DELETE. El empleado temporal ya se eliminó cuando termina la batería; el reporte refleja esas verificaciones. La prueba L conserva temporalmente el empleado y la entrega durante el reinicio, comprueba sus valores y ejecuta otra actualización después.

## 5. Documentación y reproducibilidad

```powershell
Get-ChildItem -Recurse -File | Where-Object FullName -notmatch '\.secrets\\'
Get-Content .\README.md
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Stop
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Start
```

Captura: estructura de archivos, servicios retomados y batería PASS después de reanudar. `Start` vuelve a usar los volúmenes, credenciales y suscripción existentes, sin duplicar semillas. No mostrar el contenido de `.secrets/`. No ejecutar `down -v` para esta demostración.

## Cómo interpretar el historial

No descartar reportes FAIL: describen intentos reales y deben leerse con los posteriores. El README documenta las correcciones. Para la evaluación utilizar la ejecución completa más reciente junto con sus tres estados y logs; verificar que no haya FAIL, que el contador final sea cero y que no existan errores persistentes de apply/sync. `Status` captura estado pero no reemplaza las pruebas de mutación y reinicio.
