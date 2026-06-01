# 🧪 Lab 13 — Multi-tenancy y Governance: separación entre equipos sin perder reusabilidad

**Nivel:** Avanzado 🔴🔴
**Tiempo estimado:** 100 minutos
**Dominios cubiertos:** Groups, access modifiers (private/protected/public), model versions, GRANTs automáticos, schema strategy, on-run-end hooks
**Objetivo de negocio:** *"Tenemos 4 equipos (Finance, Marketing, Producto, Ciencia de Datos) trabajando en el mismo dbt project. Finance no quiere que Marketing toque sus marts de revenue. Pero los modelos staging deben compartirse. ¿Cómo lo organizamos sin convertirlo en un cuello de botella?"*

---

## 🎯 Lo que vas a aprender

1. dbt **Groups**: agrupar modelos por equipo/dominio responsable
2. **Access modifiers**: `private`, `protected`, `public` — quién puede hacer `ref()` a qué
3. **Model versions**: evolucionar un mart sin romper a los consumidores
4. **GRANTs automáticos**: cada equipo ve solo sus schemas, programáticamente
5. **on-run-end hooks**: aplicar permisos al final de cada run

---

## El problema sin governance

Sin estructura, terminas con:

- Modelo `fct_revenue` que 6 equipos `ref()` y nadie sabe quién es dueño
- Cambios en staging que rompen marts de otros equipos sin aviso
- Permisos de Snowflake configurados a mano una vez en 2024 y nadie sabe si siguen vigentes
- "Aquí en la empresa todos tenemos acceso a todo" (= horror de seguridad y auditoría)

---

## Paso 1 — Definir Groups (15 min) 🎯

Un **group** es un namespace lógico que agrupa modelos por equipo.

`models/_groups.yml`:

```yaml
version: 2

groups:
  - name: finance
    owner:
      name: Finance Data Team
      email: finance-data@empresa.com
      slack: "#finance-data"
    description: "Marts financieros: revenue, costs, P&L, contabilidad"

  - name: marketing
    owner:
      name: Marketing Analytics
      email: marketing-analytics@empresa.com
      slack: "#mkt-analytics"
    description: "Attribution, CAC, LTV, campañas, segmentación"

  - name: product
    owner:
      name: Product Analytics
      email: product-analytics@empresa.com
      slack: "#product-analytics"
    description: "Engagement, retention, funnel, feature adoption"

  - name: data_platform
    owner:
      name: Data Platform Team
      email: data-platform@empresa.com
      slack: "#data-platform"
    description: "Modelos staging y conformados, owned by central data team"
```

---

## Paso 2 — Asignar modelos a groups (15 min)

Hay dos formas: en el YAML de cada modelo, o jerárquicamente en `dbt_project.yml`.

### Forma jerárquica (recomendada)

`dbt_project.yml`:

```yaml
models:
  bootcamp:
    staging:
      +group: data_platform        # todos los staging son del platform team
      +access: protected           # otros groups pueden ref() pero no extender

    intermediate:
      +group: data_platform
      +access: protected

    marts:
      ecommerce:
        +group: finance            # marts de ecommerce → finance
        +access: public            # cualquiera puede ref()

      clickstream:
        +group: product            # marts de clickstream → product
        +access: public

      finance:
        +group: finance
        +access: protected         # solo finance puede ref()
                                   # marketing NO podrá hacer ref('fct_pnl')

      marketing:
        +group: marketing
        +access: public

  bootcamp:
    marts:
      finance:
        _private:
          +access: private         # modelos en /finance/_private/ NO se pueden ref() desde otro group
```

### Anatomía de los access modifiers

| Modifier | Quién puede `ref()` |
|----------|---------------------|
| `public` (default) | Cualquiera, cualquier group |
| `protected` | Solo modelos del mismo group |
| `private` | Solo modelos del mismo group Y mismo subdirectorio |

> 💡 **Lo que solo se aprende con experiencia:**
> El default `public` es peligroso a escala. La práctica que veo en empresas grandes es:
> - **staging**: `protected` (otros equipos lo pueden referenciar pero no mutar)
> - **intermediate**: `private` (es implementación interna)
> - **marts**: `public` solo los que son "API pública" para BI
> - **marts internos**: `private` o `protected`

---

## Paso 3 — Probar que la separación funciona (15 min)

