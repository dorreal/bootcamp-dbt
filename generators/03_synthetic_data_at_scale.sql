-- ============================================================
-- GENERADOR DE EVENTOS A ESCALA (para labs avanzados)
-- ============================================================
-- Este script crea una tabla de eventos GRANDE directamente en
-- Snowflake usando GENERATOR(). Lo usaremos en los labs 10-14
-- (microbatch, backfills, optimización de costo).
--
-- Snowflake permite crear millones de filas sin importar
-- archivos. Es la forma realista de testear pipelines a escala.
-- ============================================================

USE ROLE TRANSFORMER;
USE WAREHOUSE BOOTCAMP_WH;
USE DATABASE BOOTCAMP_DB;
USE SCHEMA RAW;

-- ============================================================
-- TABLA: RAW_EVENTS_LARGE  (10 millones de filas, ~12 meses)
-- ============================================================
-- Si estás con XSMALL, esto tarda ~1-2 minutos. No te asustes.
-- Si necesitas más velocidad, sube el WH a SMALL temporalmente.

CREATE OR REPLACE TABLE RAW.RAW_EVENTS_LARGE AS
WITH params AS (
    SELECT 10000000 AS total_rows  -- ⬅️ Cambia esto si quieres más/menos
),
seq AS (
    SELECT SEQ8() AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 10000000))
)
SELECT
    'e_' || LPAD(rn::STRING, 10, '0')                            AS event_id,
    -- Distribuye los eventos uniformemente en los últimos 365 días
    DATEADD(
        'second',
        UNIFORM(0, 365*24*3600, RANDOM(rn)) * -1,
        CURRENT_TIMESTAMP()
    )::TIMESTAMP_NTZ                                              AS event_time,
    'u_' || LPAD(UNIFORM(1, 50000, RANDOM(rn+1))::STRING, 5, '0') AS user_id,
    'c_' || LPAD(UNIFORM(1, 5000, RANDOM(rn+2))::STRING, 4, '0')  AS content_id,
    CASE UNIFORM(1, 5, RANDOM(rn+3))
        WHEN 1 THEN 'play_start'
        WHEN 2 THEN 'play_pause'
        WHEN 3 THEN 'play_resume'
        WHEN 4 THEN 'play_complete'
        ELSE 'play_abandon'
    END                                                           AS event_type,
    UNIFORM(0, 7200, RANDOM(rn+4))                                AS playback_position_sec
FROM seq;

-- Verificación rápida
SELECT
    COUNT(*) AS total_rows,
    MIN(event_time) AS earliest_event,
    MAX(event_time) AS latest_event,
    COUNT(DISTINCT user_id) AS unique_users,
    COUNT(DISTINCT content_id) AS unique_content
FROM RAW.RAW_EVENTS_LARGE;

-- ============================================================
-- TABLA: RAW_TRANSACTIONS_LARGE (5 millones, 24 meses)
-- ============================================================
-- Para los labs de finance que requieren series temporales reales.

CREATE OR REPLACE TABLE RAW.RAW_TRANSACTIONS_LARGE AS
WITH seq AS (
    SELECT SEQ8() AS rn FROM TABLE(GENERATOR(ROWCOUNT => 5000000))
)
SELECT
    rn + 1                                                        AS transaction_id,
    UNIFORM(1, 100000, RANDOM(rn))                                AS customer_id,
    DATEADD('second',
            UNIFORM(0, 730*24*3600, RANDOM(rn+1)) * -1,
            CURRENT_TIMESTAMP())::DATE                            AS transaction_date,
    -- ingested_at: en producción esto refleja CUÁNDO llegó el evento al warehouse,
    -- no cuándo ocurrió. Importante para late-arriving (lab 8).
    DATEADD('second',
            UNIFORM(0, 86400*3, RANDOM(rn+5)),    -- 0-3 días después
            DATEADD('second',
                    UNIFORM(0, 730*24*3600, RANDOM(rn+1)) * -1,
                    CURRENT_TIMESTAMP()))                         AS ingested_at,
    ROUND(UNIFORM(5, 850, RANDOM(rn+2))::FLOAT
          + UNIFORM(0, 99, RANDOM(rn+3))/100.0, 2)                AS amount,
    CASE UNIFORM(1, 7, RANDOM(rn+4))
        WHEN 1 THEN 'USD' WHEN 2 THEN 'MXN' WHEN 3 THEN 'USD'
        WHEN 4 THEN 'USD' WHEN 5 THEN 'EUR' WHEN 6 THEN 'BRL'
        ELSE 'ARS'
    END                                                           AS currency,
    CASE UNIFORM(1, 5, RANDOM(rn+6))
        WHEN 1 THEN 'credit' WHEN 2 THEN 'refund'
        ELSE 'debit'
    END                                                           AS transaction_type
FROM seq;

SELECT COUNT(*), MIN(transaction_date), MAX(transaction_date)
FROM RAW.RAW_TRANSACTIONS_LARGE;

-- ============================================================
-- ⚠️ ERRORES TÍPICOS DE PRINCIPIANTE
-- ============================================================
-- 1) Generar 100M+ filas con un warehouse XSMALL:
--    Tarda mucho y puede timeout. Sube a SMALL o MEDIUM
--    temporalmente y luego BAJA otra vez (el costo se cobra
--    por segundo y por tamaño de warehouse).
--
-- 2) No usar RANDOM(rn) con seed:
--    Si usas RANDOM() sin argumento, cada columna genera
--    valores INDEPENDIENTES. Con RANDOM(rn) basas la
--    aleatoriedad en la fila, así múltiples columnas
--    pueden correlacionarse de forma reproducible.
--
-- 3) Olvidar el cast a TIMESTAMP_NTZ:
--    DATEADD() devuelve TIMESTAMP_LTZ por defecto, que
--    cambia según la zona horaria. Para data engineering
--    usa TIMESTAMP_NTZ (sin zona) por consistencia.
--
-- 4) Pensar que generator es "datos reales":
--    Tus datos sintéticos tienen distribución UNIFORME.
--    Datos reales tienen distribución de power-law
--    (pocos contenidos concentran la mayoría de vistas).
--    Para tests de optimización funciona bien, pero no
--    asumas que el query plan será igual con datos reales.
-- ============================================================
