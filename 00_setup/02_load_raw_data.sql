-- ============================================================
-- CARGA DE DATOS RAW EN SNOWFLAKE
-- ============================================================
-- Dos formas de cargar los datos:
--
--   OPCIÓN A) Usar dbt seeds (más simple): pones los CSV en
--             la carpeta seeds/ del proyecto y corres `dbt seed`.
--             dbt crea las tablas automáticamente.
--             ⚠️ Pero seeds están pensadas para datos pequeños
--             de referencia, no para datos transaccionales.
--             Para ejercicio educativo está OK.
--
--   OPCIÓN B) Cargar manualmente con SQL (más realista):
--             es lo que harías en producción. Subes los CSVs
--             a un stage y usas COPY INTO.
--             Este archivo cubre la opción B.
-- ============================================================

USE ROLE TRANSFORMER;
USE WAREHOUSE BOOTCAMP_WH;
USE DATABASE BOOTCAMP_DB;
USE SCHEMA RAW;

-- 1. CREAR EL FILE FORMAT PARA CSV
CREATE OR REPLACE FILE FORMAT CSV_STANDARD
    TYPE = CSV
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'null')
    EMPTY_FIELD_AS_NULL = TRUE
    TRIM_SPACE = FALSE;  -- ⚠️ FALSE a propósito para que un lab detecte espacios

-- 2. CREAR UN STAGE INTERNO
CREATE OR REPLACE STAGE BOOTCAMP_STAGE
    FILE_FORMAT = CSV_STANDARD
    COMMENT = 'Stage interno para cargar CSVs del bootcamp';

-- 3. SUBIR LOS ARCHIVOS
-- Desde SnowSQL o la UI de Snowflake (Database → BOOTCAMP_DB → RAW → Stages
-- → BOOTCAMP_STAGE → "+ Files"). O desde CLI:
--
--   PUT file:///path/to/bootcamp/seeds/ecommerce/*.csv @BOOTCAMP_STAGE/ecommerce/;
--   PUT file:///path/to/bootcamp/seeds/clickstream/*.csv @BOOTCAMP_STAGE/clickstream/;
--   PUT file:///path/to/bootcamp/seeds/finance/*.csv @BOOTCAMP_STAGE/finance/;

-- 4. CREAR LAS TABLAS RAW
-- =============== ECOMMERCE ===============
CREATE OR REPLACE TABLE RAW.RAW_CUSTOMERS (
    id            INTEGER,
    first_name    STRING,
    last_name     STRING,
    email         STRING,
    signup_date   DATE
);

CREATE OR REPLACE TABLE RAW.RAW_PRODUCTS (
    product_id    INTEGER,
    product_name  STRING,
    category      STRING,
    price_cents   INTEGER,
    is_active     BOOLEAN
);

CREATE OR REPLACE TABLE RAW.RAW_ORDERS (
    order_id      INTEGER,
    customer_id   INTEGER,
    order_date    DATE,
    status        STRING
);

CREATE OR REPLACE TABLE RAW.RAW_ORDER_ITEMS (
    line_id                  INTEGER,
    order_id                 INTEGER,
    product_id               INTEGER,
    quantity                 INTEGER,
    price_cents_at_order     INTEGER
);

CREATE OR REPLACE TABLE RAW.RAW_PAYMENTS (
    payment_id        INTEGER,
    order_id          INTEGER,
    payment_method    STRING,
    amount_cents      INTEGER
);

CREATE OR REPLACE TABLE RAW.RAW_PRODUCT_PRICES_HISTORY (
    price_history_id  INTEGER,
    product_id        INTEGER,
    price_cents       INTEGER,
    valid_from        DATE,
    valid_to          DATE
);

-- =============== CLICKSTREAM ===============
CREATE OR REPLACE TABLE RAW.RAW_USERS (
    user_id         STRING,
    plan            STRING,
    primary_device  STRING,
    signup_date     DATE,
    country         STRING
);

CREATE OR REPLACE TABLE RAW.RAW_CONTENT (
    content_id        STRING,
    title             STRING,
    content_type      STRING,
    genre             STRING,
    release_year      INTEGER,
    duration_seconds  INTEGER
);

