# 🧪 Lab 09 — Multi-currency: el problema clásico de FX

**Nivel:** Avanzado 🔴
**Tiempo estimado:** 90 minutos
**Dominios cubiertos:** Joins temporales, FX conversion, conformed metrics, currency neutrality
**Objetivo de negocio:** "Operamos en US, México, Brasil y Argentina. Cada transacción ocurre en su moneda local. El CFO quiere ver revenue consolidado en USD usando la tasa del día de la transacción (no la actual)."

---

## 🎯 Lo que vas a aprender

1. Por qué convertir a moneda neutra es un problema *temporal*, no un cálculo simple
2. Manejar tasas FX faltantes (fines de semana, feriados)
3. El patrón `most_recent_rate_per_day`
4. Conformed metric: una sola definición de "revenue_usd" en todo el warehouse

## El problema

```sql
-- La tasa MXN→USD del 10 de marzo era 17.2
-- La tasa MXN→USD de hoy es 17.5
-- Una transacción de 1000 MXN el 10 de marzo vale:
--   ❌ 1000 / 17.5 = $57.14 (usando la tasa de HOY: incorrecto)
--   ✅ 1000 / 17.2 = $58.14 (usando la tasa del DÍA: correcto)
```

Multiplicado por millones de transacciones, la diferencia es millones de USD.

---

## Paso 1 — Examinar el problema: tasas faltantes (15 min)

```sql
-- ¿Tenemos tasa para cada par (date × currency)?
WITH all_dates AS (
    SELECT DISTINCT transaction_date FROM BOOTCAMP_DB.RAW.RAW_TRANSACTIONS
),
all_currencies AS (
    SELECT DISTINCT currency FROM BOOTCAMP_DB.RAW.RAW_TRANSACTIONS
),
expected AS (
    SELECT * FROM all_dates CROSS JOIN all_currencies
),
actual AS (
    SELECT rate_date, from_currency FROM BOOTCAMP_DB.RAW.RAW_FX_RATES
)
SELECT COUNT(*) AS missing_rates
FROM expected e
LEFT JOIN actual a
    ON e.transaction_date = a.rate_date
   AND e.currency = a.from_currency
WHERE a.rate_date IS NULL;
```

Vas a ver muchas combinaciones faltantes. Razones reales:
- FX no opera fines de semana ni feriados
- Tu herramienta de ingestion solo trae rates de los últimos 60 días (los seeds simulan esto)
- Para currencies poco comunes, el proveedor a veces falla

---

## Paso 2 — Modelo de FX rates con forward-fill (20 min)

Necesitamos que CADA fecha tenga tasa, usando la tasa del último día disponible si falta.

`models/intermediate/int_fx_rates_filled.sql`:

```sql
{{ config(materialized='table') }}

with date_spine as (
    select date_day
    from {{ ref('dim_date') }}
    where date_day between
        (select min(transaction_date) from {{ ref('stg_transactions') }})
        and
        (select max(transaction_date) from {{ ref('stg_transactions') }})
),

currencies as (
    select distinct from_currency from {{ ref('stg_fx_rates') }}
),

expected as (
    select
        d.date_day,
        c.from_currency
    from date_spine d
    cross join currencies c
),

with_rate as (
    select
        e.date_day,
        e.from_currency,
        r.rate                       as direct_rate
    from expected e
    left join {{ ref('stg_fx_rates') }} r
        on e.date_day = r.rate_date
        and e.from_currency = r.from_currency
),

forward_filled as (
    select
        date_day,
        from_currency,
        direct_rate,
        -- Lleva hacia adelante la última tasa conocida cuando falta
        coalesce(
            direct_rate,
            last_value(direct_rate ignore nulls) over (
                partition by from_currency
                order by date_day
                rows between unbounded preceding and 1 preceding
            )
        ) as rate_to_usd
    from with_rate
)

select
    date_day,
    from_currency,
    rate_to_usd,
    case when direct_rate is null then true else false end as is_forward_filled
from forward_filled
where rate_to_usd is not null   -- excluye fechas anteriores al primer rate
```

> 💡 **`LAST_VALUE(... IGNORE NULLS)` es Snowflake-specific** (también funciona en Redshift, BigQuery). Es la forma elegante de hacer forward-fill sin self-joins horribles. Memorízalo.

> ⚠️ **Error de principiante #1:** Olvidar `rows between unbounded preceding and 1 preceding`. Sin esto, la ventana incluye la fila actual y nunca encuentra valores "anteriores". El forward-fill no funciona.

---

## Paso 3 — Aplicar FX a transacciones (20 min)

`models/marts/finance/fct_transactions_usd.sql`:

```sql
{{
  config(
    materialized='incremental',
    unique_key='transaction_id',
    incremental_strategy='merge'
  )
}}

with transactions as (
    select * from {{ ref('stg_transactions') }}
    {% if is_incremental() %}
    where transaction_date >= (select dateadd('day', -14, max(transaction_date)) from {{ this }})
    {% endif %}
),

fx as (
    select * from {{ ref('int_fx_rates_filled') }}
)

select
    t.transaction_id,
    t.customer_id,
    t.transaction_date,
    t.amount                                      as amount_local,
    t.currency                                    as currency_local,

    -- Tasa aplicada (la del día de la transacción)
    fx.rate_to_usd,
    fx.is_forward_filled                          as rate_was_estimated,

    -- Conversión
    round(t.amount / fx.rate_to_usd, 2)           as amount_usd,

    t.transaction_type,
    t.ingested_at,
    current_timestamp                             as dbt_loaded_at

from transactions t
left join fx
    on t.transaction_date = fx.date_day
    and t.currency = fx.from_currency
```

