# 🧪 Lab 08 — Late-arriving facts y reconciliación

**Nivel:** Avanzado 🔴
**Tiempo estimado:** 2 horas
**Dominios cubiertos:** Late-arriving data, lookback windows, reconciliación, idempotencia
**Objetivo de negocio:** "Las transacciones bancarias ocurren un día pero a veces llegan a nuestro warehouse 3-7 días después (por sistemas legacy). Nuestro fact diario muestra revenue incorrecta porque no captura las que llegaron tarde. ¿Cómo lo arreglamos sin reprocesar 2 años de historia cada día?"

---

## 🎯 Lo que vas a aprender

1. La diferencia entre `event_time` y `ingested_at` (crítica)
2. Patrón de lookback window con incremental
3. Idempotencia: que correr 2 veces dé el mismo resultado
4. Detectar y alertar sobre datos late-arriving anómalos
5. Reconciliación periódica (full refresh selectivo)

## El problema con un ejemplo concreto

Hoy es 28 de mayo. Tu pipeline corrió anoche y construyó `fct_revenue_daily`:

| transaction_date | total_usd |
|---|---|
| 2026-05-25 | $1,200 |
| 2026-05-26 | $1,500 |
| 2026-05-27 | $1,800 |

Pero hoy en `RAW_TRANSACTIONS` aparecen 5 transacciones con `transaction_date = 2026-05-26` y `ingested_at = 2026-05-28 14:00` (llegaron HOY). Sin lookback, tu fact muestra $1,500 para el 26, pero el valor real ahora es $1,800.

**Tu dashboard miente.**

---

## Paso 1 — Entender las dos fechas (15 min)

En los seeds, `raw_transactions` tiene DOS columnas de fecha:
- `transaction_date`: cuando ocurrió la transacción (el evento)
- `ingested_at`: cuando llegó al warehouse

```sql
-- Cuántas transacciones llegan tarde:
SELECT
    DATEDIFF('day', transaction_date, ingested_at) as lag_days,
    COUNT(*) as transactions
FROM BOOTCAMP_DB.RAW.RAW_TRANSACTIONS
GROUP BY 1
ORDER BY 1;
```

Verás distribución: la mayoría llega el mismo día, pero hay cola de 1, 2, 5, 30 días.

> 💡 **Patrón Senior:** Todo source en tu warehouse debe tener AMBAS fechas. Si la herramienta de ingesta no agrega `ingested_at` (o `_loaded_at`), pídeselo al equipo de data ingestion. Sin esa columna, late-arriving es invisible.

---

## Paso 2 — Modelo NAIVE (que tiene el bug) (15 min)

`models/marts/finance/fct_revenue_daily_naive.sql`:

```sql
{{
  config(
    materialized='incremental',
    unique_key='transaction_date',
    incremental_strategy='merge'
  )
}}

select
    transaction_date,
    count(*)                                          as transaction_count,
    sum(case when transaction_type = 'debit' then amount end)    as total_debit,
    sum(case when transaction_type = 'refund' then amount end)   as total_refunds,
    sum(case when transaction_type = 'debit' then amount
             when transaction_type = 'refund' then -amount end)  as net_revenue
from {{ ref('stg_transactions') }}

{% if is_incremental() %}
  -- ❌ BUG: este filtro asume que NO hay late-arriving
  where transaction_date > (select max(transaction_date) from {{ this }})
{% endif %}

group by transaction_date
```

Corre 2 veces (`dbt run` dos veces) y verifica:

```sql
-- Comparar con la verdad (recálculo completo)
WITH truth AS (
    SELECT
        transaction_date,
        COUNT(*) AS true_count,
        SUM(CASE WHEN transaction_type='debit' THEN amount
                 WHEN transaction_type='refund' THEN -amount END) AS true_net
    FROM BOOTCAMP_DB.RAW.RAW_TRANSACTIONS
    GROUP BY 1
)
SELECT
    n.transaction_date,
    n.transaction_count, t.true_count, t.true_count - n.transaction_count AS diff_count,
    n.net_revenue, t.true_net, t.true_net - n.net_revenue AS diff_net
FROM fct_revenue_daily_naive n
JOIN truth t ON n.transaction_date = t.transaction_date
WHERE t.true_count != n.transaction_count OR ABS(t.true_net - n.net_revenue) > 0.01
ORDER BY 1;
```

