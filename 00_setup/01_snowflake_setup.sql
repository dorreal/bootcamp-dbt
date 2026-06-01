-- ============================================================
-- SETUP DE SNOWFLAKE PARA EL BOOTCAMP DBT
-- ============================================================
-- Ejecutar como rol ACCOUNTADMIN una sola vez por cuenta.
-- Crea: warehouse, base de datos, schemas, rol, usuario y permisos.
-- ============================================================

USE ROLE ACCOUNTADMIN;

-- 1. WAREHOUSE DEDICADO
-- XS es suficiente para los labs. Lo escalarás manualmente cuando
-- llegues al lab 10 (backfills masivos).
CREATE WAREHOUSE IF NOT EXISTS BOOTCAMP_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60          -- se apaga tras 60 segundos sin uso
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE  -- arranca apagado (no cobra)
    COMMENT = 'Warehouse para bootcamp dbt';

-- 2. BASE DE DATOS Y SCHEMAS
CREATE DATABASE IF NOT EXISTS BOOTCAMP_DB
    COMMENT = 'Base de datos del bootcamp dbt';

USE DATABASE BOOTCAMP_DB;

-- RAW: aquí caen los datos crudos (lo que vendría de Fivetran/Airbyte/etc.)
CREATE SCHEMA IF NOT EXISTS RAW;

-- ANALYTICS: aquí dbt materializa los marts (consumo final)
CREATE SCHEMA IF NOT EXISTS ANALYTICS;

-- DEV_JULIO: schema personal para desarrollo
-- En equipos reales cada developer tiene su propio schema (DEV_<NOMBRE>)
CREATE SCHEMA IF NOT EXISTS DEV_JULIO;

-- 3. ROL Y USUARIO DE TRANSFORMACIÓN
-- Mejor práctica: dbt NO debe correr con tu usuario personal ni con ACCOUNTADMIN.
-- Crea un rol dedicado.
CREATE ROLE IF NOT EXISTS TRANSFORMER;

GRANT USAGE ON WAREHOUSE BOOTCAMP_WH TO ROLE TRANSFORMER;
GRANT OPERATE ON WAREHOUSE BOOTCAMP_WH TO ROLE TRANSFORMER;
GRANT USAGE ON DATABASE BOOTCAMP_DB TO ROLE TRANSFORMER;
GRANT USAGE ON ALL SCHEMAS IN DATABASE BOOTCAMP_DB TO ROLE TRANSFORMER;
GRANT CREATE SCHEMA ON DATABASE BOOTCAMP_DB TO ROLE TRANSFORMER;

-- Permisos amplios solo en este DB (NO en toda la cuenta)
GRANT ALL ON SCHEMA RAW TO ROLE TRANSFORMER;
GRANT ALL ON SCHEMA ANALYTICS TO ROLE TRANSFORMER;
GRANT ALL ON SCHEMA DEV_JULIO TO ROLE TRANSFORMER;

-- Permisos futuros (para objetos que se creen después)
GRANT ALL ON FUTURE TABLES IN DATABASE BOOTCAMP_DB TO ROLE TRANSFORMER;
GRANT ALL ON FUTURE VIEWS IN DATABASE BOOTCAMP_DB TO ROLE TRANSFORMER;

-- Asignar el rol a tu usuario (cambia <TU_USUARIO> por el que ves en la UI)
-- GRANT ROLE TRANSFORMER TO USER <TU_USUARIO>;

-- 4. ROL DE LECTURA PARA ANALISTAS (lab 13: data governance)
CREATE ROLE IF NOT EXISTS REPORTER;
GRANT USAGE ON WAREHOUSE BOOTCAMP_WH TO ROLE REPORTER;
GRANT USAGE ON DATABASE BOOTCAMP_DB TO ROLE REPORTER;
GRANT USAGE ON SCHEMA ANALYTICS TO ROLE REPORTER;
GRANT SELECT ON ALL TABLES IN SCHEMA ANALYTICS TO ROLE REPORTER;
GRANT SELECT ON ALL VIEWS IN SCHEMA ANALYTICS TO ROLE REPORTER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA ANALYTICS TO ROLE REPORTER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA ANALYTICS TO ROLE REPORTER;

-- 5. VERIFICACIÓN
SHOW WAREHOUSES LIKE 'BOOTCAMP_WH';
SHOW DATABASES LIKE 'BOOTCAMP_DB';
SHOW SCHEMAS IN DATABASE BOOTCAMP_DB;
SHOW ROLES LIKE 'TRANSFORMER';

-- ============================================================
-- ⚠️ ERRORES TÍPICOS DE PRINCIPIANTE
-- ============================================================
-- 1) Conectar dbt con ACCOUNTADMIN: nunca lo hagas. Si el código
--    tiene un bug, puede borrar cosas críticas. Usa TRANSFORMER.
--
-- 2) Olvidar GRANT ON FUTURE: cuando dbt cree una tabla nueva,
--    el rol REPORTER no podrá leerla. Los GRANT ON FUTURE
--    resuelven esto automáticamente para objetos futuros.
--
-- 3) AUTO_SUSPEND demasiado alto: dejarlo en 600s (10 min)
--    significa que cada lab corto te cuesta 10 minutos de WH.
--    60 segundos es razonable para desarrollo.
--
-- 4) Usar el warehouse default COMPUTE_WH: muchas cuentas lo
--    comparten con otros workloads. Tener BOOTCAMP_WH dedicado
--    aísla tu consumo y te deja medir el costo real.
-- ============================================================
