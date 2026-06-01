# 🧪 Lab 12 — Backfills históricos: reprocesar 3 años sin tumbar el warehouse

**Nivel:** Avanzado 🔴🔴
**Tiempo estimado:** 100 minutos
**Dominios cubiertos:** Backfills paralelos, scaling warehouse dinámico, particionado lógico, recovery de fallos parciales, cost-aware backfills
**Objetivo de negocio:** *"Cambiamos la lógica de cálculo de revenue (un bug que arrastrábamos hace 18 meses). Necesitamos reprocesar 3 años de fact tables (~2 billones de filas). El CFO necesita los nuevos números el lunes. Si tumbamos el warehouse, paramos toda la operación."*

---

## 🎯 Lo que vas a aprender

1. La diferencia entre `--full-refresh`, microbatch backfill y backfill manual particionado
2. Cómo escalar warehouse temporalmente sin pagar por capacidad ociosa
3. Particionar un backfill en chunks paralelos
4. Recovery: cómo retomar un backfill que falló al 70%
5. Cost-aware: estimar antes de ejecutar

---

## El problema del `--full-refresh` ingenuo

Tu instinto inicial será:

```bash
dbt run --select fct_orders --full-refresh
```

**Por qué esto es un desastre a escala:**

1. **Una sola transacción gigante**: 2B filas en un solo INSERT. Si falla al 95%, pierdes todo.
2. **Locks**: durante todo el run, tus dashboards leen datos viejos o nada.
3. **Warehouse saturado**: queries de analistas y otros pipelines se trancan.
4. **Sin observabilidad**: no sabes si está al 10% o al 90%.
5. **Sin recovery**: si tarda 8h y se cae a la hora 7, vuelves a empezar.

Vamos a construir un backfill **profesional**.

---

## Paso 1 — Estimar antes de ejecutar (15 min)

Primero, mide qué tan grande es el problema.

```sql
USE WAREHOUSE BOOTCAMP_WH;
USE DATABASE BOOTCAMP_DB;

-- ¿Cuántas filas vamos a procesar?
SELECT
    DATE_TRUNC('month', event_timestamp) AS month,
    COUNT(*) AS event_count,
    COUNT(*) / 1000000 AS millions
FROM RAW.RAW_EVENTS_LARGE
GROUP BY 1
ORDER BY 1;
```

```sql
-- Estimación de costo con QUERY_HISTORY (en producción real)
SELECT
    DATE_TRUNC('day', start_time) AS day,
    AVG(execution_time / 1000.0) AS avg_seconds,
    SUM(credits_used_cloud_services) AS credits,
    -- Aproximación: en Snowflake, XSMALL = 1 credit/hour
    SUM(credits_used_cloud_services) * 2.0 AS estimated_usd_at_2per_credit
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_text ILIKE '%fct_events_daily%'
  AND start_time > DATEADD(DAY, -30, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1 DESC
LIMIT 30;
```

> 💡 **Lo que solo se aprende con experiencia:**
> Antes de un backfill grande, calcula:
> - **Tiempo estimado**: filas a procesar / throughput histórico
> - **Costo estimado**: créditos por día × tamaño del warehouse × duración
> - **Storage delta**: el backfill duplicará temporalmente el storage (tabla vieja + nueva)
>
> Si no haces esta estimación, te aseguro que el Slack del lunes va a tener mensajes que no quieres recibir.

---

## Paso 2 — Estrategia: dividir el problema (15 min)

**Mala estrategia:**
```bash
dbt run --select fct_events_daily --event-time-start "2023-01-01" --event-time-end "2026-05-28"
```
→ 1175 batches secuenciales = 8-10 horas, sin paralelismo.

**Buena estrategia:** Particionar por trimestre y correr 4 procesos paralelos:

```
Worker 1: 2023-Q1, 2024-Q1, 2025-Q1
Worker 2: 2023-Q2, 2024-Q2, 2025-Q2
Worker 3: 2023-Q3, 2024-Q3, 2025-Q3
Worker 4: 2023-Q4, 2024-Q4, 2025-Q4
```

Cada worker es independiente. Si uno falla, los otros 3 siguen.

---

## Paso 3 — Crear un control table de progreso (15 min) 🎯

Antes de empezar, necesitas saber qué se hizo y qué falta.