Crea un modelo de prueba que viola las reglas:

`models/marts/marketing/fct_revenue_attribution.sql`:

```sql
-- Marketing intenta referenciar un mart privado de Finance
{{ config(group='marketing', access='public') }}

SELECT *
FROM {{ ref('fct_pnl') }}  -- 🚨 fct_pnl es group=finance, access=protected
```

Ejecuta:
```bash
dbt parse
```

Verás un error del tipo:
```
Node model.bootcamp.fct_revenue_attribution attempted to reference node
model.bootcamp.fct_pnl which is in group 'finance' and has access 'protected'.
```

**Eso es exactamente lo que querías**: que el sistema bloquee accesos cruzados antes de ejecutar.

> ⚠️ **Errores típicos de principiante:**
> - Crear groups pero dejar todo en `access: public`: no proteges nada.
> - Marcar todo como `private`: equipos se bloquean entre sí, cada uno reimplementa staging por su cuenta = nightmare.
> - **Regla práctica**: una columna de tu YAML por modelo crítico, default jerárquico para el resto.

---

## Paso 4 — Model versions: evolución sin romper consumers (20 min) 🎯

Imagina que Finance necesita cambiar `fct_orders` para incluir `tax_breakdown`, pero Marketing tiene 47 dashboards que dependen del schema actual. **Solución: versiones.**

`models/marts/finance/fct_orders_v2.sql`:

```sql
{{ config(
    materialized='table',
    group='finance',
    access='public',
    contract={'enforced': true}
) }}

SELECT
    order_id,
    customer_id,
    order_date,
    order_total_usd,
    tax_amount_usd,        -- 🆕 columna nueva en v2
    tax_jurisdiction,      -- 🆕
    tax_rate,              -- 🆕
    order_status,
    CURRENT_TIMESTAMP() AS dbt_processed_at
FROM {{ ref('int_orders_enriched') }}
```

`models/marts/finance/_finance.yml`:

```yaml
version: 2

models:
  - name: fct_orders
    latest_version: 2     # 🎯 v2 es la versión "default" cuando se hace ref('fct_orders')
    config:
      contract: { enforced: true }
    columns:
      - { name: order_id, data_type: varchar }
      - { name: customer_id, data_type: varchar }
      - { name: order_date, data_type: date }
      - { name: order_total_usd, data_type: number(18,2) }
      - { name: order_status, data_type: varchar }

    versions:
      - v: 1
        deprecation_date: 2026-12-31  # Marketing tiene hasta entonces para migrar
        config:
          materialized: table

      - v: 2
        defined_in: fct_orders_v2     # archivo
        columns:
          - { name: tax_amount_usd, data_type: number(18,2) }
          - { name: tax_jurisdiction, data_type: varchar }
          - { name: tax_rate, data_type: number(5,4) }
```

Ahora los consumidores pueden elegir:

```sql
-- Marketing (legacy)
SELECT * FROM {{ ref('fct_orders', v=1) }}  -- explícitamente v1

-- Finance (nuevo)
SELECT * FROM {{ ref('fct_orders', v=2) }}  -- v2

-- Sin versión → usa latest_version (v=2)
SELECT * FROM {{ ref('fct_orders') }}
```

Cuando llegue `2026-12-31`, dbt emitirá warnings de deprecación. Marketing tiene 6 meses para migrar.

> 💡 **Lo que solo se aprende con experiencia:**
> En Amazon mantienen v1 y v2 en paralelo durante 6-12 meses. v1 es solo una vista sobre v2 que renombra columnas:
> ```sql
> -- fct_orders_v1.sql (después del refactor)
> SELECT
>     order_id, customer_id, order_date, order_total_usd, order_status
> FROM {{ ref('fct_orders', v=2) }}
> ```
> Así v1 sigue funcionando pero la lógica vive en un solo lugar (v2).

---

## Paso 5 — Schemas por equipo (10 min)

En `dbt_project.yml`, usa `+schema` para que cada group escriba a su propio schema:

```yaml
models:
  bootcamp:
    staging:
      +schema: staging          # → BOOTCAMP_DB.STAGING

    marts:
      ecommerce:
        +schema: marts_ecommerce  # → BOOTCAMP_DB.MARTS_ECOMMERCE
      clickstream:
        +schema: marts_product    # → BOOTCAMP_DB.MARTS_PRODUCT
      finance:
        +schema: marts_finance    # → BOOTCAMP_DB.MARTS_FINANCE
      marketing:
        +schema: marts_marketing  # → BOOTCAMP_DB.MARTS_MARKETING
```

