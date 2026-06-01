# 🧪 Lab 02 — Staging completo y automatización con codegen

**Nivel:** Básico 🟢
**Tiempo estimado:** 90 minutos
**Dominios cubiertos:** Sources, staging layer, codegen, primer macro
**Objetivo de negocio:** "Construir la capa de staging completa del dominio ecommerce. Para cada tabla raw debe existir un staging limpio, documentado y testeado."

---

## 🎯 Lo que vas a aprender

1. Usar el package `codegen` para generar staging y sources automáticamente
2. Definir tests masivos en YAML de forma consistente
3. Crear tu primer macro reutilizable (`cents_to_dollars`)
4. Patrón de "una vista de staging por tabla raw"

## 📋 Pre-requisitos

- Lab 01 completado
- `dbt deps` corrido con `codegen` y `dbt_utils` instalados

---

## Paso 1 — Generar sources automáticamente (15 min)

Escribir source YAMLs a mano para 12 tablas es tedioso y propenso a typos. `codegen` lo hace por ti.

```bash
dbt run-operation generate_source --args '{
  "schema_name": "RAW",
  "database_name": "BOOTCAMP_DB",
  "table_names": [
    "raw_customers", "raw_orders", "raw_products",
    "raw_order_items", "raw_payments", "raw_product_prices_history"
  ],
  "generate_columns": true,
  "include_descriptions": true
}'
```

Esto imprime en la consola un YAML completo con todas las columnas detectadas. Cópialo a `models/staging/ecommerce/_sources.yml` y ajusta descripciones.

> 💡 **Truco Senior:** Para sources con muchas columnas, `codegen` te ahorra horas. Pero **siempre revisa el output**: detecta tipos pero no semántica. Si una columna se llama `amt` puede ser un monto o un código; tú debes documentar la diferencia.

---

## Paso 2 — Generar modelos de staging base (20 min)

Para cada tabla raw, codegen genera el SQL boilerplate:

```bash
dbt run-operation generate_base_model --args '{
  "source_name": "raw_ecommerce",
  "table_name": "raw_orders"
}'
```

Salida (cópiala a `stg_orders.sql`):

```sql
with source as (
    select * from {{ source('raw_ecommerce', 'raw_orders') }}
),
renamed as (
    select
        order_id,
        customer_id,
        order_date,
        status
    from source
)
select * from renamed
```

**Repite para cada tabla.** Renombra ligeramente columnas si es necesario para que el nombre sea autodescriptivo en el modelo.

---

## Paso 3 — Crear tu primer macro reutilizable (15 min)

Los precios en raw están en centavos (`price_cents`). Convertirlos a dólares con `column / 100.0` se repetirá en muchos modelos. Eso pide un macro.

Crea `macros/cents_to_dollars.sql`:

```sql
{#
  Convierte un valor en centavos a dólares con redondeo.

  Args:
    column_name: nombre de la columna o expresión
    decimal_places: número de decimales (default 2)

  Uso:
    {{ cents_to_dollars('amount_cents') }}
    {{ cents_to_dollars('amount_cents * quantity', 4) }}
#}
{% macro cents_to_dollars(column_name, decimal_places=2) %}
    round( ({{ column_name }})::numeric / 100.0, {{ decimal_places }} )
{% endmacro %}
```

> ⚠️ **Error de principiante #1:** Olvidar los paréntesis alrededor de `{{ column_name }}`. Si pasas `'amount_cents * quantity'`, sin paréntesis te quedaría `amount_cents * quantity::numeric / 100`, donde el cast aplica solo a `quantity`. Con paréntesis te quedaría `(amount_cents * quantity)::numeric / 100`, que es lo correcto.

---

## Paso 4 — Staging completo con el macro aplicado (20 min)

Versión final de `models/staging/ecommerce/stg_orders.sql`:

```sql
{{ config(materialized='view') }}

with source as (
    select * from {{ source('raw_ecommerce', 'raw_orders') }}
),

renamed as (
    select
        order_id,
        customer_id,
        order_date,
        status,

        -- Categoría limpia (lab futuro usará esto)
        case
            when status in ('placed', 'shipped') then 'open'
            when status = 'completed'            then 'closed'
            when status = 'returned'             then 'returned'
            else 'unknown'
        end as order_state
    from source
    where order_id is not null
)

select * from renamed
```

`models/staging/ecommerce/stg_order_items.sql`:

```sql
{{ config(materialized='view') }}

with source as (
    select * from {{ source('raw_ecommerce', 'raw_order_items') }}
)

select
    line_id          as order_item_id,
    order_id,
    product_id,
    quantity,
    price_cents_at_order,

    -- Usa nuestro macro
    {{ cents_to_dollars('price_cents_at_order') }} as price_usd_at_order,

    {{ cents_to_dollars('price_cents_at_order * quantity') }} as line_total_usd
from source
```

`models/staging/ecommerce/stg_payments.sql`:

```sql
{{ config(materialized='view') }}

select
    payment_id,
    order_id,
    payment_method,
    amount_cents,
    {{ cents_to_dollars('amount_cents') }} as amount_usd
from {{ source('raw_ecommerce', 'raw_payments') }}
```

`models/staging/ecommerce/stg_products.sql`:

```sql
{{ config(materialized='view') }}

with source as (
    select * from {{ source('raw_ecommerce', 'raw_products') }}
),

-- ⚠️ Los datos raw tienen un producto duplicado (lo metimos a propósito)
-- Aquí lo deduplicamos antes de exponer
deduplicated as (
    select
        product_id,
        product_name,
        category,
        price_cents,
        is_active,
        row_number() over (
            partition by product_id
            order by product_id   -- arbitrario, los duplicados son idénticos
        ) as rn
    from source
)

select
    product_id,
    product_name,
    category,
    price_cents,
    {{ cents_to_dollars('price_cents') }} as price_usd,
    is_active
from deduplicated
where rn = 1
```

