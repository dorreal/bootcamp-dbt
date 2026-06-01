# 🧪 Lab 05 — Materializaciones a fondo: midiendo en producción

**Nivel:** Intermedio 🟡
**Tiempo estimado:** 90 minutos
**Dominios cubiertos:** view vs table vs incremental, query profile, costos
**Objetivo de negocio:** "Nuestro pipeline está tardando 40 minutos cada noche. El CFO pregunta por qué Snowflake nos cuesta tanto. ¿Qué optimizamos?"

---

## 🎯 Lo que vas a aprender

1. Medir el tiempo y costo de cada materialización (no solo memorizar la teoría)
2. Leer el query profile de Snowflake
3. Convertir un modelo incrementalmente y validar correctness
4. Calcular el ahorro real en créditos de Snowflake

## Setup previo

Necesitas datos a escala. Si no lo has hecho, corre `generators/03_synthetic_data_at_scale.sql` para crear `RAW_EVENTS_LARGE` (10M filas).

---

## Paso 1 — Modelo base como `view` (15 min)

`models/staging/clickstream/stg_events_large.sql`:

```sql
{{ config(materialized='view') }}

select
    event_id,
    event_time,
    user_id,
    content_id,
    event_type,
    playback_position_sec,
    date_trunc('day', event_time)        as event_date,
    extract(hour from event_time)        as event_hour
from {{ source('raw_clickstream', 'raw_events_large') }}
```

`models/marts/clickstream/fct_daily_engagement.sql` (versión `view`):

```sql
{{ config(materialized='view') }}

select
    event_date,
    user_id,
    count(*)                                                       as total_events,
    count(case when event_type = 'play_start' then 1 end)          as plays_started,
    count(case when event_type = 'play_complete' then 1 end)       as plays_completed,
    sum(playback_position_sec)                                     as total_playback_sec
from {{ ref('stg_events_large') }}
group by event_date, user_id
```

**Mide:**

```bash
dbt run -s fct_daily_engagement
```

Anota el tiempo. Luego en Snowflake:

```sql
-- consulta la view: este es el costo REAL de cada lectura
select count(*), sum(total_events)
from BOOTCAMP_DB.DEV_JULIO_MARTS.FCT_DAILY_ENGAGEMENT;

-- ve el query profile (en Snowsight: Query History → tu query → Query Profile)
```

> 🧠 **Insight:** Como view, `dbt run` toma ~1 segundo (solo crea la definición). Pero CADA consulta a la view ejecuta el `GROUP BY` sobre los 10M de filas. Si 20 dashboards la usan, ejecutas el group 20 veces al día.

---

## Paso 2 — Cambiar a `table` (15 min)

Modifica el modelo:

```sql
{{ config(materialized='table') }}
```

```bash
dbt run -s fct_daily_engagement
```

**Mide:** ahora `dbt run` tarda más (~20-40s), porque ejecuta el group y guarda el resultado. Pero la consulta posterior es instantánea.

**Trade-off:**

| | view | table |
|---|---|---|
| `dbt run` time | <1s | ~30s |
| Query response | ~15s (cada vez) | <1s |
| Storage | 0 | ~10MB |
| Fresh data? | Sí (siempre) | Solo tras el último run |

**Cuándo gana table:** muchas lecturas por una sola escritura (caso clásico de dashboards).

---

## Paso 3 — Convertir a `incremental` (25 min)

El problema: `table` reconstruye 10M de filas cada noche. Si solo agregaste 50k filas hoy, estás reprocesando todo lo demás sin razón.

```sql
{{
  config(
    materialized='incremental',
    unique_key=['event_date', 'user_id'],
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
  )
}}

select
    event_date,
    user_id,
    count(*)                                                       as total_events,
    count(case when event_type = 'play_start' then 1 end)          as plays_started,
    count(case when event_type = 'play_complete' then 1 end)       as plays_completed,
    sum(playback_position_sec)                                     as total_playback_sec
from {{ ref('stg_events_large') }}

{% if is_incremental() %}
  -- Ventana de seguridad: procesa hoy + 3 días hacia atrás para late-arriving
  where event_date >= (
      select dateadd('day', -3, max(event_date)) from {{ this }}
  )
{% endif %}

group by event_date, user_id
```

**Primera corrida** (full refresh, igual que table):

```bash
dbt run -s fct_daily_engagement --full-refresh
```

**Segunda corrida** (incremental — esto es lo nuevo):

```bash
dbt run -s fct_daily_engagement
```

Compara tiempos. La segunda corrida debería ser ~10-50x más rápida.

> ⚠️ **Error de principiante #1:** Definir `unique_key` solo como `['user_id']`. Como el modelo es por (event_date, user_id), tienes múltiples filas por user_id (una por día). Si `unique_key = ['user_id']`, el merge mantiene solo UNA fila por usuario y borra el histórico. **El unique_key debe ser la clave del grain del modelo.**

> ⚠️ **Error de principiante #2:** Usar `>=` en el filtro incremental sin lookback. `where event_date >= (select max(event_date) from {{ this }})` deja huecos si llegan eventos de fechas anteriores. **Siempre incluye una ventana de seguridad** (3-7 días según el caso).

