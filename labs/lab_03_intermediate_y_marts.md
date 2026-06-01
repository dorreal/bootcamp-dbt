# 🧪 Lab 03 — Modelos intermediate y tu primer mart

**Nivel:** Básico 🟢
**Tiempo estimado:** 90 minutos
**Dominios cubiertos:** Intermediate layer, ephemeral, hechos y dimensiones, lineage
**Objetivo de negocio:** "Construir `dim_customers` y `fct_orders` para que el equipo de análisis pueda responder: '¿cuánto compraron nuestros clientes el último trimestre?'"

---

## 🎯 Lo que vas a aprender

1. Diferenciar staging / intermediate / marts en la práctica
2. Cuándo usar `ephemeral` (y cuándo NO)
3. Construir una tabla de hechos con métricas pre-calculadas
4. Tu primera dimensión enriquecida con agregaciones
5. Detectar el primer "data leak" entre capas

---

## Paso 1 — Modelo intermediate: enriquecer órdenes con totales (20 min)

Necesitamos calcular el total de cada orden (sumando líneas), incluyendo pagos. Esto NO va en staging (ya hace agregación) ni en mart (es intermedio). Va en `intermediate`.

`models/intermediate/int_orders_enriched.sql`:

```sql
{{
  config(
    materialized='ephemeral'
  )
}}

with orders as (
    select * from {{ ref('stg_orders') }}
),

order_items as (
    select
        order_id,
        sum(quantity)                     as total_items,
        sum(line_total_usd)               as items_subtotal_usd,
        count(distinct product_id)        as unique_products_in_order
    from {{ ref('stg_order_items') }}
    group by order_id
),

payments as (
    select
        order_id,
        sum(amount_usd)                   as total_paid_usd,
        count(*)                          as payment_count,
        listagg(distinct payment_method, ', ') within group (order by payment_method)
                                          as payment_methods
    from {{ ref('stg_payments') }}
    group by order_id
)

select
    o.order_id,
    o.customer_id,
    o.order_date,
    o.status,
    o.order_state,

    -- Métricas de items
    coalesce(oi.total_items, 0)                 as total_items,
    coalesce(oi.items_subtotal_usd, 0)          as items_subtotal_usd,
    coalesce(oi.unique_products_in_order, 0)    as unique_products,

    -- Métricas de pago
    coalesce(p.total_paid_usd, 0)               as total_paid_usd,
    coalesce(p.payment_count, 0)                as payment_count,
    p.payment_methods,

    -- Discrepancia (clave para data quality!)
    coalesce(oi.items_subtotal_usd, 0) - coalesce(p.total_paid_usd, 0)
                                                as payment_gap_usd

from orders o
left join order_items oi on o.order_id = oi.order_id
left join payments p     on o.order_id = p.order_id
```

> ⚠️ **Error de principiante #1:** Olvidar el `coalesce`. Si una orden no tiene pagos registrados aún, `total_paid_usd` queda en `NULL` y todas las restas/sumas downstream se rompen silenciosamente (NULL + 100 = NULL). **Regla: agregaciones con LEFT JOIN siempre con `coalesce` al 0 (o al valor neutro de la operación).**

> 💡 **¿Por qué ephemeral?** Este modelo solo se usa para alimentar `fct_orders`. No tiene valor para consultarse directo. Materializarlo como tabla o vista crea un objeto en Snowflake que nadie va a usar. Ephemeral lo inyecta como CTE: cero objetos en el warehouse.

---

## Paso 2 — Primer mart: `fct_orders` (20 min)

`models/marts/ecommerce/fct_orders.sql`:

```sql
{{
  config(
    materialized='table'
  )
}}

select
    -- Claves
    order_id,
    customer_id,

    -- Fechas
    order_date,
    extract(year from order_date)       as order_year,
    extract(month from order_date)      as order_month,
    extract(quarter from order_date)    as order_quarter,
    extract(dow from order_date)        as order_day_of_week,

    -- Estado
    status,
    order_state,

    -- Métricas
    total_items,
    unique_products,
    items_subtotal_usd,
    total_paid_usd,
    payment_count,
    payment_methods,
    payment_gap_usd,

    -- Flags útiles para análisis
    case when payment_gap_usd > 0.01 then true else false end
                                        as has_payment_gap,
    case when total_paid_usd = 0 then true else false end
                                        as is_unpaid,

    -- Auditoría
    current_timestamp                   as dbt_loaded_at

from {{ ref('int_orders_enriched') }}
```