> ⚠️ **Error de principiante #2:** Multiplicar en lugar de dividir. Si la tasa es `MXN → USD = 17.5` (significa "1 USD = 17.5 MXN"), entonces `amount_usd = amount_mxn / 17.5`. Si dividieras al revés, obtendrías 0.057. **Siempre escribe la unidad en el nombre de la columna** (`rate_to_usd` deja claro que es "X local = 1 USD").

---

## Paso 4 — Tests críticos para FX (15 min)

```yaml
- name: fct_transactions_usd
  description: "Transacciones convertidas a USD usando la tasa del día"
  columns:
    - name: transaction_id
      tests: [unique, not_null]
    - name: amount_usd
      tests:
        - not_null
    - name: rate_to_usd
      tests:
        - not_null              # ⚠️ Si esto falla, hay un currency nuevo sin rate
    - name: currency_local
      tests:
        - accepted_values:
            values: ['USD', 'MXN', 'EUR', 'BRL', 'ARS']

  # Tests a nivel de modelo
  tests:
    # Validar que la conversión USD a USD es identidad
    - dbt_utils.expression_is_true:
        expression: "currency_local != 'USD' or amount_local = amount_usd"
        config:
          severity: warn
```

Test singular para detectar transacciones con conversión sospechosa:

`tests/fx_unusual_conversion.sql`:

```sql
-- Alerta si la conversión cambió mucho vs el promedio histórico de esa currency
with stats as (
    select
        currency_local,
        avg(amount_usd / nullif(amount_local, 0)) as avg_rate_inverse,
        stddev(amount_usd / nullif(amount_local, 0)) as stddev_rate_inverse
    from {{ ref('fct_transactions_usd') }}
    where transaction_date >= dateadd('day', -90, current_date)
    group by 1
)
select t.*
from {{ ref('fct_transactions_usd') }} t
join stats s on t.currency_local = s.currency_local
where t.transaction_date >= dateadd('day', -7, current_date)
  and abs((t.amount_usd / nullif(t.amount_local, 0)) - s.avg_rate_inverse) > 3 * s.stddev_rate_inverse
```

Esto detecta transacciones donde la tasa aplicada se desvió >3 sigmas del promedio (señal de bug en FX rates).

---

## Paso 5 — Conformed metric: definir UNA VEZ qué es "revenue_usd" (20 min)

El error clásico: 3 dashboards y 5 marts diferentes calculan `revenue_usd` cada uno a su manera. Inevitablemente dan números distintos.

Solución: define `revenue_usd` en UN solo lugar y haz que todos los marts referencien ese cálculo.

`macros/revenue_usd.sql`:

```sql
{# Definición canónica de revenue_usd. NO copies-pegues esta lógica en marts. #}
{% macro revenue_usd(amount_col='amount_usd', type_col='transaction_type') %}
    sum(case
        when {{ type_col }} = 'debit'  then {{ amount_col }}
        when {{ type_col }} = 'refund' then -{{ amount_col }}
        else 0
    end)
{% endmacro %}
```

Uso en cualquier mart:

```sql
select
    transaction_date,
    {{ revenue_usd() }} as net_revenue_usd
from {{ ref('fct_transactions_usd') }}
group by 1
```

Si mañana Finance dice "los refunds deben restar solo el 90%", cambias el macro y TODOS los marts se actualizan.

> 💡 **Esto es la base del dbt Semantic Layer.** En dbt 1.6+, esa lógica se define como `metric` en YAML y se expone como API a herramientas de BI. Lo veremos en lab 14.

---

## 🧠 Lo que solo se aprende con experiencia

1. **Forward-fill NO es siempre correcto.** Si una transacción ocurrió el sábado, ¿usas la tasa del viernes (forward-fill) o del lunes siguiente (backward-fill)? Bancos suelen usar la tasa de cierre del viernes para el lunes. **Confírmalo con Finance.** En algunos contextos legales, la diferencia es material.

2. **No todas las currencies son iguales.** ARS (Argentina) puede devaluarse 20% en un día. USD-EUR fluctúa 0.5%. Tu forward-fill puede ser totalmente inválido para currencies volátiles. **Considera invalidar conversiones donde la última tasa conocida tiene > N días.**

3. **El "rate provider" importa.** Bloomberg, OANDA, BoE, ECB, Fed, ... cada uno publica tasas ligeramente distintas. Si tu empresa firma contratos en EUR y la tasa contractual es del ECB pero tu warehouse usa OANDA, los reports financieros NO coinciden con los reports contractuales. **Documenta la fuente de tus rates.**

4. **`nullif` es tu amigo en finance.** `amount / rate` revienta si rate es 0 o NULL. `amount / nullif(rate, 0)` produce NULL (que es propagable). Mejor un NULL claro que un crash en producción.

5. **Currency conversion no es la única transformación temporal.** Existen también: índices de inflación (CPI), precios reales vs nominales, ajustes por estacionalidad. El patrón as-of join es transferible.

---

## ✅ Checklist Lab 09

- [ ] `int_fx_rates_filled` con forward-fill funcionando
- [ ] `fct_transactions_usd` con tasa correcta del día
- [ ] Tests validando rate not null y unusual_conversion
- [ ] Macro `revenue_usd` definido y usado en al menos 2 marts
- [ ] Documentaste la fuente de tus rates (en `description` del source)

---

## 🔜 Próximo lab

**Lab 10 — Microbatch para series de tiempo masivas.** Es momento de procesar los 10M eventos de clickstream usando la estrategia incremental más avanzada de dbt. Caso real: Netflix procesa billones de eventos por día con este patrón.
