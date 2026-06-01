# 🧪 Lab 11 — Data Quality Framework: del "test passed" al "no me despiertan a las 3 AM"

**Nivel:** Avanzado 🔴🔴
**Tiempo estimado:** 120 minutos
**Dominios cubiertos:** dbt_expectations, contracts, anomaly detection, freshness, model versions, severity tiering
**Objetivo de negocio:** *"El último incidente fue así: un upstream cambió un schema, nuestro mart de revenue empezó a reportar 0, finanzas reportó al board con datos malos. Necesitamos detectar eso ANTES de que llegue a producción."*

---

## 🎯 Lo que vas a aprender

1. La jerarquía de defensas: contracts > tests críticos > expectations > freshness > anomaly detection
2. `dbt_expectations`: la librería que cubre lo que `dbt-core` no
3. Model contracts: bloquear builds si el schema cambia
4. Severity tiering: qué es `error`, qué es `warn`, y por qué importa
5. Resolver el data leak de customer_id huérfanos que arrastramos desde Lab 2

## El problema real

Los tests por defecto (`unique`, `not_null`, `accepted_values`, `relationships`) cubren ~30% de los problemas de calidad. El otro 70% son cosas como:

- "El revenue de hoy bajó 80% vs la mediana de los últimos 7 días" (anomaly)
- "Esta columna que era 100% NOT NULL ayer hoy tiene 12% NULLs" (drift)
- "El upstream agregó una columna y nuestro modelo silenciosamente la ignora" (schema drift)
- "Los datos llegaron, pero hace 18 horas. ¿Sigue siendo confiable?" (freshness)

Vamos a montar las 5 capas de defensa.

---

## Paso 1 — Resolver el data leak histórico (15 min)

Recuerda el problema del Lab 2-3: tienes ~2% de `customer_id` en `raw_orders` que no existen en `raw_customers` (huérfanos).

```sql
-- Cuantifica el problema
SELECT
    COUNT(*) AS total_orders,
    COUNT_IF(c.customer_id IS NULL) AS orphan_orders,
    ROUND(COUNT_IF(c.customer_id IS NULL) * 100.0 / COUNT(*), 2) AS pct_orphans
FROM BOOTCAMP_DB.RAW.RAW_ORDERS o
LEFT JOIN BOOTCAMP_DB.RAW.RAW_CUSTOMERS c USING (customer_id);
```

**Tres estrategias para manejar huérfanos** (cada una válida en distinto contexto):

### Estrategia A: Fail-fast (rechazar)

```yaml
# models/marts/ecommerce/_marts.yml
models:
  - name: fct_orders
    columns:
      - name: customer_id
        tests:
          - relationships:
              to: ref('dim_customers')
              field: customer_id
              severity: error  # buildBREAKS si hay huérfanos
```

**Cuándo usarla:** ETL crítico de finanzas. Mejor parar el pipeline que reportar mal.

### Estrategia B: Quarantine (separar)

Crea un modelo `fct_orders_orphans` que se materializa pero NO entra al mart productivo.

```sql
-- models/marts/ecommerce/_quarantine/fct_orders_orphans.sql
{{ config(materialized='table', schema='quarantine') }}

SELECT o.*, CURRENT_TIMESTAMP() AS quarantined_at
FROM {{ ref('stg_orders') }} o
LEFT JOIN {{ ref('stg_customers') }} c USING (customer_id)
WHERE c.customer_id IS NULL
```

Y en tu modelo principal:
```sql
SELECT o.*
FROM {{ ref('stg_orders') }} o
INNER JOIN {{ ref('stg_customers') }} c USING (customer_id)  -- INNER = excluye huérfanos
```

**Cuándo usarla:** Cuando puedes seguir operando sin esas filas, pero quieres investigar después.

### Estrategia C: Bind to "unknown customer"

```sql
SELECT
    o.*,
    COALESCE(c.customer_id, 'UNKNOWN') AS customer_id_resolved,
    CASE WHEN c.customer_id IS NULL THEN TRUE ELSE FALSE END AS is_orphan_order
FROM {{ ref('stg_orders') }} o
LEFT JOIN {{ ref('stg_customers') }} c USING (customer_id)
```

Y en `dim_customers`, inserta una fila sintética `customer_id = 'UNKNOWN'`.

**Cuándo usarla:** Dashboards de ejecutivos que prefieren ver "anónimo" antes que filas faltantes.