> 💡 **Convención Senior:** Toda tabla de hechos termina con una columna de auditoría (`dbt_loaded_at` o `dbt_updated_at`). Cuando alguien venga en 3 meses preguntando "¿está actualizada esta tabla?", esa columna responde sin abrir dbt.

---

## Paso 3 — Dimensión enriquecida: `dim_customers` (20 min)

Una dimensión clásica enriquece atributos del cliente con métricas derivadas (RFM analysis básico).

`models/marts/ecommerce/dim_customers.sql`:

```sql
{{
  config(
    materialized='table'
  )
}}

with customers as (
    select * from {{ ref('stg_customers') }}
),

order_stats as (
    select
        customer_id,
        count(*)                                 as total_orders,
        count(case when status = 'completed' then 1 end)    as completed_orders,
        count(case when status = 'returned' then 1 end)     as returned_orders,
        sum(total_paid_usd)                      as lifetime_value_usd,
        min(order_date)                          as first_order_date,
        max(order_date)                          as last_order_date,
        avg(total_paid_usd)                      as avg_order_value_usd
    from {{ ref('fct_orders') }}
    where customer_id is not null
    group by customer_id
)

select
    -- Datos del cliente
    c.customer_id,
    c.first_name,
    c.last_name,
    c.first_name || ' ' || c.last_name           as full_name,
    c.email,
    c.signup_date,

    -- Métricas RFM (Recency, Frequency, Monetary)
    coalesce(os.total_orders, 0)                 as total_orders,
    coalesce(os.completed_orders, 0)             as completed_orders,
    coalesce(os.returned_orders, 0)              as returned_orders,
    coalesce(os.lifetime_value_usd, 0)           as lifetime_value_usd,
    coalesce(os.avg_order_value_usd, 0)          as avg_order_value_usd,
    os.first_order_date,
    os.last_order_date,

    -- Recency en días
    datediff('day', os.last_order_date, current_date) as days_since_last_order,

    -- Segmentación simple
    case
        when os.total_orders is null                                       then 'never_purchased'
        when datediff('day', os.last_order_date, current_date) <= 90       then 'active'
        when datediff('day', os.last_order_date, current_date) <= 365      then 'lapsing'
        else                                                                    'churned'
    end                                          as customer_segment,

    current_timestamp                            as dbt_loaded_at

from customers c
left join order_stats os on c.customer_id = os.customer_id
```

---

## Paso 4 — Documentar y testear los marts (15 min)

`models/marts/ecommerce/_models.yml`:

```yaml
version: 2

models:
  - name: fct_orders
    description: |
      Tabla de hechos a nivel de orden. Cada fila es una orden única
      con sus métricas pre-calculadas (items, pagos, gaps).

      **Granularidad:** 1 fila por orden.
      **Owner:** Equipo de Analytics.
      **SLA:** Actualización diaria a las 6am.

    columns:
      - name: order_id
        description: "PK. Identificador único de la orden."
        tests:
          - unique
          - not_null
      - name: customer_id
        description: "FK a dim_customers. Puede contener IDs huérfanos (~2%, ver lab 11)."
        tests:
          - not_null
          - relationships:
              to: ref('dim_customers')
              field: customer_id
              severity: warn
      - name: order_date
        tests: [not_null]
      - name: total_paid_usd
        description: "Suma de todos los pagos asociados a la orden en USD."
        tests:
          - not_null
          - dbt_utils.expression_is_true:
              expression: ">= 0"

  - name: dim_customers
    description: |
      Dimensión enriquecida de clientes con métricas RFM y segmentación.

      **Granularidad:** 1 fila por cliente (snapshot del estado actual).
      **Note:** Para historia de cambios, ver el snapshot del lab 7.

    columns:
      - name: customer_id
        tests: [unique, not_null]
      - name: email
        tests: [not_null]
      - name: customer_segment
        tests:
          - accepted_values:
              values: ['never_purchased', 'active', 'lapsing', 'churned']
      - name: lifetime_value_usd
        tests:
          - dbt_utils.expression_is_true:
              expression: ">= 0"
```

