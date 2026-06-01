# 🧪 Lab 01 — Tu primera conexión dbt Cloud ↔ Snowflake

**Nivel:** Básico 🟢
**Tiempo estimado:** 60-90 minutos
**Dominios cubiertos:** Setup, conexión, primer modelo
**Objetivo de negocio:** "Conectar dbt a nuestro warehouse y crear nuestro primer modelo transformado."

---

## 🎯 Lo que vas a aprender

1. Configurar Snowflake (warehouse, database, schemas, roles) siguiendo prácticas de producción
2. Conectar dbt Cloud a Snowflake con el rol correcto (NO `ACCOUNTADMIN`)
3. Inicializar un proyecto dbt y entender la estructura de carpetas
4. Crear tu primer modelo `stg_customers` y materializarlo

## 📋 Pre-requisitos

- Cuenta Snowflake activa (la tuya: **VV98790**)
- Cuenta dbt Cloud (ya creada según tu captura)
- Acceso al rol `ACCOUNTADMIN` por una vez (para el setup)

---

## Paso 1 — Setup de Snowflake (15 min)

Abre **Snowsight** (la UI de Snowflake), crea un worksheet nuevo y ejecuta el archivo `00_setup/01_snowflake_setup.sql` del bootcamp.

Lo que crea:

| Objeto | Nombre | Propósito |
|---|---|---|
| Warehouse | `BOOTCAMP_WH` | Cómputo dedicado al bootcamp (XS, auto-suspend 60s) |
| Database | `BOOTCAMP_DB` | Contenedor de schemas |
| Schema | `RAW` | Datos crudos (lo que vendría de Fivetran) |
| Schema | `ANALYTICS` | Marts finales producidos por dbt |
| Schema | `DEV_JULIO` | Tu sandbox personal de desarrollo |
| Rol | `TRANSFORMER` | Rol que usará dbt (NUNCA `ACCOUNTADMIN`) |
| Rol | `REPORTER` | Solo lectura, para analistas |

> ⚠️ **Error de principiante #1:** Conectar dbt con `ACCOUNTADMIN`. Si tu código tiene un bug, podría borrar objetos críticos de toda la cuenta. Siempre usa un rol con permisos limitados (`TRANSFORMER`).

**Asigna el rol a tu usuario:**

```sql
GRANT ROLE TRANSFORMER TO USER <TU_USUARIO_SNOWFLAKE>;
```

Para saber tu usuario:
```sql
SELECT CURRENT_USER();
```

---

## Paso 2 — Cargar los datos raw (20 min)

Tienes **dos opciones**. Te recomiendo la opción A para este primer lab.

### Opción A — Usar dbt seeds (más simple)

1. Más adelante (Paso 4), cuando tengas el proyecto dbt creado, copia los CSVs de `seeds/ecommerce/`, `seeds/clickstream/` y `seeds/finance/` a la carpeta `seeds/` de tu proyecto dbt.
2. Corre `dbt seed`.

### Opción B — Carga manual con COPY INTO (más realista)

1. Sube los CSVs al stage de Snowflake (desde Snowsight: `Data → Databases → BOOTCAMP_DB → RAW → Stages → BOOTCAMP_STAGE → "+ Files"`).
2. Ejecuta `00_setup/02_load_raw_data.sql`.

> 💡 **Consejo Senior:** En proyectos reales casi nunca usas `seeds` para datos transaccionales. Seeds están pensadas para *datos de referencia pequeños* (códigos de país, tasas de IVA, etc.). Los datos transaccionales llegan al warehouse por ETL/ELT (Fivetran, Airbyte, Snowpipe). Usamos seeds aquí solo por simplicidad educativa.

---

## Paso 3 — Conectar dbt Cloud a Snowflake (15 min)

En la UI de dbt Cloud (tu captura mostraba esta pantalla):

1. **Connection**: clic en "Select..." y elige **Snowflake**.
2. Llena los campos:

| Campo | Valor | Notas |
|---|---|---|
| **Account** | `VV98790` (o el identificador completo de tu Snowflake) | El que ves en la URL de Snowsight |
| **Database** | `BOOTCAMP_DB` | |
| **Warehouse** | `BOOTCAMP_WH` | |
| **Role** | `TRANSFORMER` | ⚠️ NO `ACCOUNTADMIN` |
| **Username** | Tu usuario Snowflake | |
| **Auth method** | Username/Password (más simple) o Key Pair (más seguro) | |
| **Schema** | `DEV_JULIO` | Tu sandbox personal |
| **Threads** | 4 | Sube a 8 cuando tengas más modelos |

3. Clic en **Test Connection**. Debes ver "Connection successful".

> ⚠️ **Error de principiante #2:** Poner el schema `ANALYTICS` en el conector de desarrollo. Esto provoca que cuando hagas `dbt run` desde la UI, escribas en el schema de producción y pises los datos. **Cada developer debe tener su propio schema de desarrollo** (`DEV_<NOMBRE>`).

---

## Paso 4 — Inicializar el proyecto dbt (10 min)

Aún en dbt Cloud:

1. Ya tienes "Analytics" como nombre del proyecto (según tu captura). Está bien.
2. **Set up a repository**: usa "Managed by dbt Labs" para este lab (más simple); en labs avanzados conectarás un repo de GitHub propio.
3. Abre el **Studio** (botón izquierdo) → te abre el IDE web.

La estructura inicial luce así:

```
analytics/
├── dbt_project.yml         ← config del proyecto
├── models/
│   └── example/            ← borra esta carpeta de ejemplo
│       ├── my_first_dbt_model.sql
│       └── my_second_dbt_model.sql
├── seeds/                  ← acá pondrás los CSVs
├── macros/
├── tests/
└── snapshots/
```

