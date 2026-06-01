# 🧪 Lab 10 — Microbatch: 10M de eventos sin romper el warehouse

**Nivel:** Avanzado 🔴🔴
**Tiempo estimado:** 120 minutos
**Dominios cubiertos:** dbt 1.9+ microbatch, event_time, batch_size, lookback, backfills puntuales, idempotencia
**Objetivo de negocio:** *"Procesamos 50M de eventos de clickstream al día. El modelo incremental tradicional ya no escala: tarda 4 horas, gasta 80 créditos diarios, y si falla a la mitad nadie sabe qué se reprocesó. Necesitamos algo más quirúrgico."*

---

## 🎯 Lo que vas a aprender

1. Por qué `incremental` tradicional tiene un techo de escalabilidad
2. La estrategia `microbatch` (dbt 1.9+): cada día/hora es una unidad atómica
3. `event_time`, `batch_size`, `lookback`, `begin`
4. Backfills puntuales sin tocar el modelo: `--event-time-start` / `--event-time-end`
5. Idempotencia real: correr el mismo día N veces produce el mismo resultado

---

## El dolor del incremental tradicional

Hasta ahora tu lógica incremental se veía así:

```sql
{% if is_incremental() %}
    WHERE event_timestamp > (SELECT MAX(event_timestamp) FROM {{ this }})
{% endif %}
```

Esto tiene **tres problemas serios a escala**:

| Problema | Consecuencia |
|----------|--------------|
| 1. `MAX(event_timestamp)` escanea el modelo destino completo | A 1B filas, esa query sola tarda minutos |
| 2. Si una fila late-arrives 2 días tarde, **nunca entra** | Reportes incompletos sin que nadie se entere |
| 3. Reprocesar un día específico requiere borrar + `--full-refresh` | Cualquier error = reprocesar TODO desde el principio |

**Microbatch resuelve los tres.**

---

## Paso 1 — Generar dataset masivo (10 min)

Si no lo corriste en el setup, ejecuta esto en Snowflake. Genera 10M de eventos con timestamps distribuidos en los últimos 90 días.

```sql
USE WAREHOUSE BOOTCAMP_WH;
USE DATABASE BOOTCAMP_DB;
USE SCHEMA RAW;

-- Subir el warehouse temporalmente para generar rápido
ALTER WAREHOUSE BOOTCAMP_WH SET WAREHOUSE_SIZE = 'MEDIUM';

CREATE OR REPLACE TABLE RAW_EVENTS_LARGE AS
SELECT
    UUID_STRING() AS event_id,
    'user_' || (UNIFORM(1, 100000, RANDOM())) AS user_id,
    'content_' || (UNIFORM(1, 5000, RANDOM())) AS content_id,
    ARRAY_CONSTRUCT('play_start','play_complete','pause','seek','add_to_list','rate')
        [UNIFORM(0, 5, RANDOM())]::STRING AS event_type,
    -- timestamps distribuidos en últimos 90 días con sesgo hacia días recientes
    DATEADD(SECOND,
        -UNIFORM(0, 90*24*3600, RANDOM()),
        CURRENT_TIMESTAMP()) AS event_timestamp,
    UNIFORM(1, 7200, RANDOM()) AS duration_seconds,
    ARRAY_CONSTRUCT('iOS','Android','Web','TV')
        [UNIFORM(0, 3, RANDOM())]::STRING AS device_type,
    CURRENT_TIMESTAMP() AS ingested_at
FROM TABLE(GENERATOR(ROWCOUNT => 10000000));

-- Volver a XSMALL para el resto del lab
ALTER WAREHOUSE BOOTCAMP_WH SET WAREHOUSE_SIZE = 'XSMALL';

SELECT COUNT(*) AS total,
       MIN(event_timestamp) AS desde,
       MAX(event_timestamp) AS hasta
FROM RAW_EVENTS_LARGE;
```

Deberías ver ~10M filas distribuidas en 90 días.

> ⚠️ **Errores típicos de principiante:**
> - Generar los 10M con XSMALL: tardará 20+ minutos. Usa MEDIUM solo para esta carga.
> - Olvidar bajar el warehouse después: te quema créditos sin que te des cuenta.

---

## Paso 2 — Source con event_time declarado (10 min)

En `models/staging/clickstream/_sources.yml`, agrega:

```yaml
sources:
  - name: raw_clickstream_large
    database: BOOTCAMP_DB
    schema: RAW
    tables:
      - name: raw_events_large
        # CLAVE: declarar event_time aquí
        config:
          event_time: event_timestamp
```

Esto le dice a dbt: *"cuando alguien quiera filtrar por tiempo desde esta source, usa esta columna"*.

---

## Paso 3 — Staging básico (5 min)

