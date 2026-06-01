# 🧪 Lab 14 — Cost Optimization + Semantic Layer: el lab final

**Nivel:** Avanzado 🔴🔴
**Tiempo estimado:** 120 minutos
**Dominios cubiertos:** QUERY_HISTORY analysis, model refactoring, audit_helper, Slim CI, dbt Semantic Layer, métricas conformadas
**Objetivo de negocio:** *"El bill de Snowflake del mes pasado fue $47K. Encontrar los 10 modelos más caros y bajarlos al menos 30%. Y mientras estamos en eso: el CFO está harto de que finance, marketing y producto reporten 'revenue' con números distintos. Necesitamos UNA definición."*

---

## 🎯 Lo que vas a aprender

1. Analizar `QUERY_HISTORY` para encontrar los modelos más caros
2. Refactoring con `audit_helper`: validar que el nuevo modelo da los mismos números que el viejo
3. **Slim CI**: solo testear lo que cambió en cada PR (de 30 min a 3 min)
4. **dbt Semantic Layer**: definir métricas una sola vez, consultar desde cualquier herramienta
5. La diferencia entre un Data Engineer Senior y uno Mid: la habilidad de hacer pipelines **baratos**

---

## Paso 1 — Encontrar los modelos más caros (20 min) 🎯

Snowflake guarda historial de queries en `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY`. dbt etiqueta cada query con metadata útil.

```sql
USE WAREHOUSE BOOTCAMP_WH;

-- Top 20 modelos por consumo de créditos en últimos 30 días
WITH dbt_queries AS (
    SELECT
        query_id,
        query_text,
        execution_time / 1000.0 AS execution_seconds,
        credits_used_cloud_services,
        bytes_scanned,
        rows_produced,
        start_time,
        warehouse_size,
        -- Extraer el nombre del modelo del comentario de dbt
        REGEXP_SUBSTR(
            query_text,
            'node_id"\\s*:\\s*"model\\.[^.]+\\.([^"]+)"',
            1, 1, 'e', 1
        ) AS model_name
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time > DATEADD(DAY, -30, CURRENT_TIMESTAMP())
      AND query_text ILIKE '%dbt%'
      AND query_type IN ('CREATE_TABLE_AS_SELECT', 'MERGE', 'INSERT')
)
SELECT
    model_name,
    COUNT(*) AS runs,
    SUM(execution_seconds) AS total_seconds,
    AVG(execution_seconds) AS avg_seconds,
    SUM(credits_used_cloud_services) AS total_credits,
    SUM(bytes_scanned) / POW(1024, 4) AS terabytes_scanned,
    SUM(rows_produced) / 1000000 AS millions_rows_produced
FROM dbt_queries
WHERE model_name IS NOT NULL
GROUP BY model_name
ORDER BY total_credits DESC NULLS LAST
LIMIT 20;
```

> 💡 **Lo que solo se aprende con experiencia:**
> No optimices el primer modelo de la lista sin investigar. A veces el #1 es caro porque corre 1000 veces al día (microbatch sano), no porque esté mal diseñado. Mira `runs × avg_seconds`, no solo `total_credits`.

### Identificar patrones problemáticos

```sql
-- Modelos que escanean mucho pero producen poco (señal de filtro tardío)
WITH dbt_queries AS (...)  -- igual que arriba
SELECT
    model_name,
    AVG(bytes_scanned / POW(1024, 3)) AS avg_gb_scanned,
    AVG(rows_produced) AS avg_rows_produced,
    AVG(bytes_scanned / NULLIF(rows_produced, 0)) AS bytes_per_output_row
FROM dbt_queries
GROUP BY model_name
HAVING avg_gb_scanned > 1
ORDER BY bytes_per_output_row DESC
LIMIT 10;
```

Si `bytes_per_output_row` es alto, estás escaneando demasiado para producir poco. **Filtros tardíos** o **falta de partition pruning**.

---

## Paso 2 — Refactor: el filtro tardío clásico (15 min)

Imagina que tu `fct_orders` se ve así:

```sql
-- ❌ ANTES: filtra al final
WITH all_orders AS (
    SELECT * FROM {{ ref('stg_orders') }}  -- escanea TODOS los años
),
all_payments AS (
    SELECT * FROM {{ ref('stg_payments') }}  -- escanea TODOS los años
),
joined AS (
    SELECT o.*, p.payment_method, p.payment_date
    FROM all_orders o
    LEFT JOIN all_payments p USING (order_id)
)
SELECT * FROM joined
WHERE order_date >= '2026-01-01'  -- filtro AL FINAL
```

**El refactor:**