CREATE OR REPLACE TABLE RAW.RAW_EVENTS (
    event_id                 STRING,
    event_time               TIMESTAMP_NTZ,
    user_id                  STRING,
    content_id               STRING,
    event_type               STRING,
    playback_position_sec    INTEGER
);

-- =============== FINANCE ===============
CREATE OR REPLACE TABLE RAW.RAW_TRANSACTIONS (
    transaction_id      INTEGER,
    customer_id         INTEGER,
    transaction_date    DATE,
    ingested_at         TIMESTAMP_NTZ,
    amount              NUMBER(12,2),
    currency            STRING,
    transaction_type    STRING
);

CREATE OR REPLACE TABLE RAW.RAW_FX_RATES (
    fx_id           INTEGER,
    rate_date       DATE,
    from_currency   STRING,
    to_currency     STRING,
    rate            NUMBER(12,4)
);

CREATE OR REPLACE TABLE RAW.RAW_CHARGEBACKS (
    chargeback_id      INTEGER,
    transaction_id     INTEGER,
    chargeback_date    DATE,
    reason             STRING
);

-- 5. CARGAR LOS CSVS CON COPY INTO
-- Esto asume que ya subiste los archivos al stage.
COPY INTO RAW.RAW_CUSTOMERS              FROM @BOOTCAMP_STAGE/ecommerce/raw_customers.csv;
COPY INTO RAW.RAW_PRODUCTS               FROM @BOOTCAMP_STAGE/ecommerce/raw_products.csv;
COPY INTO RAW.RAW_ORDERS                 FROM @BOOTCAMP_STAGE/ecommerce/raw_orders.csv;
COPY INTO RAW.RAW_ORDER_ITEMS            FROM @BOOTCAMP_STAGE/ecommerce/raw_order_items.csv;
COPY INTO RAW.RAW_PAYMENTS               FROM @BOOTCAMP_STAGE/ecommerce/raw_payments.csv;
COPY INTO RAW.RAW_PRODUCT_PRICES_HISTORY FROM @BOOTCAMP_STAGE/ecommerce/raw_product_prices_history.csv;

COPY INTO RAW.RAW_USERS    FROM @BOOTCAMP_STAGE/clickstream/raw_users.csv;
COPY INTO RAW.RAW_CONTENT  FROM @BOOTCAMP_STAGE/clickstream/raw_content.csv;
COPY INTO RAW.RAW_EVENTS   FROM @BOOTCAMP_STAGE/clickstream/raw_events.csv;

COPY INTO RAW.RAW_TRANSACTIONS  FROM @BOOTCAMP_STAGE/finance/raw_transactions.csv;
COPY INTO RAW.RAW_FX_RATES      FROM @BOOTCAMP_STAGE/finance/raw_fx_rates.csv;
COPY INTO RAW.RAW_CHARGEBACKS   FROM @BOOTCAMP_STAGE/finance/raw_chargebacks.csv;

-- 6. VERIFICACIÓN
SELECT 'raw_customers'     AS tbl, COUNT(*) FROM RAW.RAW_CUSTOMERS              UNION ALL
SELECT 'raw_products'           , COUNT(*) FROM RAW.RAW_PRODUCTS                UNION ALL
SELECT 'raw_orders'             , COUNT(*) FROM RAW.RAW_ORDERS                  UNION ALL
SELECT 'raw_order_items'        , COUNT(*) FROM RAW.RAW_ORDER_ITEMS             UNION ALL
SELECT 'raw_payments'           , COUNT(*) FROM RAW.RAW_PAYMENTS                UNION ALL
SELECT 'raw_product_prices_hx'  , COUNT(*) FROM RAW.RAW_PRODUCT_PRICES_HISTORY  UNION ALL
SELECT 'raw_users'              , COUNT(*) FROM RAW.RAW_USERS                   UNION ALL
SELECT 'raw_content'            , COUNT(*) FROM RAW.RAW_CONTENT                 UNION ALL
SELECT 'raw_events'             , COUNT(*) FROM RAW.RAW_EVENTS                  UNION ALL
SELECT 'raw_transactions'       , COUNT(*) FROM RAW.RAW_TRANSACTIONS            UNION ALL
SELECT 'raw_fx_rates'           , COUNT(*) FROM RAW.RAW_FX_RATES                UNION ALL
SELECT 'raw_chargebacks'        , COUNT(*) FROM RAW.RAW_CHARGEBACKS;