> 💡 **Lo que solo se aprende con experiencia:**
> En Netflix/Amazon usan las 3 estrategias combinadas según el dominio. Finanzas usa A (fail-fast). Producto usa B (quarantine para análisis posterior). Marketing usa C (binding) porque sus dashboards no pueden tener huecos.

Para este lab, **usa estrategia B**.

---

## Paso 2 — Instalar dbt_expectations (5 min)

`packages.yml`:
```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: 1.3.0
  - package: calogica/dbt_expectations
    version: 0.10.4
  - package: calogica/dbt_date
    version: 0.10.1
```

```bash
dbt deps
```

`dbt_expectations` te da 60+ tests inspirados en Great Expectations. Lo que `dbt-core` no cubre.

---

## Paso 3 — Tests críticos vs warnings (20 min)

`models/marts/ecommerce/_marts.yml`:

```yaml
version: 2

models:
  - name: fct_orders
    description: "Fact table de órdenes — fuente de verdad para revenue"
    config:
      contract:
        enforced: true  # 🎯 Bloquea build si schema cambia
    columns:
      - name: order_id
        data_type: varchar
        constraints:
          - type: not_null
          - type: primary_key
        tests:
          - unique:
              config:
                severity: error  # SIEMPRE error

      - name: customer_id
        data_type: varchar
        constraints:
          - type: not_null
        tests:
          - relationships:
              to: ref('dim_customers')
              field: customer_id
              config:
                severity: error

      - name: order_total_usd
        data_type: number(18, 2)
        tests:
          - dbt_expectations.expect_column_values_to_be_between:
              min_value: 0
              max_value: 50000
              row_condition: "order_status != 'cancelled'"
              config:
                severity: error  # > $50K USD es sospechoso

          - dbt_expectations.expect_column_mean_to_be_between:
              min_value: 30
              max_value: 500
              config:
                severity: warn  # warn = sigue el build pero alerta

      - name: order_date
        tests:
          - dbt_expectations.expect_column_values_to_be_between:
              min_value: "'2026-01-01'"
              max_value: "current_date()"
              config:
                severity: error  # fechas futuras = bug

    tests:
      # Test a nivel de modelo: row count razonable
      - dbt_expectations.expect_table_row_count_to_be_between:
          min_value: 100
          max_value: 10000000
          config:
            severity: warn

      # Frescura: máximo 24h sin órdenes nuevas
      - dbt_expectations.expect_row_values_to_have_recent_data:
          column_name: order_date
          datepart: hour
          interval: 24
          config:
            severity: error
```

### Anatomía de severity

| Severity | Comportamiento |
|----------|----------------|
| `error` | Build falla. CI bloquea merge. Despiertas a alguien. |
| `warn` | Build pasa. Se loggea. Revisión post-mortem. |

> ⚠️ **Errores típicos de principiante:**
> - Marcar TODO como `error`: el equipo empieza a ignorar las fallas porque son ruido constante. La fatiga de alertas mata el sistema.
> - Marcar TODO como `warn`: nadie revisa los warnings, los problemas se acumulan.
> - **Regla**: error solo para cosas que romperían reportes externos o decisiones de negocio. Todo lo demás, warn.

---

## Paso 4 — Anomaly detection sin Monte Carlo (25 min) 🎯

Detectar "el revenue de hoy es anormalmente bajo" sin pagar herramientas externas.

`models/data_quality/anomaly_revenue_daily.sql`:

```sql
{{ config(materialized='table', schema='data_quality') }}

WITH daily_revenue AS (
    SELECT
        DATE(order_date) AS order_day,
        SUM(order_total_usd) AS revenue_usd,
        COUNT(*) AS order_count
    FROM {{ ref('fct_orders') }}
    WHERE order_status = 'completed'
    GROUP BY 1
),

with_stats AS (
    SELECT
        order_day,
        revenue_usd,
        order_count,
        -- Media móvil de los últimos 7 días (excluyendo hoy)
        AVG(revenue_usd) OVER (
            ORDER BY order_day
            ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
        ) AS revenue_7d_avg,
        STDDEV(revenue_usd) OVER (
            ORDER BY order_day
            ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
        ) AS revenue_7d_stddev
    FROM daily_revenue
)

SELECT
    order_day,
    revenue_usd,
    revenue_7d_avg,
    revenue_7d_stddev,
    -- Z-score: cuántas desviaciones está hoy de la media
    CASE
        WHEN revenue_7d_stddev > 0
        THEN ABS(revenue_usd - revenue_7d_avg) / revenue_7d_stddev
        ELSE 0
    END AS z_score,
    -- Anomaly flag
    CASE
        WHEN ABS(revenue_usd - revenue_7d_avg) / NULLIF(revenue_7d_stddev, 0) > 3
        THEN 'ANOMALY'
        WHEN ABS(revenue_usd - revenue_7d_avg) / NULLIF(revenue_7d_stddev, 0) > 2
        THEN 'WARNING'
        ELSE 'OK'
    END AS anomaly_flag
FROM with_stats
WHERE revenue_7d_avg IS NOT NULL  -- excluye los primeros 7 días sin baseline
```