```sql
-- ✅ DESPUÉS: filtra ANTES del join
WITH recent_orders AS (
    SELECT *
    FROM {{ ref('stg_orders') }}
    WHERE order_date >= '2026-01-01'  -- 🎯 filtro arriba
),
recent_payments AS (
    SELECT *
    FROM {{ ref('stg_payments') }}
    WHERE payment_date >= '2026-01-01'  -- 🎯 filtro arriba
),
joined AS (
    SELECT o.*, p.payment_method, p.payment_date
    FROM recent_orders o
    LEFT JOIN recent_payments p USING (order_id)
)
SELECT * FROM joined
```

**Por qué funciona:**
- Snowflake hace **pruning de micro-partitions** cuando filtras antes de joinear
- Menos bytes_scanned → menos tiempo → menos créditos
- A escala de 1B filas, esto puede ser **10x más rápido**

> ⚠️ **Errores típicos de principiante:**
> Confiar en que el optimizer va a empujar el filtro hacia abajo. Snowflake **a veces** lo hace, pero NO con joins complejos, agregaciones intermedias o subqueries. **Filtra explícitamente arriba**.

---

## Paso 3 — Validar el refactor con audit_helper (20 min) 🎯

`audit_helper` es un package de dbt-labs para comparar dos versiones de un modelo.

```yaml
# packages.yml
packages:
  - package: dbt-labs/audit_helper
    version: 0.12.1
```

```bash
dbt deps
```

### Comparar row counts y schemas

```sql
-- analyses/audit_fct_orders.sql
{# Compara fct_orders_v1 (antes del refactor) con fct_orders_v2 (después) #}

{{
    audit_helper.compare_relations(
        a_relation=ref('fct_orders_v1'),
        b_relation=ref('fct_orders_v2'),
        primary_key='order_id'
    )
}}
```

```bash
dbt compile --select audit_fct_orders
```

dbt genera SQL que ejecutas en Snowflake y te dice exactamente qué filas difieren entre ambas versiones.

### Comparar valores columna por columna

```sql
-- analyses/audit_fct_orders_column_values.sql
{{
    audit_helper.compare_column_values(
        a_query="SELECT * FROM " ~ ref('fct_orders_v1'),
        b_query="SELECT * FROM " ~ ref('fct_orders_v2'),
        primary_key='order_id',
        column_to_compare='order_total_usd'
    )
}}
```

Resultado: te dice cuántas filas tienen valor distinto en `order_total_usd` entre v1 y v2.

> 💡 **Lo que solo se aprende con experiencia:**
> NUNCA reemplaces un modelo crítico sin un audit. Aunque tú "estés seguro" de que el refactor es equivalente, audit_helper te ahorrará una explicación incómoda al CFO cuando descubra que el revenue de Q1 cambió 0.3% por un edge case.

---

## Paso 4 — Optimizar materializaciones por modelo (15 min)

Recapitulando lo del Lab 5, pero ahora con criterio basado en datos:

```sql
-- ¿Qué modelos están materialized=table pero solo se consultan en CI?
SELECT
    object_name,
    COUNT(*) AS reads_last_30d
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
     LATERAL FLATTEN(input => ah.base_objects_accessed) f
WHERE start_time > DATEADD(DAY, -30, CURRENT_TIMESTAMP())
  AND f.value:objectDomain = 'Table'
  AND f.value:objectName ILIKE '%BOOTCAMP_DB%'
GROUP BY 1
HAVING COUNT(*) < 10
ORDER BY 2;
```

Si un modelo se lee menos de 10 veces al mes y se materializa como `table`, considera:

- → `view` (no almacena, recompute al leer)
- → `ephemeral` (compila como CTE, ni siquiera existe en Snowflake)

### Decisión por uso

| Reads/día | Compute cost build | Materialización óptima |
|-----------|---------------------|------------------------|
| > 100 | Bajo | `table` (paga 1 vez, lee N veces) |
| > 100 | Alto | `incremental` (paga delta, lee N veces) |
| 10-100 | Bajo | `view` (sin storage, paga al leer) |
| < 10 | Cualquiera | `view` o `ephemeral` |
| 1 (solo en CI) | Cualquiera | `ephemeral` |

---

## Paso 5 — Snowflake-specific optimizations (15 min) 🎯

### Cluster keys

Para tablas grandes (>1B filas), un **clustering key** acelera filtros sobre esa columna.

```sql
-- En el modelo
{{ config(
    materialized='table',
    cluster_by=['order_date', 'customer_id']
) }}

SELECT ...
```

Cuándo usarlo:
- Tabla > 100GB
- Queries filtran consistentemente por la(s) misma(s) columna(s)
- No la pongas en TODAS las tablas: el clustering tiene costo de mantenimiento