```sql
CREATE OR REPLACE TABLE BOOTCAMP_DB.OPS.BACKFILL_PROGRESS (
    backfill_id VARCHAR,
    model_name VARCHAR,
    partition_start DATE,
    partition_end DATE,
    status VARCHAR,  -- 'pending', 'running', 'success', 'failed'
    row_count NUMBER,
    started_at TIMESTAMP_NTZ,
    finished_at TIMESTAMP_NTZ,
    duration_seconds NUMBER,
    error_message VARCHAR,
    PRIMARY KEY (backfill_id, model_name, partition_start)
);

-- Inicializar las particiones
INSERT INTO BOOTCAMP_DB.OPS.BACKFILL_PROGRESS (
    backfill_id, model_name, partition_start, partition_end, status
)
SELECT
    'backfill_revenue_2026_05',
    'fct_events_daily',
    DATEADD(DAY, -90, CURRENT_DATE()) + (SEQ * 30),  -- chunks de 30 días
    DATEADD(DAY, -90, CURRENT_DATE()) + ((SEQ + 1) * 30),
    'pending'
FROM (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS SEQ
    FROM TABLE(GENERATOR(ROWCOUNT => 3))  -- 3 particiones de 30 días = 90 días
);

SELECT * FROM BOOTCAMP_DB.OPS.BACKFILL_PROGRESS;
```

Ahora tienes una "tabla de batalla" donde marcas qué chunks están listos.

---

## Paso 4 — Macro de backfill con tracking (20 min)

`macros/backfill_partition.sql`:

```sql
{% macro run_backfill_partition(model_name, backfill_id, partition_start, partition_end) %}

    {# Marcar como running #}
    {% set update_running %}
        UPDATE BOOTCAMP_DB.OPS.BACKFILL_PROGRESS
        SET status = 'running', started_at = CURRENT_TIMESTAMP()
        WHERE backfill_id = '{{ backfill_id }}'
          AND model_name = '{{ model_name }}'
          AND partition_start = '{{ partition_start }}'
    {% endset %}

    {% do run_query(update_running) %}
    {{ log("Backfill iniciado: " ~ model_name ~ " [" ~ partition_start ~ " → " ~ partition_end ~ "]", info=true) }}

{% endmacro %}


{% macro complete_backfill_partition(model_name, backfill_id, partition_start, row_count) %}

    {% set update_success %}
        UPDATE BOOTCAMP_DB.OPS.BACKFILL_PROGRESS
        SET status = 'success',
            finished_at = CURRENT_TIMESTAMP(),
            row_count = {{ row_count }},
            duration_seconds = DATEDIFF('second', started_at, CURRENT_TIMESTAMP())
        WHERE backfill_id = '{{ backfill_id }}'
          AND model_name = '{{ model_name }}'
          AND partition_start = '{{ partition_start }}'
    {% endset %}

    {% do run_query(update_success) %}

{% endmacro %}
```

---

## Paso 5 — Script orquestador (15 min)

`scripts/run_backfill.sh`:

```bash
#!/bin/bash
set -e

BACKFILL_ID="backfill_revenue_2026_05"
MODEL="fct_events_daily"

echo "🚀 Iniciando backfill $BACKFILL_ID"

# 1. Subir el warehouse temporalmente
echo "📈 Escalando warehouse a LARGE..."
dbt run-operation alter_warehouse --args "{warehouse: BOOTCAMP_WH, size: LARGE}"

# 2. Obtener particiones pending
PARTITIONS=$(dbt show \
    --inline "SELECT partition_start, partition_end FROM BOOTCAMP_DB.OPS.BACKFILL_PROGRESS \
              WHERE backfill_id='$BACKFILL_ID' AND status IN ('pending', 'failed')" \
    --output json | jq -r '.[] | "\(.PARTITION_START),\(.PARTITION_END)"')

# 3. Ejecutar cada partición
for partition in $PARTITIONS; do
    START=$(echo $partition | cut -d',' -f1)
    END=$(echo $partition | cut -d',' -f2)

    echo "  ⚙️  Procesando [$START → $END]..."

    if dbt run --select $MODEL \
              --event-time-start "$START" \
              --event-time-end "$END" \
              --vars "{backfill_id: $BACKFILL_ID}" ; then
        echo "  ✅ Partición $START completada"
    else
        echo "  ❌ Partición $START FALLÓ — continuando con las demás"
        # Marcar como failed pero no detener el script
        dbt run-operation mark_partition_failed \
            --args "{backfill_id: $BACKFILL_ID, partition_start: $START}"
    fi
done

# 4. Bajar el warehouse
echo "📉 Volviendo a XSMALL..."
dbt run-operation alter_warehouse --args "{warehouse: BOOTCAMP_WH, size: XSMALL}"

# 5. Reporte final
echo "📊 Estado final:"
dbt show --inline "SELECT status, COUNT(*) AS particiones, SUM(row_count) AS filas \
                    FROM BOOTCAMP_DB.OPS.BACKFILL_PROGRESS \
                    WHERE backfill_id='$BACKFILL_ID' \
                    GROUP BY 1"
```

