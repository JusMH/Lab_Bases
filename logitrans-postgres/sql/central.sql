CREATE ROLE repl_fisica LOGIN REPLICATION PASSWORD :'physical';
CREATE ROLE repl_logica LOGIN REPLICATION PASSWORD :'logical';
REVOKE CONNECT, TEMPORARY ON DATABASE logitrans FROM PUBLIC;
GRANT CONNECT ON DATABASE logitrans TO repl_logica;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE TABLE empleados (
 id_empleado SERIAL PRIMARY KEY, nombre TEXT NOT NULL,
 departamento TEXT, salario NUMERIC
);
CREATE TABLE entregas (
 id_entrega SERIAL PRIMARY KEY, fecha DATE, destino TEXT,
 id_empleado INT REFERENCES empleados(id_empleado)
);
GRANT USAGE ON SCHEMA public TO repl_logica;
GRANT SELECT ON empleados TO repl_logica;
INSERT INTO empleados(nombre,departamento,salario) VALUES
 ('Ana Mora','Operaciones',1250000),('Luis Vega','Transporte',950000),
 ('Sofia Solano','Finanzas',1450000),('Carlos Rojas','Bodega',780000);
INSERT INTO entregas(fecha,destino,id_empleado) VALUES
 ('2026-10-28','San Jose',1),('2026-10-29','Limon',2),('2026-10-30','Alajuela',1);
CREATE PUBLICATION pub_empleados FOR TABLE public.empleados;
SELECT pg_create_physical_replication_slot('regional_physical', true);