### Transient tables (sin Time Travel)

```sql
{{ config(
    materialized='table',
    transient=true   -- 🎯 sin Fail-safe ni Time Travel
) }}
```

Cuándo usarlo:
- Modelos staging/intermediate que se regeneran completos en cada run
- No necesitas recovery de la tabla a un punto pasado
- **Ahorra**: tabla normal tiene 7 días de Time Travel + 7 días de Fail-safe = 14 días de storage extra. Transient = 0.

### Warehouse por modelo

Modelos pesados pueden usar warehouse más grande temporalmente:

```sql
{{ config(
    materialized='table',
    snowflake_warehouse='BOOTCAMP_WH_LARGE'
) }}
```

Y configuras `BOOTCAMP_WH_LARGE` con auto-suspend de 60 segundos. Solo paga cuando corre.

---

## Paso 6 — Slim CI: solo testear lo que cambió (15 min) 🎯

Tu PR cambia 2 modelos. Pero el CI corre los 200. **Eso es 50 minutos de CI por PR.** Slim CI lo resuelve.

### En dbt Cloud

En tu job de CI, marca:
- ✅ "Defer to another environment" → apunta a tu prod
- ✅ "Run only modified models"

dbt comparará el manifest del PR contra el manifest de prod, y solo correrá lo modificado.

### En CLI

```bash
# Subir manifest de prod a un bucket S3/GCS
dbt run --target prod --upload-artifacts

# En el PR
dbt run --select state:modified+ --defer --state ./prod_manifest
```

- `state:modified+` = modelos modificados + sus descendientes
- `--defer` = referencias a modelos no modificados apuntan a prod (no rebuild)

> 💡 **Lo que solo se aprende con experiencia:**
> Slim CI puede llevar tu CI de 30 minutos a 3 minutos en PRs típicos. **PERO**, debes correr el job completo en main al menos diario para detectar regresiones que `state:modified+` no captura.

---

## Paso 7 — dbt Semantic Layer: una sola definición de "revenue" (20 min) 🎯

El problema clásico: Finance dice $1M, Marketing dice $1.05M, Producto dice $980K. **Todos calculan "revenue" distinto.**

Semantic Layer = definir métricas una vez, consultar desde Tableau/Looker/Mode/Hex con la misma definición.

### Definir una semantic model

`models/semantic/orders_semantic.yml`:

```yaml
version: 2

semantic_models:
  - name: orders
    description: "Semantic model centralizado para órdenes y revenue"
    model: ref('fct_orders')

    defaults:
      agg_time_dimension: order_date

    entities:
      - name: order
        type: primary
        expr: order_id
      - name: customer
        type: foreign
        expr: customer_id

    dimensions:
      - name: order_date
        type: time
        type_params:
          time_granularity: day
      - name: order_status
        type: categorical
      - name: order_country
        type: categorical

    measures:
      - name: order_count
        agg: count
        expr: order_id

      - name: total_revenue
        agg: sum
        expr: order_total_usd
        # 🎯 Filtros aplicados a TODA query que use esta medida
        agg_time_dimension: order_date

      - name: avg_order_value
        agg: average
        expr: order_total_usd
```

### Definir las métricas

`models/semantic/_metrics.yml`:

```yaml
version: 2

metrics:
  - name: revenue
    label: "Revenue (USD)"
    description: "Revenue de órdenes completadas en USD. Excluye refunds y cancelaciones."
    type: simple
    type_params:
      measure:
        name: total_revenue
        filter: |
          {{ Dimension('order__order_status') }} = 'completed'

  - name: revenue_yoy_growth
    label: "Revenue YoY %"
    description: "Crecimiento de revenue vs mismo período año anterior"
    type: derived
    type_params:
      expr: "(current_revenue - prior_year_revenue) / prior_year_revenue * 100"
      metrics:
        - name: revenue
          alias: current_revenue
        - name: revenue
          offset_window: 1 year
          alias: prior_year_revenue

  - name: average_order_value
    label: "AOV"
    description: "Ticket promedio"
    type: ratio
    type_params:
      numerator:
        name: total_revenue
        filter: |
          {{ Dimension('order__order_status') }} = 'completed'
      denominator: order_count
```

Ahora, sin importar de dónde consulten:

```sql
-- Desde dbt
dbt sl query --metrics revenue --group-by order_date,order_country

-- Desde Tableau/Looker
SELECT revenue, order_date, order_country
FROM {{ semantic_layer.metric('revenue') }}
```

**Todos obtienen el mismo número.** La definición vive en un solo lugar.

