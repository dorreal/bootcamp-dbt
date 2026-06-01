# 🧪 Lab 07 — Snapshots y SCD2 a escala (caso Netflix)

**Nivel:** Intermedio-Avanzado 🟠
**Tiempo estimado:** 2 horas
**Dominios cubiertos:** Snapshots, SCD Type 2, strategy timestamp vs check, snapshot meta-fields
**Objetivo de negocio:** "Necesitamos saber, en cualquier punto en el tiempo, cuál era el plan de suscripción de un usuario. Hoy un usuario es Premium, pero hace 6 meses era Basic. Los reports de revenue deben respetar el plan que tenía CUANDO ocurrió el evento, no el actual."

---

## 🎯 Lo que vas a aprender

1. Qué es un SCD Type 2 y por qué casi siempre lo necesitas
2. Snapshots con strategy `timestamp` vs `check`
3. Joins "as-of" (point-in-time joins)
4. Cómo escala a millones de usuarios y por qué un snapshot mal hecho cuesta caro

## El problema que resuelve

Imagina esto en Netflix:
- En enero de 2026, Julio era usuario **Basic** ($8/mes).
- En marzo de 2026, hace upgrade a **Premium** ($18/mes).
- En mayo de 2026, vio un episodio.

¿Cuánto vale ese view para Netflix? Depende del plan vigente EN MARZO O EN MAYO?

Si solo guardas el plan actual, **pierdes la historia**. Toda la revenue analysis se rompe.

**SCD Type 2** es la solución: cada vez que cambia un atributo, se crea una nueva fila con `valid_from` / `valid_to`.

---

## Paso 1 — El input: tabla que cambia (15 min)

Vamos a simular que `raw_users` se actualiza con el plan actual:

```sql
-- En Snowflake, simulamos un cambio:
USE ROLE TRANSFORMER;
USE WAREHOUSE BOOTCAMP_WH;

-- Agregar columna updated_at si no existe (es lo más común en producción)
ALTER TABLE BOOTCAMP_DB.RAW.RAW_USERS
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP_NTZ;

UPDATE BOOTCAMP_DB.RAW.RAW_USERS
SET updated_at = current_timestamp;
```

> 💡 **Lo realista:** En producción, raw_users casi siempre tiene `updated_at` (la herramienta de ETL la pone). Si NO la tiene, vas con `check` strategy (más adelante).

---

## Paso 2 — Snapshot con strategy `timestamp` (20 min)

`snapshots/users_snapshot.sql`:

```sql
{% snapshot users_snapshot %}

{{
  config(
    target_schema='snapshots',
    target_database='BOOTCAMP_DB',
    unique_key='user_id',
    strategy='timestamp',
    updated_at='updated_at',
    invalidate_hard_deletes=true
  )
}}

select
    user_id,
    plan,
    primary_device,
    country,
    updated_at
from {{ source('raw_clickstream', 'raw_users') }}

{% endsnapshot %}
```

**Corre el snapshot la primera vez:**

```bash
dbt snapshot
```

dbt crea `BOOTCAMP_DB.snapshots.users_snapshot` con estas columnas:

| user_id | plan | ... | dbt_scd_id | dbt_updated_at | dbt_valid_from | dbt_valid_to |
|---|---|---|---|---|---|---|
| u_00001 | basic | ... | hash | 2026-05-28 ... | 2026-05-28 ... | NULL |

**`dbt_valid_to = NULL` significa "es la fila vigente actual"**.

---

## Paso 3 — Simular un cambio y volver a snapshotear (20 min)

```sql
-- Julio hace upgrade a premium
UPDATE BOOTCAMP_DB.RAW.RAW_USERS
SET plan = 'premium', updated_at = current_timestamp
WHERE user_id = 'u_00001';

-- Y un cliente cambia de país (mudanza)
UPDATE BOOTCAMP_DB.RAW.RAW_USERS
SET country = 'US', updated_at = current_timestamp
WHERE user_id = 'u_00002';
```

```bash
dbt snapshot
```

Verifica:

```sql
SELECT user_id, plan, country, dbt_valid_from, dbt_valid_to
FROM BOOTCAMP_DB.snapshots.users_snapshot
WHERE user_id IN ('u_00001', 'u_00002')
ORDER BY user_id, dbt_valid_from;
```

Verás 2 filas por user_id: la antigua con `dbt_valid_to` lleno (cerrada), la nueva con `dbt_valid_to = NULL` (vigente).

---

## Paso 4 — Strategy `check` (cuando NO hay updated_at) (20 min)

A veces el source no tiene timestamp. Entonces dbt compara columnas:

```sql
{% snapshot users_snapshot_check %}

{{
  config(
    target_schema='snapshots',
    unique_key='user_id',
    strategy='check',
    check_cols=['plan', 'country']     -- ⬅️ las columnas a vigilar
  )
}}

select
    user_id,
    plan,
    primary_device,
    country
from {{ source('raw_clickstream', 'raw_users') }}

{% endsnapshot %}
```

**Diferencias:**

| | timestamp | check |
|---|---|---|
| Requiere updated_at en source | ✅ Sí | ❌ No |
| Performance | Rápido (compara fechas) | Más lento (compara N columnas) |
| Detecta cambios en cualquier columna | Solo si updated_at se actualiza | Solo en check_cols |
| Caso de uso | Fuentes modernas con CDC | Fuentes legacy / files |

> ⚠️ **Error de principiante #1:** Usar `check_cols=['*']` para "vigilar todas". Esto compara TODAS las columnas, incluyendo timestamps de carga que cambian a cada minuto, generando una fila nueva cada vez. **Listá explícitamente solo las columnas de negocio que importan.**

---

## Paso 5 — Point-in-time join (as-of join) (30 min)