`macros/alter_warehouse.sql`:
```sql
{% macro alter_warehouse(warehouse, size) %}
    {% set sql %}
        ALTER WAREHOUSE {{ warehouse }} SET WAREHOUSE_SIZE = '{{ size }}'
    {% endset %}
    {% do run_query(sql) %}
    {{ log("Warehouse " ~ warehouse ~ " ahora es " ~ size, info=true) }}
{% endmacro %}
```

---

## Paso 6 — Paralelismo controlado (15 min) 🎯

Hasta aquí corres particiones secuenciales. Para paralelismo real, lanza N workers de dbt en paralelo, cada uno tomando una partición distinta.

**Versión simple** (en bash):

```bash
#!/bin/bash
# scripts/run_backfill_parallel.sh

BACKFILL_ID="backfill_revenue_2026_05"
MODEL="fct_events_daily"
MAX_PARALLEL=3  # 3 workers simultáneos

# Función worker
process_partition() {
    local start=$1
    local end=$2
    echo "[Worker] Procesando $start → $end"
    dbt run --select $MODEL \
            --event-time-start "$start" \
            --event-time-end "$end" \
            --vars "{backfill_id: $BACKFILL_ID}" \
            --target-path "target_${start}"  # 🎯 target paths separados
}

export -f process_partition

# Obtener particiones y procesarlas en paralelo
dbt show --inline "SELECT partition_start, partition_end FROM BOOTCAMP_DB.OPS.BACKFILL_PROGRESS \
                   WHERE backfill_id='$BACKFILL_ID' AND status='pending'" \
    --output csv | tail -n +2 | \
    xargs -n 2 -P $MAX_PARALLEL bash -c 'process_partition "$@"' _
```

> ⚠️ **Errores típicos de principiante:**
> - Lanzar paralelismo sin `--target-path` distinto por worker: dbt usa archivos temporales en `target/`. Si 3 workers escriben al mismo `target/`, corrompes manifests. Usa `--target-path` por worker.
> - No limitar el paralelismo: 20 workers paralelos saturan el warehouse y todas las queries van a la cola. 3-5 workers suele ser el sweet spot.
> - Olvidar que Snowflake tiene `MAX_CONCURRENCY_LEVEL` por warehouse. Si lo excedes, las queries se encolan.

> 💡 **Lo que solo se aprende con experiencia:**
> En Amazon usan **Airflow con dynamic task mapping**: una tarea por partición, paralelismo controlado por el pool de workers, retry automático con backoff exponencial, alertas en Slack si una partición falla N veces. Esto es lo siguiente a aprender después de dominar el patrón manual.

---

## Paso 7 — Recovery: el backfill falló al 70% (15 min)

Tu backfill llevaba 7 horas, procesó 35 de 50 particiones, y el warehouse se quedó sin créditos.

```sql
-- ¿Qué quedó pending o failed?
SELECT
    partition_start,
    partition_end,
    status,
    error_message
FROM BOOTCAMP_DB.OPS.BACKFILL_PROGRESS
WHERE backfill_id = 'backfill_revenue_2026_05'
  AND status IN ('pending', 'failed', 'running')  -- 'running' = se quedó colgado
ORDER BY partition_start;
```

```sql
-- Limpia los 'running' que se quedaron colgados (más de 1 hora sin terminar)
UPDATE BOOTCAMP_DB.OPS.BACKFILL_PROGRESS
SET status = 'failed',
    error_message = 'Timeout: stuck in running > 1h'
WHERE backfill_id = 'backfill_revenue_2026_05'
  AND status = 'running'
  AND DATEDIFF('hour', started_at, CURRENT_TIMESTAMP()) > 1;
```

Ahora vuelve a lanzar el orquestador. Como tu script filtra `WHERE status IN ('pending', 'failed')`, retomará exactamente desde donde quedaste.

---

## Paso 8 — Validación post-backfill (10 min)

Antes de marcar el backfill como exitoso, **valida**.