> 💡 **Lo que solo se aprende con experiencia:**
> Semantic Layer es lo más cercano a un "single source of truth" verdadero que existe en data. Pero requiere disciplina: cualquier cálculo de revenue que no vaya por el Semantic Layer rompe el contrato. Es decisión organizacional, no técnica.

---

## Paso 8 — Auditoría de costo final (10 min)

Cierra el lab generando un reporte ejecutivo de cuánto ahorraste:

```sql
WITH before_optimization AS (
    SELECT
        DATE_TRUNC('week', start_time) AS week,
        SUM(credits_used_cloud_services * 2.0) AS estimated_usd
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time BETWEEN DATEADD(DAY, -60, CURRENT_TIMESTAMP())
                         AND DATEADD(DAY, -30, CURRENT_TIMESTAMP())
      AND query_text ILIKE '%dbt%'
    GROUP BY 1
),
after_optimization AS (
    SELECT
        DATE_TRUNC('week', start_time) AS week,
        SUM(credits_used_cloud_services * 2.0) AS estimated_usd
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time > DATEADD(DAY, -30, CURRENT_TIMESTAMP())
      AND query_text ILIKE '%dbt%'
    GROUP BY 1
)
SELECT
    AVG(b.estimated_usd) AS avg_weekly_before,
    AVG(a.estimated_usd) AS avg_weekly_after,
    (AVG(b.estimated_usd) - AVG(a.estimated_usd)) AS weekly_savings,
    ROUND((AVG(b.estimated_usd) - AVG(a.estimated_usd)) / AVG(b.estimated_usd) * 100, 1) AS pct_reduction
FROM before_optimization b, after_optimization a;
```

Esto es lo que llevas al 1:1 con tu manager.

---

## ✅ Checklist de salida

- [ ] Identificaste el top 10 de modelos más caros
- [ ] Refactorizaste al menos uno aplicando filtros tempranos
- [ ] Validaste el refactor con `audit_helper`
- [ ] Convertiste al menos 2 modelos de `table` a `view` por bajo uso
- [ ] Aplicaste `transient=true` a modelos staging
- [ ] Slim CI configurado en dbt Cloud
- [ ] Al menos 3 métricas en Semantic Layer (revenue, AOV, una derivada)
- [ ] Reporte de ahorro %

---

## 🎓 Preguntas tipo entrevista senior

1. *"¿Cómo justificarías ante el CFO contratar otro Data Engineer?"*
   → Mostrando ahorro generado por optimizaciones. "El último Data Engineer le ahorró a la empresa $200K/año en compute Snowflake refactorizando 15 modelos. Necesitamos otro para hacer lo mismo en los próximos 30 modelos identificados."

2. *"Un modelo es caro porque agrega 100M filas con DISTINCT. ¿Qué haces?"*
   → DISTINCT en 100M filas es lento. Alternativas: (a) eliminar duplicados upstream en staging (mejor), (b) usar `QUALIFY ROW_NUMBER() OVER (PARTITION BY pk ORDER BY ts DESC) = 1` que en Snowflake suele ser más rápido que DISTINCT, (c) si los duplicados son del 1%, considerar `APPROX_COUNT_DISTINCT` cuando exactitud no es crítica.

3. *"¿Cuándo NO vale la pena usar Semantic Layer?"*
   → Cuando tu equipo es pequeño (1-3 personas) y no hay múltiples consumers de BI. Es overhead innecesario. También cuando las métricas son muy bespoke por dashboard (sin oportunidad de reuso). Semantic Layer brilla en orgs con 5+ analistas y 3+ herramientas BI.

---

## 🎉 ¡Completaste el bootcamp!

Llevas:
- **14 labs** que cubren los 7 dominios del exam dbt Certification
- **Casos reales** tipo Netflix/Amazon (microbatch, backfills, governance, semantic layer)
- **3 datasets multi-domain** (ecommerce + clickstream + finance)
- **Datos sintéticos** con problemas intencionales para practicar debugging

### Próximos pasos sugeridos

1. **Certificación**: ya estás listo para `dbt Analytics Engineer Certification` (Lab 0 cubrió la teoría)
2. **Proyecto portfolio**: monta este bootcamp en un repo público de GitHub con README profesional
3. **Profundizar**: el siguiente nivel es **dbt + Airflow** (orquestación) y **dbt + Spark/Databricks** (escala masiva)
4. **Comunidad**: postea en LinkedIn algunos casos del bootcamp con tu brand "El Universo Spark"

---

🏁 **Has llegado al final.** Si llegaste hasta aquí practicando cada lab, estás técnicamente al nivel de un Data Engineer Senior en dbt.