`models/staging/clickstream/stg_events_large.sql`:

```sql
{{ config(
    materialized='view'
) }}

SELECT
    event_id,
    user_id,
    content_id,
    event_type,
    event_timestamp,
    duration_seconds,
    device_type,
    ingested_at
FROM {{ source('raw_clickstream_large', 'raw_events_large') }}
```

---

## Paso 4 — El modelo microbatch (30 min) 🎯

`models/marts/clickstream/fct_events_daily.sql`:

```sql
{{ config(
    materialized='incremental',
    incremental_strategy='microbatch',
    event_time='event_date',
    batch_size='day',
    lookback=3,
    begin='2026-02-01',
    unique_key=['event_date', 'user_id', 'content_id', 'event_type'],
    on_schema_change='append_new_columns'
) }}

SELECT
    DATE(event_timestamp) AS event_date,
    user_id,
    content_id,
    event_type,
    device_type,
    COUNT(*) AS event_count,
    SUM(duration_seconds) AS total_duration_seconds,
    MIN(event_timestamp) AS first_event_at,
    MAX(event_timestamp) AS last_event_at,
    CURRENT_TIMESTAMP() AS dbt_processed_at
FROM {{ ref('stg_events_large') }}
GROUP BY 1, 2, 3, 4, 5
```

### Anatomía de cada parámetro

| Parámetro | Qué hace | Por qué importa |
|-----------|----------|-----------------|
| `incremental_strategy='microbatch'` | Activa el modo microbatch | En lugar de un `MERGE` gigante, hace N pequeños `INSERT OVERWRITE` por día |
| `event_time='event_date'` | Columna del **modelo** que define el tiempo | dbt la usa para particionar los batches |
| `batch_size='day'` | Cada batch = 1 día | Otras opciones: `hour`, `month`, `year` |
| `lookback=3` | Reprocesa los últimos 3 batches en cada run | Captura late-arriving sin pedir explícitamente backfill |
| `begin='2026-02-01'` | Punto de arranque histórico | Primer run procesa desde aquí hasta hoy |
| `unique_key` | Identifica una fila única dentro de un batch | Esencial para idempotencia |

### El mecanismo bajo el capó

Cuando corres `dbt run --select fct_events_daily`, dbt:

1. Calcula qué batches faltan: `(MAX(event_date) - lookback) → hoy`
2. **Para cada batch**, ejecuta un SQL que filtra `WHERE event_date BETWEEN '2026-05-25' AND '2026-05-25'`
3. Hace `DELETE FROM target WHERE event_date = '2026-05-25'` + `INSERT`
4. Si un batch falla, los otros siguen. dbt te dice cuáles fallaron.

> 💡 **Lo que solo se aprende con experiencia:**
> El `lookback=3` es tu seguro contra late-arriving. Si dejas `lookback=0`, datos que lleguen tarde nunca entrarán. Si pones `lookback=30`, gastas créditos reprocesando cosas que probablemente no cambiaron. El sweet spot suele ser 3-7 días para clickstream, 1-2 para datos transaccionales.

---

## Paso 5 — Primera ejecución (15 min)

```bash
dbt run --select fct_events_daily
```

Observa los logs. Verás algo así:

```
Running 90 batches of model fct_events_daily
  Batch 1/90 [2026-02-01]: 110,234 rows in 4.2s
  Batch 2/90 [2026-02-02]: 108,901 rows in 3.9s
  ...
```

Cada día es una transacción independiente. Si falla el batch 47, los otros 89 ya están persistidos.

### Compáralo con `--full-refresh`

```bash
dbt run --select fct_events_daily --full-refresh
```

Si pones esto, dbt **reprocesa TODOS los batches desde `begin`**. En producción es algo que casi nunca quieres hacer en un microbatch; existen mejores alternativas.

---

## Paso 6 — Backfill quirúrgico (20 min) 🎯

Imagina que descubres que el día **2026-04-15** tuvo un bug en el pipeline upstream y los eventos llegaron mal. Necesitas reprocesar SOLO ese día sin tocar nada más.

**Antes (incremental tradicional):**
```sql
DELETE FROM fct_events_daily WHERE event_date = '2026-04-15';
-- luego rezar y correr dbt run, esperando que el WHERE incremental capture esos eventos
```

**Con microbatch:**
```bash
dbt run --select fct_events_daily \
        --event-time-start "2026-04-15" \
        --event-time-end "2026-04-16"
```

Eso es todo. dbt:
1. Identifica el batch del 2026-04-15
2. Lo borra
3. Lo regenera con la lógica actual
4. Otros batches no se tocan

### Backfill de un rango más grande

```bash
# Reprocesar todo abril
dbt run --select fct_events_daily \
        --event-time-start "2026-04-01" \
        --event-time-end "2026-05-01"
```

