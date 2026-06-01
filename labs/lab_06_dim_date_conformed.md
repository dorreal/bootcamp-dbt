# 🧪 Lab 06 — `dim_date` y dimensiones conformadas

**Nivel:** Intermedio 🟡
**Tiempo estimado:** 60 minutos
**Dominios cubiertos:** dim_date, dimensiones conformadas, fechas fiscales, dbt_date package
**Objetivo de negocio:** "El equipo de Finance pide reports por trimestre fiscal, los Analytics por mes calendario, y Marketing por semana ISO. Necesitamos una única dimensión de fechas que sirva a todos."

---

## 🎯 Lo que vas a aprender

1. Por qué cada proyecto necesita una `dim_date`
2. Cómo construirla sin escribir SQL desde cero (con `dbt_date`)
3. Concepto de "conformed dimensions" (dimensiones compartidas entre hechos)
4. Año fiscal vs calendario, semana ISO vs custom

---

## El problema

Si quieres responder "ventas por trimestre fiscal donde Q1 empieza en abril", calcular eso en cada query es propenso a error. Una `dim_date` centraliza esa lógica:

| date_day | day_of_week | fiscal_quarter | iso_week | is_weekend |
|---|---|---|---|---|
| 2026-05-28 | Thursday | FY2026-Q2 | 22 | false |

Todos los `fct_*` joinean a `dim_date` y reutilizan estos atributos.

---

## Paso 1 — `dim_date` con dbt_date (15 min)

`models/marts/core/dim_date.sql`:

```sql
{{
  config(
    materialized='table'
  )
}}

with date_spine as (
    {{
      dbt_date.get_date_dimension("2020-01-01", "2030-12-31")
    }}
)

select
    date_day,

    -- Componentes calendario
    day_of_week,
    day_of_week_name,
    day_of_week_name_short,
    day_of_month,
    day_of_year,
    week_start_date,
    week_end_date,
    iso_week_of_year,
    week_of_year,
    month_of_year,
    month_name,
    month_name_short,
    quarter_of_year,
    year_number,

    -- Flags útiles
    case when day_of_week in (1, 7) then true else false end       as is_weekend,
    case when date_day = current_date then true else false end     as is_today,
    case when date_day < current_date then true else false end     as is_past,
    case when date_day > current_date then true else false end     as is_future,

    -- Fiscal year (custom: empieza en abril)
    case
        when month_of_year >= 4 then year_number
        else year_number - 1
    end                                                            as fiscal_year,

    case
        when month_of_year between 4 and 6   then 1
        when month_of_year between 7 and 9   then 2
        when month_of_year between 10 and 12 then 3
        else 4
    end                                                            as fiscal_quarter,

    -- Etiquetas listas para BI
    'FY' || (case when month_of_year >= 4 then year_number else year_number - 1 end)
                                                                   as fiscal_year_label,

    'FY' || (case when month_of_year >= 4 then year_number else year_number - 1 end)
        || '-Q' || (case
            when month_of_year between 4 and 6   then 1
            when month_of_year between 7 and 9   then 2
            when month_of_year between 10 and 12 then 3
            else 4
        end)                                                       as fiscal_quarter_label

from date_spine
```

> 💡 **Por qué hasta 2030:** En empresas reales hay forecasts y planes financieros con fechas futuras. Si tu dim_date llega solo a "hoy", los joins de forecast pierden filas. Mejor 5 años de buffer hacia adelante.

---

## Paso 2 — Conectar `fct_orders` con `dim_date` (15 min)

Modifica `fct_orders` para tener una FK explícita:

```sql
select
    order_id,
    customer_id,
    order_date,
    order_date as date_day,    -- ⬅️ FK a dim_date
    ...
```

`_models.yml`:

```yaml
- name: fct_orders
  columns:
    - name: date_day
      tests:
        - relationships:
            to: ref('dim_date')
            field: date_day
```

Ahora cualquier dashboard puede hacer:

```sql
select
    d.fiscal_quarter_label,
    sum(o.total_paid_usd) as revenue
from {{ ref('fct_orders') }} o
join {{ ref('dim_date') }} d on o.date_day = d.date_day
where d.fiscal_year = 2026
group by d.fiscal_quarter_label
```

Sin tener que recalcular fiscal_quarter en la query.

---

## Paso 3 — Conformed dimension (15 min)

`dim_date` ahora es **conformada**: la usan `fct_orders`, `fct_pre_purchase_behavior` y `fct_daily_engagement`. Todos ven el mismo concepto de "trimestre fiscal".

**Reto:** modifica `fct_pre_purchase_behavior` y `fct_daily_engagement` para tener su FK `date_day` y test de relationships.

> 🧠 **Por qué importa:** En proyectos sin conformed dimensions, cada mart calcula su propio "quarter". Análisis cruzados entre dominios dan totales distintos porque uno usa quarter fiscal y otro calendario. Es el origen de los famosos "los números no cuadran entre dashboards".

---

## Paso 4 — Test de cobertura completa (15 min)

```yaml
- name: dim_date
  description: "Dimensión de fechas conformada. Cubre 2020-01-01 a 2030-12-31."
  columns:
    - name: date_day
      tests:
        - unique
        - not_null
        - dbt_utils.expression_is_true:
            expression: "between '2020-01-01' and '2030-12-31'"
    - name: fiscal_quarter
      tests:
        - accepted_values:
            values: [1, 2, 3, 4]
```

Test custom singular para asegurar continuidad (sin huecos de fechas):

`tests/dim_date_no_gaps.sql`:

```sql
-- Pasa si no hay huecos. Es decir, el número de filas distintas
-- debe igualar el rango total de fechas.
with bounds as (
    select min(date_day) as min_d, max(date_day) as max_d from {{ ref('dim_date') }}
),
counts as (
    select count(distinct date_day) as actual_days from {{ ref('dim_date') }}
)
select *
from bounds, counts
where datediff('day', min_d, max_d) + 1 != actual_days
```

---

## 🧠 Lo que solo se aprende con experiencia

1. **No reinventes la rueda con `dbt_date`.** Escribir un dim_date a mano con `generator()` es educativo pero produce el mismo resultado. En producción siempre usa `dbt_date` o `dbt_utils.date_spine`.

2. **El fiscal year es de las cosas más malentendidas.** Pregunta a Finance:
   - ¿En qué mes empieza el FY?
   - ¿FY26 se llama así porque termina en 2026 o porque empieza en 2026?
   - ¿Los trimestres son calendario o fiscales?

   Cada empresa lo tiene distinto. Documenta la decisión en el `description` del modelo.

3. **Time zones son hell.** Si tus eventos vienen en UTC pero el negocio piensa en CDMX, ¿el "día" de un evento ocurrido a las 11 PM CDMX se cuenta como hoy o mañana? Define la zona de referencia del negocio y haz el cast UNA VEZ, en staging.

4. **`dim_time` (hora del día) raramente vale la pena.** Si reportes son por hora, agrega `hour_of_day` directo a `dim_date` o como columna del fact. Una `dim_time` con 86400 filas (una por segundo) es overkill.

---

## ✅ Checklist Lab 06

- [ ] `dim_date` construida con `dbt_date.get_date_dimension`
- [ ] Fiscal year/quarter calculado según regla de negocio
- [ ] `fct_orders` y otros marts tienen FK `date_day` con test de relationships
- [ ] Test de no-gaps pasando

---

## 🔜 Próximo lab

**Lab 07 — Snapshots y SCD Type 2 a escala.** Vas a capturar cambios históricos de productos (precios que suben con el tiempo) usando `dbt snapshot`, y compararás vs hacerlo manualmente.