Ahora cada equipo tiene su schema. **Próximo paso**: que cada equipo solo tenga GRANTs a su schema.

---

## Paso 6 — GRANTs automáticos con on-run-end (20 min) 🎯

Configurar GRANTs a mano es un anti-patrón. Hazlo programático.

`macros/grant_schema_access.sql`:

```sql
{% macro grant_schema_access() %}
    {# Solo correr en production target #}
    {% if target.name == 'prod' %}

        {% set grants_sql %}
            -- Finance team: lectura en marts_finance y marts_ecommerce
            GRANT USAGE ON SCHEMA BOOTCAMP_DB.MARTS_FINANCE TO ROLE FINANCE_READER;
            GRANT SELECT ON ALL TABLES IN SCHEMA BOOTCAMP_DB.MARTS_FINANCE TO ROLE FINANCE_READER;
            GRANT SELECT ON ALL VIEWS IN SCHEMA BOOTCAMP_DB.MARTS_FINANCE TO ROLE FINANCE_READER;
            GRANT USAGE ON SCHEMA BOOTCAMP_DB.MARTS_ECOMMERCE TO ROLE FINANCE_READER;
            GRANT SELECT ON ALL TABLES IN SCHEMA BOOTCAMP_DB.MARTS_ECOMMERCE TO ROLE FINANCE_READER;

            -- Marketing team: lectura en marts_marketing y marts_ecommerce
            GRANT USAGE ON SCHEMA BOOTCAMP_DB.MARTS_MARKETING TO ROLE MARKETING_READER;
            GRANT SELECT ON ALL TABLES IN SCHEMA BOOTCAMP_DB.MARTS_MARKETING TO ROLE MARKETING_READER;
            GRANT USAGE ON SCHEMA BOOTCAMP_DB.MARTS_ECOMMERCE TO ROLE MARKETING_READER;
            GRANT SELECT ON ALL TABLES IN SCHEMA BOOTCAMP_DB.MARTS_ECOMMERCE TO ROLE MARKETING_READER;

            -- Product team: lectura en marts_product
            GRANT USAGE ON SCHEMA BOOTCAMP_DB.MARTS_PRODUCT TO ROLE PRODUCT_READER;
            GRANT SELECT ON ALL TABLES IN SCHEMA BOOTCAMP_DB.MARTS_PRODUCT TO ROLE PRODUCT_READER;

            -- 🎯 FUTURE GRANTS: aplican automáticamente a tablas nuevas
            GRANT SELECT ON FUTURE TABLES IN SCHEMA BOOTCAMP_DB.MARTS_FINANCE TO ROLE FINANCE_READER;
            GRANT SELECT ON FUTURE TABLES IN SCHEMA BOOTCAMP_DB.MARTS_MARKETING TO ROLE MARKETING_READER;
            GRANT SELECT ON FUTURE TABLES IN SCHEMA BOOTCAMP_DB.MARTS_PRODUCT TO ROLE PRODUCT_READER;
            GRANT SELECT ON FUTURE TABLES IN SCHEMA BOOTCAMP_DB.MARTS_ECOMMERCE TO ROLE FINANCE_READER;
            GRANT SELECT ON FUTURE TABLES IN SCHEMA BOOTCAMP_DB.MARTS_ECOMMERCE TO ROLE MARKETING_READER;
        {% endset %}

        {% do run_query(grants_sql) %}
        {{ log("✅ Schema grants aplicados", info=true) }}
    {% endif %}
{% endmacro %}
```

En `dbt_project.yml`:

```yaml
on-run-end:
  - "{{ grant_schema_access() }}"
```

Cada `dbt run` en prod aplicará los GRANTs. Si creas una tabla nueva, **FUTURE GRANTS** se encarga.

> 💡 **Lo que solo se aprende con experiencia:**
> `GRANT SELECT ON FUTURE TABLES` es la diferencia entre "tengo que dar permisos cada vez que creo un mart" y "el sistema lo hace solo". Cualquiera que haya operado un warehouse a escala llegó tarde a este descubrimiento.

