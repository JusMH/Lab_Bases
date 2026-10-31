# Informe de validación técnica

## Alcance y entorno de ejecución

Las pruebas del 30 de octubre de 2026 validaron la disponibilidad, la seguridad y la transmisión de datos en el laboratorio LogiTrans. Las dos ejecuciones finales aprobaron las pruebas A–L y la comprobación final de salud. Este informe analiza los registros conservados de esas ejecuciones.

| Elemento | Entorno registrado |
|---|---|
| PostgreSQL | 18.6, paquete Debian 18.6-1.pgdg12+2, idéntico en los tres nodos |
| Contenedores | Linux x86_64 sobre Docker Desktop 4.86.0 en Windows |
| Docker Engine / Compose | 29.7.2 / v5.3.1 |
| Servicios y puertos del host | central-db:15432, regional-db:5433 y bi-db:5434 |
| Red Docker | 172.30.84.0/24; puerto interno 5432 en todos los servicios |
| Hora de los reportes | Costa Rica, UTC−06:00; logs de Docker/PostgreSQL en UTC |

Fuentes: [entorno.txt](evidencias/entorno.txt), [estado de los contenedores](evidencias/containers-20261030-180630.txt) y [reporte final de pruebas](evidencias/tests-20261030-180630.txt).

## Metodología de verificación

La batería de [lab.ps1](lab.ps1) ejecuta consultas con `psql` dentro de los contenedores. Para operaciones asíncronas consulta las condiciones hasta obtener el resultado esperado o alcanzar un plazo definido; las consultas tienen un límite de 15 segundos. Cada comprobación registra PASS o FAIL y el proceso finaliza con error cuando existen fallos.

Las pruebas de datos usan el ID devuelto por INSERT y un marcador UUID en el nombre del empleado y el destino de la entrega. Comparan valores concretos en los destinos y comprueban la ausencia del ID después de DELETE. La entrega se valida antes de eliminar al empleado, respetando la clave foránea. La prueba D comprueba además los valores del empleado inicial con ID 1; los estados exportados contienen los cuatro empleados iniciales.

La prueba I combina la configuración de la suscripción con la conexión activa observada en regional-db y su slot lógico. La comprobación final exige un proceso de aplicación activo con LSN recibido, contadores de errores de aplicación y sincronización en cero, enlace físico en streaming y ausencia de `entregas` en BI.

| Registro de ejecución | Finalización local | Resultado |
|---|---|---|
| [tests-20261030-180247.txt](evidencias/tests-20261030-180247.txt) | 18:04:35 | Cinco fallos: D, E, G, L y F; incidencia del verificador |
| [tests-20261030-180511.txt](evidencias/tests-20261030-180511.txt) | 18:05:41 | A–L y FINAL aprobadas; failures=0 |
| [tests-20261030-180630.txt](evidencias/tests-20261030-180630.txt) | 18:07:00 | A–L y FINAL aprobadas; failures=0; valores comparados detallados |

La marca del nombre de cada archivo corresponde al inicio de la batería. Los tiempos de finalización proceden de la última línea del reporte.

## Pruebas ejecutadas

La siguiente tabla corresponde a la última batería completa, [tests-20261030-180630.txt](evidencias/tests-20261030-180630.txt). Su interpretación se contrasta con las condiciones implementadas en `lab.ps1` y con los estados de cada nodo.

| Prueba | Verificación y resultado observado | Estado |
|---|---|---|
| A | Los tres nodos respondieron y reportaron PostgreSQL 18.6 con la misma versión de paquete | PASS |
| B | pg_is_in_recovery(): false en central-db y true en regional-db | PASS |
| C | Emisor físico en streaming hacia regional-db; receptor WAL desde central-db con regional_physical y LSN de recepción | PASS |
| D | Empleado inicial ID 1 con valores esperados; empleado ID 7 insertado y localizado en regional y BI con salario 1234.56 | PASS |
| E | Empleado ID 7 actualizado a departamento Validado y salario 9876.54 en ambos destinos | PASS |
| F | Después del reinicio, empleado ID 7 eliminado y ausente en los tres nodos; entrega de prueba ausente en regional | PASS |
| G | Entrega ID 5 localizada en regional con fecha 2026-10-30, destino UUID e id_empleado=7 | PASS |
| H | public.entregas no existe en BI | PASS |
| I | Publicación limitada a public.empleados; suscripción dirigida a regional-db; slot lógico local activo con cliente BI; sin slots lógicos en central | PASS |
| J | Roles restringidos, verificadores SCRAM, permisos comprobados, HBA válido y parámetros requeridos | PASS |
| K | Regional con transaction_read_only=on; CREATE TABLE rechazado por solo lectura y tabla de prueba inexistente | PASS |
| L | Reinicio de los tres contenedores, persistencia de los registros y nueva actualización a salario 9999.99 recibida en regional y BI | PASS |
| FINAL | Proceso de aplicación activo, contadores apply/sync en cero, regional en recuperación y enlace físico restaurado | PASS |

## Resultados observados