**Acciones:**

1. **Borra la carpeta `models/example/`** completa (es boilerplate inútil).
2. Reemplaza tu `dbt_project.yml` con el contenido de `00_setup/dbt_project.yml` del bootcamp, pero cambia la línea `name: 'bootcamp'` por `name: 'analytics'` (debe coincidir con el nombre que dbt Cloud espera).
3. Crea el archivo `packages.yml` en la raíz, con el contenido del bootcamp.
4. Crea la estructura de carpetas:

```
models/
├── staging/
│   ├── ecommerce/
│   ├── clickstream/
│   └── finance/
├── intermediate/
└── marts/
    ├── ecommerce/
    ├── clickstream/
    └── finance/
```

5. En el terminal de dbt Cloud (esquina inferior), corre:

```bash
dbt deps
```

Esto descarga `dbt_utils` y los otros packages.

---

## Paso 5 — Tu primer source y staging model (15 min)

### 5.1 Declarar el source

Crea `models/staging/ecommerce/_sources.yml`:

```yaml
version: 2

sources:
  - name: raw_ecommerce
    description: "Datos crudos del sistema de ecommerce (cargados por COPY INTO o seed)"
    database: BOOTCAMP_DB
    schema: RAW
    tables:
      - name: raw_customers
        description: "Tabla de clientes registrados"
        columns:
          - name: id
            description: "ID único del cliente"
            tests:
              - unique
              - not_null
      - name: raw_orders
      - name: raw_products
      - name: raw_order_items
      - name: raw_payments
```

### 5.2 Crear el primer modelo de staging

Crea `models/staging/ecommerce/stg_customers.sql`:

```sql
{{
  config(
    materialized='view'
  )
}}

with source as (
    select * from {{ source('raw_ecommerce', 'raw_customers') }}
),

renamed as (
    select
        -- IDs
        id as customer_id,

        -- Atributos
        first_name,
        last_name,

        -- Limpieza de email: trim espacios y lowercase
        -- (recuerda: los seeds tienen ruido a propósito)
        lower(trim(email)) as email,

        -- Fechas
        signup_date

    from source
    -- Excluir clientes sin email (en producción, esto se decide con el negocio)
    where email is not null and trim(email) != ''
)

select * from renamed
```

### 5.3 Documentar el modelo

Crea `models/staging/ecommerce/_models.yml`:

```yaml
version: 2

models:
  - name: stg_customers
    description: "Clientes con email limpio y normalizado"
    columns:
      - name: customer_id
        description: "Identificador único del cliente"
        tests:
          - unique
          - not_null
      - name: email
        description: "Email en minúsculas y sin espacios"
        tests:
          - not_null
```

### 5.4 Ejecutar y verificar

En el terminal de dbt Cloud:

```bash
dbt run -s stg_customers
dbt test -s stg_customers
```

Si todo va bien, ve a Snowsight y verifica:

```sql
SELECT COUNT(*) FROM BOOTCAMP_DB.DEV_JULIO_STAGING.STG_CUSTOMERS;
SELECT * FROM BOOTCAMP_DB.DEV_JULIO_STAGING.STG_CUSTOMERS LIMIT 5;
```

> ⚠️ **Error de principiante #3:** Olvidar el `_` antes del nombre de un YAML (`_sources.yml`, `_models.yml`). dbt los procesa igual con cualquier nombre, pero la convención del prefijo `_` hace que se ordenen al inicio de la carpeta en el IDE y sean fáciles de identificar. Equipos senior siempre los nombran así.

---

## 🧠 Lo que solo se aprende con experiencia

1. **Schema de desarrollo ≠ schema de producción.** En equipos serios cada developer tiene su propio schema (`DEV_JULIO`, `DEV_RUBI`, etc.) y producción es un schema separado al que solo se llega vía CI/CD. Nadie corre `dbt run` apuntando a producción manualmente.

2. **Los datos raw nunca se tocan.** Tu staging es la *primera vez* que dbt lee los datos. Si haces lógica de negocio aquí, otros equipos no podrán reconstruirla. Mantén staging 1:1 con el source: renombrar, castear tipos, limpiar nulls obvios. Punto.

3. **Convención de nombres salva proyectos.** `stg_<source>_<entidad>` para staging, `int_<dominio>_<descripción>` para intermediate, `dim_<entidad>` y `fct_<proceso>` para marts. Tener nombres predecibles es la diferencia entre un proyecto de 500 modelos navegable y uno inmantenible.

4. **`source()` no es opcional.** Podrías escribir `from BOOTCAMP_DB.RAW.RAW_CUSTOMERS` directo y funcionaría. Pero perderías el DAG: dbt no sabría que tu modelo depende de ese raw, no podría hacer freshness checks, y al cambiar de cuenta Snowflake romperías todo. **Siempre `source()` o `ref()`. Nunca SQL directo a una tabla.**

---

## ✅ Checklist de salida del Lab 01

- [ ] Snowflake configurado con rol `TRANSFORMER` (no usas `ACCOUNTADMIN`)
- [ ] dbt Cloud conectado, "Test Connection" exitoso
- [ ] Carpeta `models/example/` borrada
- [ ] `dbt_project.yml` y `packages.yml` configurados
- [ ] `dbt deps` ejecutado sin errores
- [ ] `stg_customers` creado, documentado y testeado
- [ ] La tabla resultante se ve en Snowflake con la limpieza aplicada

---

## 🔜 Próximo lab

**Lab 02 — Staging completo del dominio ecommerce.** Crearás todos los modelos de staging del dominio ecommerce usando el package `codegen` para acelerar el boilerplate, e introduciremos el concepto de macros reutilizables.