---

## Paso 7 — Crear los roles en Snowflake (5 min)

Antes de que el macro funcione, los roles deben existir:

```sql
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS FINANCE_READER;
CREATE ROLE IF NOT EXISTS MARKETING_READER;
CREATE ROLE IF NOT EXISTS PRODUCT_READER;

-- Otorgar usage del warehouse y database
GRANT USAGE ON WAREHOUSE BOOTCAMP_WH TO ROLE FINANCE_READER;
GRANT USAGE ON WAREHOUSE BOOTCAMP_WH TO ROLE MARKETING_READER;
GRANT USAGE ON WAREHOUSE BOOTCAMP_WH TO ROLE PRODUCT_READER;

GRANT USAGE ON DATABASE BOOTCAMP_DB TO ROLE FINANCE_READER;
GRANT USAGE ON DATABASE BOOTCAMP_DB TO ROLE MARKETING_READER;
GRANT USAGE ON DATABASE BOOTCAMP_DB TO ROLE PRODUCT_READER;
```

Luego asignas users a estos roles según su equipo.

---

## Paso 8 — Exposures: documentar consumers downstream (10 min)

Los **exposures** documentan que un dashboard, ML model, o app externa depende de un modelo dbt.

`models/marts/finance/_exposures.yml`:

```yaml
version: 2

exposures:
  - name: finance_executive_dashboard
    type: dashboard
    maturity: high
    url: https://tableau.empresa.com/views/FinanceExec
    description: "Dashboard semanal del CFO con revenue, costos, margen"
    depends_on:
      - ref('fct_orders')
      - ref('fct_pnl')
      - ref('dim_customers')
    owner:
      name: Maria Lopez
      email: mlopez@empresa.com

  - name: revenue_forecast_ml
    type: ml
    maturity: medium
    description: "Modelo ML de forecasting de revenue mensual"
    depends_on:
      - ref('fct_orders')
      - ref('dim_date')
    owner:
      name: Data Science Team
      email: ds-team@empresa.com
```

Beneficios:
- En `dbt docs`, ves quién consume cada modelo
- Si cambias `fct_orders` v1 → v2, sabes a qué dashboards avisar
- Auditoría: "¿este modelo se puede eliminar?" → si no tiene exposures, sí

---

## ✅ Checklist de salida

- [ ] Definiste 4 groups (finance, marketing, product, data_platform)
- [ ] Cada modelo está asignado a un group
- [ ] Access modifiers configurados (protected en staging, public/private según mart)
- [ ] Probaste que un cross-group ref() falla en parse
- [ ] Tienes versioning configurado en al menos un modelo crítico
- [ ] GRANTs automáticos vía on-run-end hook
- [ ] Exposures documentando consumers downstream

---

## 🎓 Preguntas tipo entrevista senior

1. *"Tu CEO quiere que TODOS los analistas puedan acceder a TODOS los datos. Como Data Lead, ¿qué le respondes?"*
   → Acceso ≠ visibilidad. Todos PUEDEN ver TODO en el catálogo (búsqueda, dbt docs), pero el acceso real a datos sensibles (salaries, PII, financials) requiere request explícito con auditoría. Argumentos: compliance (GDPR, SOC2), reducción de blast radius en breaches, cultura de "data ownership" responsable.

2. *"Vas a deprecar fct_orders_v1. ¿Cómo lo comunicas?"*
   → (1) Marcar `deprecation_date` en el yaml. (2) Email/Slack a owners de exposures que lo usan. (3) dbt warning en cada run. (4) 30 días antes del deadline, agregar `severity: error` en algún test que fuerce el upgrade. (5) Después del deadline, transformar v1 en view sobre v2. (6) Después de N meses sin uso, eliminar.

3. *"Un equipo quiere acceso de WRITE a un schema de otro equipo. ¿Qué les ofreces?"*
   → No. En su lugar: (a) el equipo dueño expone una **public model** con el dato que necesitan, o (b) el equipo solicitante crea su propio mart con `ref()` al modelo dueño, o (c) se crea un mart en `data_platform` que ambos comparten. Escribir directo al schema ajeno rompe ownership y auditoría.

---

➡️ **Siguiente:** [Lab 14 — Cost optimization + Semantic Layer](./lab_14_cost_optimization_semantic_layer.md)