Vas a ver discrepancias. Esos son los late-arriving que el modelo naive perdió.

---

## Paso 3 — Modelo CORRECTO con lookback window (30 min)

`models/marts/finance/fct_revenue_daily.sql`:

```sql
{{
  config(
    materialized='incremental',
    unique_key='transaction_date',
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
  )
}}

select
    transaction_date,
    count(*)                                                     as transaction_count,
    sum(case when transaction_type = 'debit'  then amount end)   as total_debit,
    sum(case when transaction_type = 'refund' then amount end)   as total_refunds,
    sum(case when transaction_type = 'debit'  then amount
             when transaction_type = 'refund' then -amount end)  as net_revenue,

    -- Métricas de calidad: cuántas llegaron tarde
    count(case when ingested_at::date > transaction_date then 1 end) as late_arriving_count,
    max(ingested_at)                                             as latest_ingestion_seen,

    current_timestamp                                            as dbt_loaded_at

from {{ ref('stg_transactions') }}

{% if is_incremental() %}
  -- ✅ Lookback de 14 días: reprocesa las últimas 2 semanas SIEMPRE
  -- 14 días cubre el 99.9% de los late-arriving en este dataset
  where transaction_date >= (
      select dateadd('day', -14, max(transaction_date)) from {{ this }}
  )
{% endif %}

group by transaction_date
```

**Combinado con `unique_key + merge`**, el lookback funciona así:

1. Cada corrida reprocesa los últimos 14 días desde el source.
2. `merge` actualiza las filas existentes con los nuevos totales (capturando los late-arrivers).
3. Filas viejas que NO se tocaron quedan intactas.

> ⚠️ **Error de principiante #1:** Hacer el lookback sin `merge`. Si usas `incremental_strategy='append'` con lookback, vas a duplicar filas. Lookback REQUIERE merge (o delete+insert).

> ⚠️ **Error de principiante #2:** Lookback demasiado corto. 1 día es típico pero deja escapar el 5% de los late-arrivers. 30 días es seguro pero ya es muy pesado. **El balance correcto se mide:** consulta la distribución de `DATEDIFF(day, transaction_date, ingested_at)` en tu source. Elige el percentil 99 + 2 días de buffer.

---

## Paso 4 — Idempotencia: el test del Senior (20 min)

Idempotencia significa: **correr el modelo 1 vez o 10 veces seguidas produce EL MISMO resultado**.

Si tu lookback está bien, esto se cumple. Si tu modelo es no-idempotente, tienes un bug oculto.

**Test de idempotencia:**

```bash
# Corre el modelo
dbt run -s fct_revenue_daily

# Guarda un snapshot del resultado
```

```sql
CREATE OR REPLACE TABLE BOOTCAMP_DB.DEV_JULIO.test_idempotency_v1 AS
SELECT * FROM fct_revenue_daily ORDER BY transaction_date;
```

```bash
# Corre OTRA VEZ sin cambiar el source
dbt run -s fct_revenue_daily
```

```sql
-- Compara
SELECT *
FROM (
    SELECT * FROM fct_revenue_daily MINUS SELECT * FROM test_idempotency_v1
    UNION ALL
    SELECT * FROM test_idempotency_v1 MINUS SELECT * FROM fct_revenue_daily
);
-- Debe devolver 0 filas
```

Si devuelve filas, **NO eres idempotente**. Algo cambia entre corridas (típicamente `current_timestamp` en una métrica de negocio).

---

## Paso 5 — Reconciliación periódica (full refresh selectivo) (20 min)

El lookback de 14 días captura el 99.9% de los late-arrivers. Pero el 0.1% que llega después de 14 días se pierde.

**Solución:** programa un `--full-refresh` semanal de los últimos 90 días.

`macros/refresh_last_n_days.sql`:

```sql
{% macro refresh_last_n_days(model_name, days=90) %}

    {% set sql %}
        delete from {{ ref(model_name) }}
        where transaction_date >= dateadd('day', -{{ days }}, current_date)
    {% endset %}

    {% do log("Reconciliando " ~ model_name ~ ": borrando últimos " ~ days ~ " días", info=true) %}
    {% do run_query(sql) %}

    -- Después de borrar, el próximo `dbt run` los reconstruye desde scratch
    -- gracias al `merge` con unique_key

{% endmacro %}
```

**Job en dbt Cloud (programado los domingos):**

```bash
dbt run-operation refresh_last_n_days --args '{"model_name": "fct_revenue_daily", "days": 90}'
dbt run -s fct_revenue_daily
```

Esto reconstruye los últimos 90 días desde cero. Mensualmente puedes hacerlo de 365 días. Trimestralmente, todo.

> 💡 **Patrón Senior:** Pipeline con 3 frecuencias:
> - **Diario:** incremental con lookback corto (14 días)
> - **Semanal:** reconciliation de 90 días
> - **Mensual:** full refresh de todo el histórico
>
> Es el "defense in depth" del data engineering.

---

## Paso 6 — Detección de anomalías en late-arriving (20 min)

Tu modelo ahora tiene `late_arriving_count` por día. Crea un test que alerte si hay un día con MUCHOS late-arrivers (puede ser síntoma de un problema upstream):

`tests/anomalous_late_arriving.sql`:

```sql
-- Detecta días donde más del 10% de las transacciones llegaron tarde
-- Solo evalúa días con al menos 50 transacciones (para evitar ruido)
select
    transaction_date,
    transaction_count,
    late_arriving_count,
    round(late_arriving_count * 100.0 / transaction_count, 1) as late_pct
from {{ ref('fct_revenue_daily') }}
where transaction_count >= 50
  and late_arriving_count * 100.0 / transaction_count > 10
  and transaction_date >= dateadd('day', -30, current_date)
```

```yaml
- name: fct_revenue_daily
  tests:
    - dbt_utils.expression_is_true:
        expression: "late_arriving_count <= transaction_count"
```

---

## 🧠 Lo que solo se aprende con experiencia

1. **Late-arriving es UNIVERSAL.** No solo bancos. APIs con retries, IoT con conectividad intermitente, sistemas legacy con sync nocturno, fusiones con sistemas de la empresa adquirida. **Asume late-arriving por default.** Si tu sistema no lo tiene, eventualmente lo tendrá.

2. **`ingested_at` debe ser inmutable.** Si tu herramienta de ingestion la actualiza en cada sync (mal hecho), pierdes la capacidad de detectar late-arriving. Debe ser "primera vez que esta fila apareció", no "última vez que la actualizamos".

3. **Idempotencia es la propiedad mágica.** Una pipeline idempotente es:
   - Trivial de re-correr ante un fallo
   - Trivial de hacer backfill
   - Trivial de testear (`audit_helper.compare_queries`)
   - Trivial de auditar

   Romper idempotencia (con `current_timestamp` en métricas, con `random()`, con valores que dependen del horario) es de los peores anti-patterns. **Si lo haces, documéntalo a fuego.**

4. **El verdadero costo de no manejar late-arriving:** se descubre cuando Finance reporta números al CFO basados en el dashboard, y 3 semanas después un auditor encuentra una diferencia con los reportes oficiales del banco. Eso destruye la confianza en el data team. **Vale la pena el costo extra del lookback.**

5. **Para volúmenes verdaderamente masivos (Netflix-scale), microbatch es mejor que lookback.** Lookback procesa N días enteros cada corrida. Microbatch procesa solo los batches que dbt sabe que cambiaron. Lo veremos en Lab 10.

---

## ✅ Checklist Lab 08

- [ ] Verificaste que tu raw tiene `transaction_date` E `ingested_at`
- [ ] Versión naive corrida y comparada con la verdad (diferencias visibles)
- [ ] Versión con lookback corrida 2 veces (idempotencia OK)
- [ ] Macro `refresh_last_n_days` funcionando
- [ ] Test de anomalía de late-arriving operativo

---

## 🔜 Próximo lab

**Lab 09 — Multi-currency y conversión FX como problema clásico.** Vas a unir transacciones en MXN, USD, EUR, BRL con la tabla de tasas FX y producir un fact en USD para reporting consolidado. Es el caso clásico de joins temporales correctos.
