# Resultado ejecutado — 30 de octubre de 2026

**Estado: funcional.** Tres contenedores activos y healthy. PostgreSQL 18.6 idéntico en todos. Topología comprobada: central-db → réplica física → regional-db → réplica lógica → bi-db. Última batería completada a las 18:07:00, hora de Costa Rica (UTC−06:00), con cero comprobaciones fallidas.

Evidencia principal: `evidencias/tests-20261030-180630.txt`. Se conserva otra batería completa aprobada (`180511`) y el primer intento fallido (`180247`), cuyo verificador consultaba incorrectamente ID 0. No se ocultaron los fallos. Se corrigió el ámbito de la variable y se ejecutaron dos baterías completas posteriores. El registro propio de prueba que quedó del primer intento se eliminó por su ID y UUID exactos; el comando y resultado están en `evidencias/limpieza-intento-inicial.txt`.

| Prueba | Resultado real |
|---|---|
| A | PASS: tres versiones PostgreSQL 18.6 iguales y disponibles |
| B | PASS: central false y regional true en pg_is_in_recovery() |
| C | PASS: sender físico streaming; regional recibe WAL desde central con regional_physical |
| D | PASS: datos iniciales presentes y empleado ID 7 con UUID y salario 1234.56 en ambos destinos |
| E | PASS: departamento Validado y salario 9876.54 en ambos destinos |
| F | PASS: empleado de prueba eliminado en los tres nodos después del reinicio |
| G | PASS: entrega ID 5 con fecha, destino UUID e ID de empleado exactos en regional |
| H | PASS: public.entregas no existe en BI |
| I | PASS: publicación solo empleados; conexión y slot lógico realmente en regional |
| J | PASS: roles mínimos, contraseñas SCRAM, privilegios, HBA restringido y parámetros |
| K | PASS: regional readonly y CREATE TABLE rechazado realmente |
| L | PASS: reinicio sin borrar volúmenes, datos conservados, UPDATE nuevo a 9999.99 replicado |
| FINAL | PASS: apply worker activo, apply_error_count=0, sync_error_count=0 y físico streaming |

Los registros temporales de la última prueba se eliminaron. La consulta posterior confirmó cero empleados TEST_ en BI. Se mantienen los cuatro empleados y tres entregas iniciales. Las secuencias avanzaron durante las pruebas, como corresponde.

## Evidencias y revisión final

* `entorno.txt`: versiones Docker/Compose, puertos, conflicto 5432 y digest de imagen.
* `tests-20261030-180630.txt`: valores exactos comparados, IDs y resultados PASS/FAIL.
* `containers-20261030-180630.txt`: servicios y puertos publicados.
* `state-{nodo}-20261030-180630.txt`: roles sin hashes, HBA, parámetros, slots, WAL, publicación, datos y suscripción sin contraseña.
* `log-{nodo}-20261030-180630.txt`: logs reales de los tres nodos, revisados.
* `revision-final.txt`: entradas ERROR/FATAL/PANIC revisadas, cero errores de pg_file_settings en los tres nodos y contadores de suscripción en cero.

Los logs incluyen el rechazo esperado de escritura en regional (K), terminaciones por orden administrativa durante reinicios y una conexión rechazada transitoria del apply worker mientras regional arrancaba. La reconexión se completó automáticamente; las pruebas de datos posteriores al reinicio aprobaron. No se detectaron errores persistentes de replicación. Se confirmó `standby.signal=present`. El identificador del sistema coincide en central/regional (copia física) y difiere en BI (clúster independiente).

`docker compose config --quiet` terminó correctamente. Se revisaron las credenciales generadas contra los archivos públicos del proyecto, sin encontrar ninguna contraseña fuera de `.secrets/`. La documentación incluye arranque, repetición, administración, parada y conservación de volúmenes.

## Comandos utilizados

```powershell
docker version
docker compose version
docker network inspect bridge cvexpert-brecha-cursos_default estudios_medicos_t1_datos lab_I
Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 5432,5433,5434,15432
Get-Process -Id 7852
docker pull postgres:18-bookworm
powershell -NoProfile -ExecutionPolicy Bypass -File .\lab.ps1 Start
docker compose config --quiet
docker compose ps
docker compose logs --no-color --timestamps central-db regional-db bi-db
```

`Start` ejecutó internamente inicialización, disponibilidad, suscripción, pruebas, `docker compose restart` y recopilación de evidencias. Se repitió sin duplicar semillas ni suscripción. Los comandos SQL precisos de consulta y las instrucciones de capturas están en `EVIDENCIAS.md`; los del verificador están en `lab.ps1`.

## Diferencias y limitaciones pendientes

El único cambio de puerto respecto al enunciado es central-db **15432**, porque 5432 pertenece a otro PostgreSQL de Windows que permanece intacto. Regional usa 5433 y BI 5434. La administración se realiza por socket mediante Docker; HBA rechaza accesos administrativos TCP aunque existan puertos publicados.

No quedan pruebas A–L pendientes. No se generaron capturas gráficas: se entregan evidencias de consola reales y una guía exacta para tomarlas. El laboratorio utiliza SCRAM dentro de una red Docker local, sin TLS, y replicación asíncrona. No incluye failover automático ni sincronización de secuencias en BI. Los límites de WAL y las condiciones de invalidación de slots se documentan en README. No se alteraron instalaciones ajenas ni se hicieron commits o push.