Acá viene el oro: usar el snapshot para enriquecer eventos con el plan vigente EN ESE MOMENTO.

`models/marts/clickstream/fct_events_with_plan.sql`:

```sql
{{
  config(
    materialized='incremental',
    unique_key='event_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
  )
}}

with events as (
    select * from {{ ref('stg_events') }}
    {% if is_incremental() %}
    where event_time >= (select dateadd('day', -3, max(event_time)) from {{ this }})
    {% endif %}
),

user_history as (
    select
        user_id,
        plan,
        country,
        dbt_valid_from,
        coalesce(dbt_valid_to, '9999-12-31'::timestamp) as dbt_valid_to
    from {{ ref('users_snapshot') }}
)

select
    e.event_id,
    e.event_time,
    e.user_id,
    e.content_id,
    e.event_type,

    -- Plan vigente CUANDO ocurrió el evento (no el actual)
    h.plan         as plan_at_event,
    h.country      as country_at_event,

    -- Flag para debug
    case when h.user_id is null then 'no_history' else 'matched' end as match_status

from events e
left join user_history h
    on e.user_id = h.user_id
    and e.event_time >= h.dbt_valid_from
    and e.event_time <  h.dbt_valid_to
```

> 💡 **El truco del `9999-12-31`:** dbt deja `dbt_valid_to` como NULL para la fila vigente. Pero en un join, `event_time < NULL` siempre es NULL (no true). Reemplazar NULL por `9999-12-31` hace que la fila vigente "atrape" todos los eventos futuros.

> ⚠️ **Error de principiante #2:** `BETWEEN dbt_valid_from AND dbt_valid_to`. Esto incluye ambos extremos, causando filas duplicadas en el punto exacto del cambio. **Siempre usa `>= valid_from AND < valid_to`** (semi-abierto).

---

## Paso 6 — Test de no duplicación tras as-of join (10 min)

```yaml
- name: fct_events_with_plan
  description: "Eventos enriquecidos con el plan vigente cuando ocurrió el evento (SCD2 point-in-time)"
  columns:
    - name: event_id
      tests:
        - unique           # ⬅️ Crítico: si el as-of join está mal, duplica
        - not_null
    - name: plan_at_event
      tests:
        - accepted_values:
            values: ['free', 'basic', 'standard', 'premium']
            config:
              severity: warn   # eventos sin historial caen como NULL
```

Si `event_id` no es único, el as-of join está mal. **Debug:**

```sql
SELECT event_id, COUNT(*)
FROM fct_events_with_plan
GROUP BY 1 HAVING COUNT(*) > 1;
```

Si hay duplicados, casi seguro tu condición de fechas está mal.

---

## Paso 7 — Performance a escala (15 min)

Con 50M de eventos y 1M de usuarios con histórico SCD2, el as-of join puede ser lento. **Tres optimizaciones:**

### Opción A — `cluster by` en el snapshot

```sql
{{
  config(
    target_schema='snapshots',
    cluster_by=['user_id', 'dbt_valid_from'],
    ...
  )
}}
```

### Opción B — Reducir la cardinalidad del histórico

Si el snapshot tiene 5M filas pero solo 1M user_ids únicos, el join procesa todo. **Crea un modelo derivado solo con el histórico activo en el rango de eventos:**

```sql
with active_history as (
    select * from {{ ref('users_snapshot') }}
    where dbt_valid_to is null
       or dbt_valid_to >= (select min(event_time) from {{ ref('stg_events') }})
)
```

### Opción C — Cambiar el modelo a microbatch (lo veremos en Lab 10)

---

## 🧠 Lo que solo se aprende con experiencia

1. **Snapshots se ejecutan ANTES del run.** El orden es `dbt seed → dbt snapshot → dbt run`. Si haces solo `dbt run`, los snapshots NO se actualizan, y tu modelo SCD2 quedará desactualizado. `dbt build` los corre todos en orden.

2. **No borres jamás un snapshot por accidente.** El histórico está SOLO ahí. No hay forma de regenerarlo: si lo borras, perdiste 6 meses de cambios. **Backups del schema `snapshots` deben ser prioridad #1.**

3. **`invalidate_hard_deletes=true` es delicado.** Si activado, cuando un user_id desaparece del source, dbt marca su fila vigente como cerrada (con `valid_to = current_timestamp`). Útil si los DELETEs son intencionales. **Peligroso si un día tu source pierde datos por error**: marcarías a TODOS como borrados.

4. **El "as-of join" es el patrón más caro del data engineering.** Para 100M eventos × 10M users con snapshot, puede tardar horas. Si tu warehouse pequeño no aguanta, las soluciones son:
   - Particionar por fecha y hacer microbatch
   - Pre-calcular un "user_snapshot_daily" (1 fila por user-día)
   - Mover a Snowflake Streams + Tasks (CDC nativo)

5. **No todos los atributos necesitan SCD2.** Solo los que afectan reportes históricos. Email, teléfono, contraseña → no necesitan SCD2 (nadie reportea "revenue por email del 2023"). Plan, tier, country, segment → sí. Pregúntate: "¿alguien va a hacer revenue por este atributo?"

---

## ✅ Checklist Lab 07

- [ ] Snapshot con strategy `timestamp` corrido al menos 2 veces
- [ ] Probado un cambio en source y verificado que SCD2 lo capturó
- [ ] As-of join funcionando con `event_id` único
- [ ] Entiendes la diferencia entre `timestamp` y `check`
- [ ] Documentaste qué atributos SÍ necesitan SCD2 en tu negocio

---

## 🔜 Próximo lab

**Lab 08 — Late-arriving facts y reconciliación.** El problema clásico: transacciones que llegan días después de ocurrir. ¿Cómo las absorbes sin reprocesar todo?