---

## Paso 4 — Validar correctness del incremental (15 min)

El miedo de todo Senior: ¿mi modelo incremental tiene los MISMOS datos que la versión `table`? Si no, el incremental introduce un bug silencioso.

Usa el package `audit_helper`:

```sql
-- analyses/audit_fct_daily_engagement.sql
{% set old_relation = ref('fct_daily_engagement') %}

-- Crea una versión table fresh para comparar
{% set new_query %}
select
    event_date,
    user_id,
    count(*) as total_events,
    count(case when event_type = 'play_start' then 1 end) as plays_started,
    count(case when event_type = 'play_complete' then 1 end) as plays_completed,
    sum(playback_position_sec) as total_playback_sec
from {{ ref('stg_events_large') }}
group by event_date, user_id
{% endset %}

{{ audit_helper.compare_queries(
    a_query="select * from " ~ old_relation,
    b_query=new_query,
    primary_key="event_date || '|' || user_id"
) }}
```

Compílalo (no ejecutes, solo genera el SQL):

```bash
dbt compile -s audit_fct_daily_engagement
```

Copia el SQL de `target/compiled/analyses/audit_fct_daily_engagement.sql` y córrelo en Snowflake. Debería darte 100% de match. Si no, tienes un bug.

> 💡 **Patrón Senior:** Todo modelo que conviertes a incremental debe ir acompañado de un audit query. Ejecútalo el primer día y luego cada vez que toques la lógica.

---

## Paso 5 — Calcular el ahorro real en créditos (20 min)

Snowflake cobra por **segundos de cómputo × tamaño del warehouse**.

| Tamaño | Créditos por hora |
|---|---|
| XS | 1 |
| S | 2 |
| M | 4 |
| L | 8 |
| XL | 16 |

Si tu modelo era `table` y tardaba 60s en XS, costaba: `60/3600 × 1 = 0.017 créditos` por corrida.
Si lo conviertes a `incremental` y tarda 5s, cuesta: `5/3600 × 1 = 0.0014 créditos`.

Multiplica por 365 corridas/año y por el número de modelos pesados, y verás miles de dólares de ahorro.

**Consulta tus costos reales:**

```sql
-- En Snowflake (ROLE ACCOUNTADMIN):
SELECT
    query_text,
    warehouse_name,
    execution_time / 1000 AS seconds,
    credits_used_cloud_services + 0 AS credits  -- aproximado
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_text ILIKE '%fct_daily_engagement%'
  AND start_time >= dateadd('day', -7, current_timestamp)
ORDER BY start_time DESC
LIMIT 20;
```

---

## 🧠 Lo que solo se aprende con experiencia

1. **`view` rara vez es óptima en marts.** Pero NO porque sea "lenta" — depende del patrón. Si una view se consulta 1 vez al día por un job batch, gana. Si se consulta 1000 veces al día por dashboards, table o incremental ganan. **Medí el ratio reads/writes antes de decidir.**

2. **Incremental tiene un costo escondido: la complejidad mental.** Cualquier developer que vaya a modificar tu modelo necesita entender:
   - ¿Qué hace `is_incremental()`?
   - ¿Qué pasa con `--full-refresh`?
   - ¿Hay lookback? ¿De cuántos días?
   - ¿`unique_key` es correcto?

   Si nadie más entiende tu modelo, eres un cuello de botella. **Documenta el incremental en el `description` del modelo.**

3. **`on_schema_change` salva carreras.** Imagina: agregas una columna `genre` al modelo. Sin `on_schema_change`, Snowflake falla con "column count mismatch" y nadie sabe por qué. Con `on_schema_change: append_new_columns`, dbt agrega la columna automáticamente. Es free, úsalo siempre.

4. **`merge` vs `delete+insert` vs `append`.** El default `merge` es seguro pero más lento (Snowflake hace UPDATE + INSERT). Si SABES que solo insertas filas nuevas (logs, events), `append` es 3-5x más rápido. Si tu warehouse no soporta merge bien (Redshift histórico), `delete+insert` es alternativa. **Default seguro: merge. Override si midiste un problema.**

5. **El query profile es tu mejor amigo.** En Snowsight: ejecuta tu modelo, ve a Query History, abre tu query, pestaña "Query Profile". Verás un grafo donde cada paso muestra el tiempo, las filas y el "bytes spilled to local disk". Si ves spilling, tu warehouse es muy chico para esa query. Si ves "TableScan" tomando 90% del tiempo, falta clustering. **Aprende a leer el query profile; es lo que diferencia un Junior de un Senior.**

---

## ✅ Checklist de salida del Lab 05

- [ ] Mediste `dbt run` y query time para las 3 materializaciones
- [ ] Versión incremental con `unique_key` correcto y lookback de 3 días
- [ ] Validaste correctness con `audit_helper.compare_queries`
- [ ] Calculaste el costo en créditos de cada versión
- [ ] Leíste un query profile completo en Snowsight

---

## 🔜 Próximo lab

**Lab 06 — `dim_date` y dimensiones reutilizables.** Construirás la dimensión de fechas más usada en BI (y por qué cada proyecto la necesita).