Ahora un **test custom** que falle si hay anomaly hoy:

`tests/anomaly_revenue_today.sql`:
```sql
-- Tests singulares: si retornan filas, fallan
SELECT *
FROM {{ ref('anomaly_revenue_daily') }}
WHERE order_day = CURRENT_DATE()
  AND anomaly_flag = 'ANOMALY'
```

```yaml
# models/data_quality/_data_quality.yml
version: 2
models:
  - name: anomaly_revenue_daily
    description: "Detección de anomalías en revenue usando z-score con ventana 7d"
```

> 💡 **Lo que solo se aprende con experiencia:**
> - z > 3 = anomaly fuerte (99.7% percentil). z > 2 = warning (95%). Estos thresholds son arbitrarios; ajústalos a tu negocio.
> - Para revenue, una caída es más alarmante que un alza. Considera anomalies one-sided: `revenue < avg - 2*stddev`.
> - Si tienes estacionalidad fuerte (Black Friday), z-score normal te dispara falsos positivos. Usa baseline del mismo día de semana, o desestacionaliza.

---

## Paso 5 — Source freshness (10 min)

Si tus raw tables no se están actualizando, todos tus modelos downstream están construyendo basura.

`models/staging/ecommerce/_sources.yml`:

```yaml
sources:
  - name: raw_ecommerce
    database: BOOTCAMP_DB
    schema: RAW
    tables:
      - name: raw_orders
        loaded_at_field: ingested_at
        freshness:
          warn_after: { count: 6, period: hour }
          error_after: { count: 24, period: hour }

      - name: raw_payments
        loaded_at_field: ingested_at
        freshness:
          warn_after: { count: 12, period: hour }
          error_after: { count: 48, period: hour }
```

Ejecuta:
```bash
dbt source freshness
```

Si tu source no tiene update reciente, el comando falla. En dbt Cloud puedes programarlo como job separado que corra cada hora.

---

## Paso 6 — Model contracts: el escudo contra schema drift (20 min) 🎯

Un **contract** declara: *"este modelo TIENE estas columnas con estos tipos, y si cambia, falla el build."*

`models/marts/ecommerce/dim_customers.sql`:

```sql
{{ config(
    materialized='table',
    contract={'enforced': true}
) }}

SELECT
    customer_id::VARCHAR(50) AS customer_id,
    customer_email::VARCHAR(255) AS customer_email,
    customer_first_name::VARCHAR(100) AS customer_first_name,
    customer_last_name::VARCHAR(100) AS customer_last_name,
    registered_at::TIMESTAMP_NTZ AS registered_at,
    is_active::BOOLEAN AS is_active,
    CURRENT_TIMESTAMP() AS dbt_processed_at
FROM {{ ref('stg_customers') }}
```

Y en el YAML:
```yaml
models:
  - name: dim_customers
    config:
      contract:
        enforced: true
    columns:
      - name: customer_id
        data_type: varchar(50)
        constraints: [{type: not_null}, {type: primary_key}]
      - name: customer_email
        data_type: varchar(255)
        constraints: [{type: not_null}]
      - name: customer_first_name
        data_type: varchar(100)
      - name: customer_last_name
        data_type: varchar(100)
      - name: registered_at
        data_type: timestamp_ntz
      - name: is_active
        data_type: boolean
        constraints: [{type: not_null}]
      - name: dbt_processed_at
        data_type: timestamp_ntz
```

**Pruébalo**: cambia el SELECT a algo que omita `customer_email` y corre `dbt run --select dim_customers`. **Falla antes de tocar Snowflake.**

> 💡 **Lo que solo se aprende con experiencia:**
> En Amazon, los marts críticos SIEMPRE tienen contracts enforced. Es la diferencia entre "el dashboard del CFO se rompió" y "el CI bloqueó el merge con un error claro de qué columna falta".

---

## Paso 7 — Tests de unicidad compuesta y patrones (10 min)