> ⚠️ **Errores típicos de principiante:**
> - Pensar que `--event-time-end` es inclusivo: NO lo es. Es exclusivo (`<`, no `<=`). Para procesar abril completo, end = `2026-05-01`, no `2026-04-30`.
> - Hacer backfill sin avisar al equipo: si tienes downstream BI dashboards, durante unos segundos esos datos no existirán. Usa transacciones o coordina ventanas de mantenimiento.

---

## Paso 7 — Probar la idempotencia (10 min)

Correr el mismo día N veces debe producir el mismo resultado:

```bash
# Corre 3 veces seguidas
dbt run --select fct_events_daily --event-time-start "2026-04-15" --event-time-end "2026-04-16"
dbt run --select fct_events_daily --event-time-start "2026-04-15" --event-time-end "2026-04-16"
dbt run --select fct_events_daily --event-time-start "2026-04-15" --event-time-end "2026-04-16"
```

Verifica:
```sql
SELECT event_date, COUNT(*)
FROM fct_events_daily
WHERE event_date = '2026-04-15'
GROUP BY 1;
```

El conteo debe ser idéntico cada vez. Si crece, tienes un bug en tu `unique_key`.

---

## Paso 8 — Comparar costos (10 min)

Vamos a comparar lo que costaría procesar los mismos 10M con incremental tradicional vs microbatch.

```sql
-- Costo de tu run de microbatch
SELECT
    query_text,
    execution_time / 1000 AS seconds,
    credits_used_cloud_services,
    rows_produced
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_text ILIKE '%fct_events_daily%'
  AND start_time > DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;
```

> 💡 **Lo que solo se aprende con experiencia:**
> En producción real, microbatch suele ser **2-5x más barato** que incremental tradicional a partir de ~50M filas, porque:
> 1. No escaneas el destino para encontrar `MAX(timestamp)`
> 2. Cada batch es pequeño → menos memoria → puedes usar warehouse más chico
> 3. Si solo cambian 3 días de los últimos 90, solo procesas 3 días

---

## Paso 9 — Estrategia híbrida: microbatch + late-arriving del Lab 8 (15 min)

Ahora combina conceptos: simula que llegan eventos viejos.

```sql
INSERT INTO RAW_EVENTS_LARGE
SELECT
    UUID_STRING() AS event_id,
    'user_late_arrival',
    'content_1',
    'play_start',
    DATEADD(DAY, -2, CURRENT_TIMESTAMP()) AS event_timestamp,  -- 2 días atrás
    300,
    'iOS',
    CURRENT_TIMESTAMP() AS ingested_at;
```

Ejecuta:
```bash
dbt run --select fct_events_daily
```

Como tu `lookback=3`, esto reprocesa los últimos 3 batches automáticamente y captura el evento late-arrived. **Sin que tú hayas tenido que hacer un backfill manual.**

> 💡 **Esto es lo que hace Netflix:**
> Sus pipelines de telemetría tienen `lookback=7` porque los eventos de TVs en regiones con mala conexión pueden llegar hasta una semana tarde. El costo extra de reprocesar 7 días es mínimo comparado con tener métricas incorrectas.

---

## ✅ Checklist de salida

Antes de pasar al Lab 11, asegúrate de:

- [ ] Generaste los 10M eventos en `RAW_EVENTS_LARGE`
- [ ] Tu modelo `fct_events_daily` corre con microbatch
- [ ] Hiciste un backfill puntual con `--event-time-start/--event-time-end`
- [ ] Verificaste idempotencia corriendo 3x el mismo batch
- [ ] Entiendes diferencia entre `lookback` (automático) y `--event-time-start` (manual)

---

## 🎓 Preguntas tipo entrevista senior

1. *"¿En qué caso usarías incremental tradicional en lugar de microbatch?"*
   → Cuando los datos no tienen una columna temporal natural (ej: snapshot diario de un catálogo) o cuando el volumen es bajo (< 1M filas) y la complejidad de microbatch no se justifica.

2. *"¿Qué pasa si tu source cambia el schema entre dos batches?"*
   → Con `on_schema_change='append_new_columns'` dbt agrega columnas nuevas pero no toca las viejas. Si eliminas una columna upstream, los batches viejos siguen teniéndola con NULL.

3. *"¿Por qué `unique_key` debe incluir el grano temporal?"*
   → Porque cada batch es atómico: dbt borra el día completo antes de reinsertar. Si `unique_key` no incluye `event_date`, dbt no sabe qué filas son del batch y puede duplicar al reinsertar.

---

➡️ **Siguiente:** [Lab 11 — Data Quality Framework completo](./lab_11_data_quality_framework.md)