El empleado de la última prueba utilizó el marcador `TEST_82dfc0845f7542218e16389bdfd96ccf`. El reporte registra en ambos destinos la secuencia de valores `Pruebas / 1234.56`, `Validado / 9876.54` y, después del reinicio, `Validado / 9999.99`. También registra su ausencia en los tres nodos tras la eliminación.

Los estados finales muestran `regional_physical` activo en central-db y `bi_empleados` activo en regional-db, con plugin `pgoutput` y `synced=false`. La conexión lógica observada en regional tiene aplicación `bi-empleados`, cliente `172.30.84.4` y estado `streaming`. BI conserva `sub_empleados` habilitada con origen `host=regional-db port=5432`. Estas observaciones respaldan el origen lógico en el standby.

Los cuatro empleados iniciales aparecen en los tres [estados exportados](EVIDENCIAS.md#relación-de-archivos). La captura de datos del [informe PDF](Evidencia_Uso_Lab.pdf), evidencia 4, página 4, muestra además las tres entregas iniciales en central y regional y el resultado verdadero de `entregas_ausente` en BI. La publicación contiene exclusivamente `public.empleados`.

## Comprobaciones de seguridad

La prueba J verificó LOGIN y REPLICATION en los dos roles, ausencia de SUPERUSER, CREATEDB, CREATEROLE y BYPASSRLS, y formato SCRAM de sus verificadores de contraseña. Comprobó SELECT sobre `empleados` para `repl_logica`, ausencia de SELECT sobre `entregas`, de INSERT sobre `empleados` y de CREATE sobre `public`. La definición de permisos de [sql/central.sql](sql/central.sql) complementa estas comprobaciones.

Las reglas HBA exportadas autorizan únicamente el enlace físico desde `172.30.84.3/32` y el lógico desde `172.30.84.4/32`, con SCRAM-SHA-256; el administrador local usa `peer`. La prueba J no detectó reglas inválidas ni métodos `trust` o `md5`. Los parámetros de WAL y slots cumplieron los valores requeridos, y regional mantuvo `hot_standby_feedback=on` y `primary_slot_name=regional_physical`.

Los registros de estado presentan atributos y resultados de consultas sin contraseñas ni verificadores. [revision-final.txt](evidencias/revision-final.txt) registra cero errores de configuración en `pg_file_settings` para los tres nodos. Estas comprobaciones no constituyen una auditoría integral de seguridad; el alcance corresponde a los controles del laboratorio.

## Persistencia después del reinicio

La prueba L ejecutó `docker compose restart` sin eliminar volúmenes. Después de recuperar la disponibilidad, verificó los valores del empleado ID 7 en regional y BI y la entrega ID 5 en central y regional. Una nueva actualización del salario a 9999.99 llegó a ambos destinos. Posteriormente, F comprobó la eliminación replicada y FINAL verificó la recuperación de los dos enlaces.

El estado de los contenedores exportado tras la batería registra los tres servicios como `healthy`. [revision-final.txt](evidencias/revision-final.txt) muestra el mismo identificador del sistema para central/regional y otro distinto para BI, coherente con una copia física y un clúster suscriptor independiente.

## Incidencias técnicas relevantes

| Incidencia | Evidencia e interpretación | Resolución o comportamiento observado |
|---|---|---|
| Puerto 5432 del host ocupado | entorno.txt identifica un proceso postgres con PID 7852 | Se asignó 15432 al primario; las conexiones internas conservan 5432 |
| Consulta del empleado ID 0 en el primer intento | tests-20261030-180247.txt registra el timeout de D y fallos posteriores por prerrequisitos | Se corrigió el ámbito de la variable del ID en el verificador; las dos baterías posteriores aprobaron |
| Registro temporal del intento inicial | [limpieza-intento-inicial.txt](evidencias/limpieza-intento-inicial.txt) muestra el empleado ID 5 y DELETE 1 | Se retiró el registro residual; el archivo conserva el resultado de la eliminación |
| Escritura rechazada en regional | Logs de regional: cannot execute CREATE TABLE in a read-only transaction | Resultado esperado de K; confirma el modo de solo lectura |
| Interrupciones durante el reinicio | revision-final.txt y logs muestran cierres administrativos y un Connection refused del proceso de aplicación | La conexión se restableció; el UPDATE y DELETE posteriores aprobaron y los contadores finales permanecieron en cero |

La presencia de mensajes ERROR o FATAL en esos momentos no equivale a un fallo persistente de replicación. La interpretación se apoya en su contexto y en las comprobaciones de datos y salud posteriores. Los registros históricos se mantienen separados de los resultados finales aprobados.

## Conclusión

Los registros disponibles respaldan el cumplimiento de las pruebas A–L y la comprobación final en dos ejecuciones completas. La validación demuestra replicación física hacia un standby de solo lectura, emisión lógica desde ese standby exclusivamente para `empleados` y continuidad de las operaciones después del reinicio. Las limitaciones de asincronía, cifrado, secuencias y failover se detallan en [README.md](README.md).
