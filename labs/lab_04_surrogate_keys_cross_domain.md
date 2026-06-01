# 🧪 Lab 04 — Surrogate keys y joins entre dominios

**Nivel:** Intermedio 🟡
**Tiempo estimado:** 90 minutos
**Dominios cubiertos:** Surrogate keys, identity resolution, joins multi-fuente
**Objetivo de negocio:** "Combinar datos de ecommerce y clickstream para responder: '¿qué contenido ve un cliente ANTES de comprar?'"

---

## 🎯 Lo que vas a aprender

1. Por qué necesitas surrogate keys (claves sustitutas) en marts
2. Cómo resolver identidades entre sistemas que no comparten ID
3. Usar `dbt_utils.generate_surrogate_key()` correctamente
4. Tu primer join cross-domain con fallbacks

---

## El problema real

En el mundo real, ecommerce tiene `customer_id` (entero) y clickstream tiene `user_id` (`u_00001`). **No hay una llave compartida**. ¿Cómo unes a un cliente con su comportamiento de visualización?

**Soluciones típicas:**
1. Una tabla de mapeo `user_id ↔ customer_id` (mantenida por el equipo de identity).
2. Match por email (si ambos sistemas lo tienen).
3. Match probabilístico (device fingerprinting, IP, etc.).

Para este lab simularemos la solución 1 con un seed.

---

## Paso 1 — Crear el mapping de identidad (10 min)

`seeds/identity_map.csv`:

```csv
user_id,customer_id,confidence
u_00001,1,high
u_00002,2,high
u_00003,3,high
u_00010,15,medium
u_00050,50,high
u_00100,100,high
```

Solo mapeamos algunos casos (en producción cubrirías más). Carga:

```bash
dbt seed --select identity_map
```

---

## Paso 2 — Surrogate keys en staging clickstream (20 min)

`models/staging/clickstream/stg_users.sql`:

```sql
{{ config(materialized='view') }}

select
    -- Surrogate key consistente (hash determinístico)
    {{ dbt_utils.generate_surrogate_key(['user_id']) }} as user_sk,

    -- Natural key (la original)
    user_id,
    plan,
    primary_device,
    signup_date,
    country
from {{ source('raw_clickstream', 'raw_users') }}
```

`models/staging/clickstream/stg_events.sql`:

```sql
{{ config(materialized='view') }}

select
    {{ dbt_utils.generate_surrogate_key(['event_id']) }}   as event_sk,
    {{ dbt_utils.generate_surrogate_key(['user_id'])  }}   as user_sk,
    {{ dbt_utils.generate_surrogate_key(['content_id']) }} as content_sk,
    event_id,
    event_time,
    user_id,
    content_id,
    event_type,
    playback_position_sec
from {{ source('raw_clickstream', 'raw_events') }}
-- Filtrar duplicados y eventos del futuro (los inyectamos en los seeds)
qualify row_number() over (partition by event_id order by event_time desc) = 1
   and event_time <= current_timestamp
```

> 💡 **`qualify` es de Snowflake/Redshift/BigQuery.** Es como un `where` que aplica a window functions, sin necesidad de un CTE extra. En Postgres tendrías que usar un CTE con `row_number()`. Memorízalo, es de las features más útiles de Snowflake.

---

## Paso 3 — Modelo de identity resolution (20 min)

`models/intermediate/int_user_identity_resolved.sql`:

```sql
{{ config(materialized='ephemeral') }}

with users as (
    select * from {{ ref('stg_users') }}
),

mapping as (
    select * from {{ ref('identity_map') }}
)

select
    u.user_sk,
    u.user_id,
    u.plan,
    u.primary_device,
    u.country,

    -- Resolución de identidad con fallback
    m.customer_id                                          as matched_customer_id,
    coalesce(m.confidence, 'no_match')                     as match_confidence,
    case
        when m.customer_id is not null then 'identified'
        else                                'anonymous'
    end                                                    as identity_status
from users u
left join mapping m on u.user_id = m.user_id
```

---

## Paso 4 — Mart cross-domain: comportamiento pre-compra (25 min)

Pregunta de negocio: para cada orden, ¿qué contenido vio el cliente en los 7 días previos?

`models/marts/clickstream/fct_pre_purchase_behavior.sql`:

```sql
{{ config(materialized='table') }}

with orders as (
    select
        order_id,
        customer_id,
        order_date,
        total_paid_usd
    from {{ ref('fct_orders') }}
    where customer_id is not null
),

events_with_customer as (
    select
        e.event_id,
        e.event_time,
        e.content_id,
        e.event_type,
        i.matched_customer_id as customer_id
    from {{ ref('stg_events') }} e
    inner join {{ ref('int_user_identity_resolved') }} i
        on e.user_sk = i.user_sk
    where i.matched_customer_id is not null
      and e.event_type = 'play_complete'   -- solo cuenta lo que terminó de ver
),

joined as (
    select
        o.order_id,
        o.customer_id,
        o.order_date,
        o.total_paid_usd,
        e.event_id,
        e.event_time,
        e.content_id,
        datediff('day', e.event_time, o.order_date) as days_before_order
    from orders o
    inner join events_with_customer e
        on o.customer_id = e.customer_id
        and e.event_time < o.order_date
        and e.event_time >= dateadd('day', -7, o.order_date)
)

select
    {{ dbt_utils.generate_surrogate_key(['order_id', 'event_id']) }} as fact_sk,
    order_id,
    customer_id,
    order_date,
    total_paid_usd,
    content_id,
    event_time,
    days_before_order,
    current_timestamp as dbt_loaded_at
from joined
```

> ⚠️ **Error de principiante #1:** Hacer el join `orders ↔ events` sin filtrar `e.event_time < o.order_date`. Acabas contando eventos de DESPUÉS de la compra, lo que invalida el análisis ("pre-compra"). Los filtros temporales en joins son fáciles de olvidar y caros de detectar.

> ⚠️ **Error de principiante #2:** `INNER JOIN` cuando deberías hacer `LEFT JOIN`. En este caso usamos inner a propósito (solo nos interesan órdenes CON eventos previos). Pero si tu pregunta de negocio es "para CADA orden, ¿cuántos eventos previos hubo, incluyendo cero?", debe ser LEFT JOIN y cuentas con `count_if`. **Antes de escribir el JOIN, escribe en español la pregunta exacta.**

---

## Paso 5 — Validar con tests cross-domain (15 min)

```yaml
# models/marts/clickstream/_models.yml
version: 2

models:
  - name: fct_pre_purchase_behavior
    description: |
      Hechos de eventos de visualización dentro de los 7 días previos a una compra.
      **Granularidad:** 1 fila por par (orden, evento_pre_compra).
      Una orden puede tener N filas (uno por cada evento previo).
    columns:
      - name: fact_sk
        description: "Surrogate key del par (orden, evento)"
        tests:
          - unique
          - not_null
      - name: days_before_order
        tests:
          - dbt_utils.expression_is_true:
              expression: "between 0 and 7"
      - name: order_id
        tests:
          - relationships:
              to: ref('fct_orders')
              field: order_id
      - name: content_id
        tests:
          - relationships:
              to: ref('stg_content')
              field: content_id
              severity: warn
```

```bash
dbt build --select +fct_pre_purchase_behavior
```

---

## 🧠 Lo que solo se aprende con experiencia

1. **Surrogate keys son hashes, no enteros.** `generate_surrogate_key(['user_id'])` devuelve un MD5. Es texto, no entero. Si tu BI tool espera entero como FK, vas a tener problemas. Plan B: usa `dbt_utils.surrogate_key_using_dense_rank` o crea una tabla `dim_user` con `row_number()` como integer SK.

2. **Identity resolution es un proyecto en sí mismo.** En empresas como Netflix o Spotify, equipos enteros se dedican a "identity": cookies, devices, accounts, profiles. dbt es donde consumes el resultado, no donde lo construyes. Si tu empresa no tiene identity resolution, tu análisis cross-domain está condenado a ser parcial.

3. **Cuidado con joins explosivos.** `orders × events` puede multiplicar filas brutalmente. Si una orden tiene 50 eventos previos, y tienes 100k órdenes, terminas con 5M filas. Si haces SUM sin `DISTINCT`, los totales se inflan. **Siempre verifica el count antes y después de cada join.**

4. **`qualify` vs `row_number() + CTE`.** En Snowflake, `qualify row_number() over (...) = 1` es ~30% más rápido que el patrón CTE clásico, porque el optimizador puede pushear el filtro mejor. Usa qualify siempre que puedas. Es soportado en Snowflake, BigQuery, Redshift, Databricks.

5. **El test `dbt_utils.expression_is_true` es subestimado.** Permite testear cualquier predicado SQL como test: `"amount > 0"`, `"end_date >= start_date"`, `"col_a + col_b = col_c"`. Lo uso más que `accepted_values`.

---

## ✅ Checklist de salida del Lab 04

- [ ] `identity_map.csv` cargado como seed
- [ ] Staging de clickstream con surrogate keys
- [ ] `int_user_identity_resolved` con fallback de match
- [ ] `fct_pre_purchase_behavior` cross-domain funcionando
- [ ] Tests cross-domain pasando (al menos como warn)
- [ ] Verificaste counts antes/después del join explosivo

---

## 🔜 Próximo lab

**Lab 05 — Materializaciones a fondo: ¿cuándo usar cuál?** Vas a tomar `fct_orders` y compararlo materializado como view, table e incremental. Medirás los tiempos y aprenderás cuándo cada uno gana.