---

## Paso 5 — Construir todo y observar el data leak (15 min)

```bash
dbt build --select +marts.ecommerce
```

El `+` a la izquierda significa "este modelo y todos sus ancestros". Esto construye desde staging hasta marts en el orden correcto.

**Observa el output cuidadosamente.** Vas a notar algo raro:

```
WARN: relationships test on fct_orders.customer_id — 10 records found
WARN: relationships test on stg_orders.customer_id — 10 records found
```

¡Pero `dim_customers` solo tiene los clientes con email válido! Los ~10 customer_id "fantasma" de raw nunca llegan ahí.

```sql
SELECT COUNT(DISTINCT customer_id) FROM RAW.RAW_ORDERS;        -- ~80
SELECT COUNT(DISTINCT customer_id) FROM ANALYTICS_MARTS.DIM_CUSTOMERS;  -- ~75
SELECT COUNT(DISTINCT customer_id) FROM ANALYTICS_MARTS.FCT_ORDERS;     -- ~80
```

Las órdenes apuntan a clientes que no existen en la dimensión. **Esto es un "data leak"**: un cliente puede aparecer en `fct_orders` pero no en `dim_customers`, y un dashboard que haga `JOIN` los va a perder.

> 🧠 **Lección Senior:** Este es el bug #1 en proyectos reales. Lo cubrimos a profundidad en el **Lab 11 (Data Quality Framework)**. Por ahora reconócelo y dócumentalo en el `description` del modelo (como hicimos en `customer_id`).

---

## 🧠 Lo que solo se aprende con experiencia

1. **Ephemeral no es gratis.** Cada vez que `int_orders_enriched` es referenciado, dbt compila su CTE dentro del modelo padre. Si 5 modelos lo usan, su lógica se ejecuta 5 veces. Si es lógica pesada (joins con tablas grandes), conviene materializarlo como `table` aunque parezca "intermedio". **Regla:** ephemeral solo para lógica ligera + reutilizada por ≤2 modelos.

2. **No replicar lógica entre marts.** Si vas a calcular `lifetime_value_usd` también en otra dimensión, no copies-pegues el SQL. Crea un intermediate `int_customer_metrics` y úsalo en ambos lugares. La duplicación de lógica es la enfermedad #1 de proyectos dbt grandes.

3. **El concepto de "grain" (granularidad) es crítico.** Tu `fct_orders` tiene grain "1 fila por orden". Tu `dim_customers` tiene grain "1 fila por cliente". Si confundes los grains al hacer joins en un dashboard, multiplicas filas accidentalmente. **Siempre documenta el grain en el `description` del modelo.** Es la primera pregunta que un Senior hace cuando ve un modelo nuevo: "¿cuál es el grain?"

4. **`dim_` y `fct_` no son solo convención.** En Looker, Power BI, Tableau y dbt Semantic Layer, el prefijo importa. Herramientas reconocen `fct_` como "tabla de hechos" (joinable a N dimensiones) y `dim_` como "tabla de dimensión" (joinable a 1+ hechos). Romper la convención rompe la auto-detección.

5. **`current_timestamp` en una tabla materializada cambia en cada `dbt run`.** Si la usas en lógica de negocio (ej: `case when last_order_date >= current_date - 30`), tu tabla muta sin que cambien los datos source. Es deseable para `dbt_loaded_at`, peligroso si lo metes en una métrica.

---

## ✅ Checklist de salida del Lab 03

- [ ] `int_orders_enriched` creado como ephemeral
- [ ] `fct_orders` materializado como table con métricas y flags
- [ ] `dim_customers` con segmentación RFM
- [ ] YAML con tests y descripciones detalladas (incluyendo grain)
- [ ] Detectaste el data leak entre `fct_orders` y `dim_customers`
- [ ] Lineage graph muestra: raw → staging → intermediate → marts

---

## 🔜 Próximo lab

**Lab 04 — Surrogate keys y joins entre dominios.** Vas a hacer join entre `ecommerce` y `clickstream` (resolver identidades) y aprenderás por qué `generate_surrogate_key` es esencial cuando combinas múltiples fuentes.