> 💡 **Lo que solo se aprende con experiencia:** Cuando ves duplicados en raw, **no asumas que son idénticos**. Antes de deduplicar, ejecuta:
>
> ```sql
> SELECT product_id, COUNT(*) AS dup_count, COUNT(DISTINCT product_name)
> FROM RAW.RAW_PRODUCTS GROUP BY 1 HAVING dup_count > 1;
> ```
>
> Si `COUNT(DISTINCT product_name)` es mayor a 1, los "duplicados" tienen valores distintos y hay que decidir cuál ganar (por fecha, por origen, etc.). En este caso son idénticos, pero acostúmbrate a verificar.

---

## Paso 5 — Tests masivos en YAML (15 min)

`models/staging/ecommerce/_models.yml`:

```yaml
version: 2

models:
  - name: stg_customers
    description: "Clientes con email normalizado"
    columns:
      - name: customer_id
        tests: [unique, not_null]
      - name: email
        tests: [not_null]

  - name: stg_orders
    description: "Órdenes con estado categorizado"
    columns:
      - name: order_id
        tests: [unique, not_null]
      - name: customer_id
        tests:
          - not_null
          - relationships:
              to: ref('stg_customers')
              field: customer_id
              # ⚠️ Este test va a FALLAR a propósito.
              # Los seeds tienen ~2% de órdenes con customer_id inexistente.
              # En el lab 11 vamos a "manejar" esto correctamente.
              severity: warn   # warn en vez de error para no romper la corrida
      - name: status
        tests:
          - accepted_values:
              values: ['placed', 'shipped', 'completed', 'returned']

  - name: stg_order_items
    description: "Líneas de las órdenes con precios calculados"
    columns:
      - name: order_item_id
        tests: [unique, not_null]
      - name: order_id
        tests:
          - not_null
          - relationships:
              to: ref('stg_orders')
              field: order_id
      - name: quantity
        tests:
          - not_null
          - dbt_utils.expression_is_true:
              expression: ">= 0"

  - name: stg_payments
    description: "Pagos de las órdenes"
    columns:
      - name: payment_id
        tests: [unique, not_null]
      - name: amount_cents
        tests:
          - not_null
          - dbt_utils.expression_is_true:
              expression: ">= 0"

  - name: stg_products
    description: "Catálogo de productos deduplicado"
    columns:
      - name: product_id
        tests: [unique, not_null]   # ⬅️ Pasará gracias a la deduplicación
      - name: category
        tests:
          - accepted_values:
              values: ['beverages', 'bakery', 'food']
```

---

## Paso 6 — Ejecutar todo y observar (10 min)

```bash
# Construye todo staging de ecommerce
dbt build --select staging.ecommerce
```

`dbt build` ejecuta los modelos Y los tests en orden del DAG.

**Lo que vas a ver:**

- ✅ 5 modelos pasaron (PASS)
- ⚠️ 1 test pasó con WARN: `relationships` en `stg_orders.customer_id` (los ~10 customer_id fantasma)
- ✅ Todos los demás tests pasaron

```bash
dbt docs generate
dbt docs serve
```

Abre el lineage graph. Verás:

```
raw_customers ─→ stg_customers
raw_orders    ─→ stg_orders ──→ (depends on stg_customers para el test)
raw_products  ─→ stg_products
...
```

---

## 🧠 Lo que solo se aprende con experiencia

1. **Tests warn vs error.** En staging, errores de calidad casi siempre van como `warn` y se manejan en intermediate. Si pones `error` aquí, una sola fila mala detiene toda la corrida y bloquea al equipo. La regla: **warn en staging, error en marts.** Los marts son el contrato con el negocio; no pueden tener datos malos.

2. **El patrón "view en staging + table en marts" no es dogma.** Si tu staging escanea 500M de filas con joins pesados en cada consulta, una view re-ejecuta todo eso cada vez. En ese caso, materializa staging como table. La regla práctica: empieza todo como view, sube a table cuando midas un problema real.

3. **Macros son un arma de doble filo.** `cents_to_dollars` está bien porque es simple y muy usado. Pero he visto equipos crear un macro para *cada* conversión SQL trivial, y al rato el código es ilegible: tienes que abrir 15 archivos para entender una consulta. **Regla:** macro solo si se repite 3+ veces Y agrega valor (más que solo "renombrar" SQL).

4. **codegen tiene un primo muy útil: `generate_model_yaml`.** Después de crear un modelo, en vez de escribir el YAML a mano:

   ```bash
   dbt run-operation generate_model_yaml --args '{"model_names": ["stg_orders"]}'
   ```

   Te imprime el YAML con todas las columnas, listo para pegar. Equipos serios automatizan esto en pre-commit hooks.

---

## ✅ Checklist de salida del Lab 02

- [ ] 5 modelos de staging creados (`stg_customers`, `stg_orders`, `stg_order_items`, `stg_payments`, `stg_products`)
- [ ] Cada modelo tiene su YAML con tests
- [ ] Macro `cents_to_dollars` creado y usado
- [ ] `dbt build --select staging.ecommerce` corre sin errores
- [ ] El warning de relationships en `customer_id` está identificado (lo arreglamos en lab 11)
- [ ] Docs generados, lineage graph visible

---

## 🔜 Próximo lab

**Lab 03 — Modelos intermediate y primer mart.** Construirás `fct_orders` (tabla de hechos), aprenderás cuándo usar ephemeral, y verás el primer caso de "data leak" (cuando un cambio en raw rompe un mart silenciosamente).