```sql
-- 1. Row count vs expected
WITH expected AS (
    SELECT
        DATE(event_timestamp) AS event_date,
        COUNT(*) AS expected_count
    FROM RAW.RAW_EVENTS_LARGE
    WHERE event_timestamp >= DATEADD(DAY, -90, CURRENT_DATE())
    GROUP BY 1
),
actual AS (
    SELECT
        event_date,
        SUM(event_count) AS actual_count
    FROM ANALYTICS.FCT_EVENTS_DAILY
    WHERE event_date >= DATEADD(DAY, -90, CURRENT_DATE())
    GROUP BY 1
)
SELECT
    COALESCE(e.event_date, a.event_date) AS event_date,
    e.expected_count,
    a.actual_count,
    a.actual_count - e.expected_count AS diff
FROM expected e
FULL OUTER JOIN actual a USING (event_date)
WHERE COALESCE(e.expected_count, 0) != COALESCE(a.actual_count, 0)
ORDER BY event_date;
```

Si esta query retorna filas, **algo no cuadra**. Investiga antes de declarar éxito.

```sql
-- 2. Comparar revenue total con números viejos (si guardaste un snapshot pre-backfill)
SELECT
    SUM(revenue_usd) AS new_revenue,
    'fct_events_daily_v2' AS source
FROM ANALYTICS.FCT_EVENTS_DAILY
UNION ALL
SELECT
    SUM(revenue_usd),
    'snapshot_pre_backfill'
FROM ANALYTICS_SNAPSHOTS.FCT_EVENTS_DAILY_20260520;
```

> 💡 **Lo que solo se aprende con experiencia:**
> SIEMPRE haz snapshot de la tabla antes de un backfill grande:
> ```sql
> CREATE TABLE ANALYTICS_SNAPSHOTS.FCT_EVENTS_DAILY_20260520
> CLONE ANALYTICS.FCT_EVENTS_DAILY;
> ```
> `CLONE` en Snowflake es **gratis** (zero-copy clone) e instantáneo. Si tu backfill produce números raros, puedes revertir con `CREATE OR REPLACE TABLE FCT_EVENTS_DAILY CLONE FCT_EVENTS_DAILY_20260520`.

---

## Paso 9 — Cost-aware backfill (10 min)

Antes de ejecutar, calcula el costo esperado:

```sql
-- Costo histórico promedio por partición
WITH partition_costs AS (
    SELECT
        DATE(start_time) AS day,
        AVG(credits_used_cloud_services * 2.0) AS avg_usd_per_run  -- $2/credit aprox
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE query_text ILIKE '%fct_events_daily%'
      AND start_time > DATEADD(MONTH, -1, CURRENT_TIMESTAMP())
    GROUP BY 1
)
SELECT
    AVG(avg_usd_per_run) AS avg_cost_per_partition,
    AVG(avg_usd_per_run) * 50 AS estimated_total_for_50_partitions
FROM partition_costs;
```

Si el estimado es $500 y tu budget mensual es $200, **no ejecutes**. Negocia primero.

---

## ✅ Checklist de salida

- [ ] Creaste `OPS.BACKFILL_PROGRESS` para tracking
- [ ] Macros de tracking (`run_backfill_partition`, `complete_backfill_partition`)
- [ ] Script orquestador con escalado dinámico de warehouse
- [ ] Probaste recovery (mata el script a la mitad y retómalo)
- [ ] Validaste row counts post-backfill
- [ ] Hiciste CLONE de tabla pre-backfill como backup
- [ ] Estimaste costo antes de ejecutar

---

## 🎓 Preguntas tipo entrevista senior

1. *"Cómo manejas un backfill de 5 años en una tabla con downstream BI 24/7 que NO puede tener gaps?"*
   → Backfill a una tabla shadow (`fct_orders_v2`). Validas. Swap atómico: `ALTER TABLE fct_orders RENAME TO fct_orders_old; ALTER TABLE fct_orders_v2 RENAME TO fct_orders`. Downtime = milisegundos.

2. *"Tu backfill genera 2x el storage temporal. ¿Qué haces si no tienes espacio?"*
   → Backfill en chunks, cada chunk reemplaza al viejo inmediatamente (no acumulas dos copias). O alquila storage temporal con Snowflake Cloud Services (es relativamente barato).

3. *"¿Cuándo NO hacer backfill y mejor recalcular forward?"*
   → Si el bug solo afecta períodos recientes (< 30 días), recalcula forward y deja una nota en docs. Si el bug es de un período concreto del pasado (ej: una semana), `--event-time-start/--end` puntual. Solo haz backfill total si los datos históricos van a un dashboard de finanzas auditable.

---

➡️ **Siguiente:** [Lab 13 — Multi-tenancy y governance](./lab_13_multitenancy_governance.md)