```yaml
models:
  - name: fct_order_items
    tests:
      # Combinación de columnas única
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns:
            - order_id
            - product_id

    columns:
      - name: product_sku
        tests:
          # Regex: debe matchear formato esperado
          - dbt_expectations.expect_column_values_to_match_regex:
              regex: "^SKU-[0-9]{6}$"

      - name: unit_price_usd
        tests:
          - dbt_expectations.expect_column_values_to_not_be_null
          # No solo > 0, también que no sea negativo Y que tenga decimales razonables
          - dbt_expectations.expect_column_values_to_be_between:
              min_value: 0.01
              max_value: 9999.99
```

---

## Paso 8 — Severity tier completo (15 min)

Vamos a establecer la jerarquía completa de calidad de datos:

```yaml
# models/marts/ecommerce/fct_orders.yml — versión completa

models:
  - name: fct_orders
    columns:

      # TIER 1 — CRÍTICO (despierta gente a las 3 AM)
      - name: order_id
        tests:
          - unique: { config: { severity: error } }
          - not_null: { config: { severity: error } }

      - name: order_total_usd
        tests:
          - not_null: { config: { severity: error } }
          - dbt_expectations.expect_column_values_to_be_between:
              min_value: 0
              max_value: 100000
              config: { severity: error }

      # TIER 2 — IMPORTANTE (review en business hours)
      - name: customer_id
        tests:
          - relationships:
              to: ref('dim_customers')
              field: customer_id
              config: { severity: warn }  # quarantine ya maneja los huérfanos

      # TIER 3 — INFORMATIVO (métricas de calidad, dashboard)
      - name: order_status
        tests:
          - accepted_values:
              values: ['pending', 'paid', 'shipped', 'completed', 'cancelled', 'refunded']
              config: { severity: warn }
```

Y configura en tu `dbt_project.yml`:

```yaml
tests:
  +severity: warn  # default global: warn
  +store_failures: true  # guarda filas que fallaron en tabla
  +store_failures_as: table
```

`store_failures: true` es oro: cuando algo falla, puedes inspeccionar exactamente qué filas causaron el problema.

```sql
-- Después de un dbt test fallido
SELECT * FROM BOOTCAMP_DB.DBT_TEST_FAILURES.WHATEVER_FALLO LIMIT 100;
```

---

## Paso 9 — Ejecutar todo el framework (5 min)

```bash
# Tests por severity
dbt test --select fct_orders                       # corre todos
dbt test --select fct_orders --severity error      # solo críticos (para CI)
dbt test --select fct_orders --severity warn       # solo warnings

# Source freshness
dbt source freshness

# Test específico custom
dbt test --select anomaly_revenue_today
```

En tu CI/CD ideal:
- **PR build**: `dbt test --severity error` (rápido, bloquea merge)
- **Daily prod job**: `dbt test` completo + `dbt source freshness`
- **Hourly job**: solo source freshness
- **Weekly**: `dbt test --select tag:anomaly` para revisión

---

## ✅ Checklist de salida

- [ ] Resolviste los customer_id huérfanos con estrategia B (quarantine)
- [ ] Instalaste `dbt_expectations`
- [ ] Tu `fct_orders` tiene contract enforced
- [ ] Tienes `anomaly_revenue_daily` con z-score
- [ ] Tienes source freshness configurado
- [ ] Entiendes la diferencia entre error/warn y cuándo usar cada uno
- [ ] `store_failures` activo para debugging

---

## 🎓 Preguntas tipo entrevista senior

1. *"Tu test `unique` en `order_id` empieza a fallar en producción. ¿Qué haces?"*
   → Primero: `SELECT order_id, COUNT(*) FROM fct_orders GROUP BY 1 HAVING COUNT(*) > 1`. Si son duplicados de un microbatch que corrió 2 veces sin idempotencia, fix en el modelo. Si son duplicados upstream, abrir ticket. Mientras tanto: `severity: warn` temporal con comentario y fecha de revisión.

2. *"¿Cómo diferencias 'anomaly' de 'cambio legítimo del negocio'?"*
   → Anomaly = breakdown estadístico (z > 3). Cambio legítimo = correlacionado con eventos conocidos (lanzamiento, campaña, estacionalidad). La práctica es: cuando salta una alerta, los analistas la marcan como TP o FP en un labeling system. Con tiempo, mejoras el threshold.

3. *"¿Cuándo NO usar contract enforcement?"*
   → Modelos staging que mutan rápido durante desarrollo. Modelos exploratorios. Modelos sin downstream consumer crítico. Enforce contracts solo en lo que toca dashboards productivos.

---

➡️ **Siguiente:** [Lab 12 — Backfills históricos masivos](./lab_12_backfills_masivos.md)
