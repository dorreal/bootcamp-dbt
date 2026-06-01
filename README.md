# 🎓 Bootcamp dbt + Snowflake: Junior a Senior

> **Para Julio César Pérez** — 14 laboratorios progresivos diseñados para llevarte de "hola dbt" a resolver problemas de Senior Data Engineer en Netflix/Amazon.

---

## 🎯 ¿Qué vas a aprender?

Este bootcamp **no es un tutorial más de dbt**. Es un track diseñado para que al terminarlo:

- Puedas defender una **entrevista de Senior Data Engineer**
- Estés listo para la **dbt Analytics Engineer Certification**
- Hayas resuelto los **mismos problemas que enfrentan equipos en Netflix, Amazon, Airbnb**
- Tengas un **portfolio público** demostrable

---

## 📁 Estructura del proyecto

```
bootcamp/
├── README.md                            ← estás aquí
│
├── 00_setup/                            ← scripts de inicialización
│   ├── 01_snowflake_setup.sql           ← warehouse, DB, schemas, roles
│   ├── 02_load_raw_data.sql             ← carga de raw data
│   ├── dbt_project.yml                  ← plantilla de proyecto
│   └── packages.yml                     ← dependencias dbt
│
├── seeds/                               ← CSVs para cargar a Snowflake
│   ├── ecommerce/                       ← 6 archivos (customers, orders, products, ...)
│   ├── clickstream/                     ← 3 archivos (eventos, users, content)
│   └── finance/                         ← 3 archivos (transactions, fx_rates, chargebacks)
│
├── generators/                          ← Python para regenerar seeds
│   ├── build_seeds.py
│   └── 03_synthetic_data_at_scale.sql   ← genera 10M+ eventos
│
└── labs/                                ← 14 laboratorios progresivos
    ├── lab_01_setup_y_primera_conexion.md
    ├── lab_02_staging_completo_codegen.md
    ├── ...
    └── lab_14_cost_optimization_semantic_layer.md
```

---

## 🛣️ Ruta de aprendizaje

| Fase | Labs | Nivel | Foco |
|------|------|-------|------|
| **Fundamentos** | 01-03 | 🟢 Básico | Setup, staging, modelado en capas |
| **Modelado** | 04-06 | 🟢🟡 Intermedio | Surrogate keys, materializaciones, dim_date |
| **Históricos** | 07-09 | 🟡 Intermedio | Snapshots SCD2, late-arriving, multi-currency |
| **Escala** | 10-12 | 🔴 Avanzado | Microbatch, data quality, backfills masivos |
| **Senior** | 13-14 | 🔴🔴 Senior | Multi-tenancy, cost optimization, semantic layer |

### Detalle por lab

| # | Lab | Tiempo | Nivel |
|---|-----|--------|-------|
| 01 | [Setup y primera conexión](./labs/lab_01_setup_y_primera_conexion.md) | 60 min | 🟢 |
| 02 | [Staging completo + codegen](./labs/lab_02_staging_completo_codegen.md) | 90 min | 🟢 |
| 03 | [Intermediate y marts](./labs/lab_03_intermediate_y_marts.md) | 90 min | 🟢 |
| 04 | [Surrogate keys cross-domain](./labs/lab_04_surrogate_keys_cross_domain.md) | 75 min | 🟢🟡 |
| 05 | [Materializaciones a fondo](./labs/lab_05_materializaciones_a_fondo.md) | 90 min | 🟡 |
| 06 | [dim_date conformed](./labs/lab_06_dim_date_conformed.md) | 60 min | 🟡 |
| 07 | [Snapshots SCD2](./labs/lab_07_snapshots_scd2.md) | 90 min | 🟡 |
| 08 | [Late-arriving facts](./labs/lab_08_late_arriving.md) | 90 min | 🟡 |
| 09 | [Multi-currency FX](./labs/lab_09_multi_currency_fx.md) | 90 min | 🔴 |
| 10 | [Microbatch eventos masivos](./labs/lab_10_microbatch_eventos_masivos.md) | 120 min | 🔴🔴 |
| 11 | [Data Quality Framework](./labs/lab_11_data_quality_framework.md) | 120 min | 🔴🔴 |
| 12 | [Backfills masivos](./labs/lab_12_backfills_masivos.md) | 100 min | 🔴🔴 |
| 13 | [Multi-tenancy & governance](./labs/lab_13_multitenancy_governance.md) | 100 min | 🔴🔴 |
| 14 | [Cost optimization + Semantic Layer](./labs/lab_14_cost_optimization_semantic_layer.md) | 120 min | 🔴🔴 |

**Total estimado: ~22 horas de práctica activa.**

---

## 🚀 Cómo empezar (15 minutos)

### Pre-requisitos

- ✅ Cuenta de Snowflake (tienes: `VV98790`)
- ✅ Cuenta de dbt Cloud (tienes: proyecto "Analytics" en trial)
- ✅ Git instalado (para clonar este repo si quieres versionarlo)

### Paso 1 — Setup de Snowflake

Abre Snowsight y ejecuta en orden:

```sql
-- 1. Crea warehouse, database, schemas, roles
@00_setup/01_snowflake_setup.sql

-- 2. Crea estructuras vacías para raw data
@00_setup/02_load_raw_data.sql
```

### Paso 2 — Cargar seeds

En dbt Cloud:
1. Conecta tu repo (o crea uno nuevo)
2. Copia el contenido de `00_setup/dbt_project.yml`, `00_setup/packages.yml` y `seeds/` a tu proyecto
3. Ejecuta:
   ```bash
   dbt deps
   dbt seed
   ```

### Paso 3 — Empieza por el Lab 01

```bash
open labs/lab_01_setup_y_primera_conexion.md
```

Sigue el orden numérico. Cada lab tiene un link al siguiente al final.

---

## 📊 Casos de negocio cubiertos (Netflix/Amazon-style)

✅ **Slowly Changing Dimensions (SCD2)** — Lab 07
Reconstruir el estado histórico de un cliente: "¿Qué plan tenía Juan el 15 de marzo?"

✅ **Late-arriving facts** — Lab 08
Transacciones que llegan 5 días tarde por fallas de red. Reconciliación sin reprocesar todo.

✅ **Multi-currency revenue** — Lab 09
Convertir 4 monedas a USD usando la tasa del día de la transacción, manejando huecos de fines de semana.

✅ **Procesamiento a escala (10M+ eventos/día)** — Lab 10
Microbatch con backfill quirúrgico, idempotente.

✅ **Data Quality Framework** — Lab 11
5 capas de defensa: contracts > tests críticos > expectations > freshness > anomaly detection.

✅ **Backfills históricos** — Lab 12
Reprocesar 3 años sin tumbar el warehouse, con tracking de progreso y recovery.

✅ **Multi-tenancy** — Lab 13
4 equipos compartiendo un mismo dbt project sin pisarse: groups, access modifiers, version, exposures.

✅ **Cost optimization** — Lab 14
Bajar el bill de Snowflake 30% con QUERY_HISTORY analysis, refactoring con audit_helper, Slim CI.

✅ **Semantic Layer** — Lab 14
Una sola definición de "revenue" para Tableau, Looker, Hex, código.

---

## 🧠 Filosofía del bootcamp

Cada lab incluye 4 secciones que NO ves en tutoriales típicos:

### 🎯 "Lo que vas a aprender"
Lista clara de skills concretos.

### ⚠️ "Errores típicos de principiante"
Los baches que **todos** cometemos la primera vez. Para que tú no.

### 💡 "Lo que solo se aprende con experiencia"
Decisiones que solo entiendes después de 3 años en producción. Heurísticas, anti-patterns, trade-offs.

### 🎓 "Preguntas tipo entrevista senior"
Las preguntas reales que te van a hacer en una entrevista de Senior DE. Con respuesta razonada.

---

## 🛠️ Stack tecnológico

| Componente | Tecnología |
|------------|------------|
| Data warehouse | **Snowflake** (cuenta trial) |
| Transformation | **dbt Cloud** (UI-first) |
| Languages | **SQL** + **Jinja** |
| Packages | dbt_utils, dbt_expectations, dbt_date, codegen, audit_helper |
| Source control | Git (recomendado: GitHub público para portfolio) |

---

## 📚 Materiales complementarios

En la carpeta `/mnt/user-data/outputs/`:

1. **`dbt_guia_certificacion.docx`** — Guía teórica de los 7 dominios del exam
2. **`dbt_preguntas_optimizacion.docx`** — 35 preguntas tipo examen + 7 técnicas de optimización

---

## 🎯 ¿Qué hacer después de terminar?

1. **Empuja todo a GitHub público** con README profesional. Esto es portfolio.
2. **Toma el examen de certificación**: ya estarás técnica y teóricamente listo.
3. **Construye contenido**: aquí tienes material para 14 episodios de "El Universo Spark" sobre dbt + Snowflake en español.
4. **El siguiente nivel** es agregar **Airflow** (orquestación) y **Databricks/Spark** (escala masiva). Ambos están en tu lista de aprendizaje.

---

## 💬 Notas finales

Este bootcamp está diseñado para **practicar sin asistencia**. Todo el código está completo y ejecutable. Si te atoras en algún paso, regresa a la sección "Errores típicos de principiante" del lab — probablemente el problema esté ahí.

**Estimación realista:** Si haces 1 lab por noche, terminas en 2-3 semanas. Si haces uno por fin de semana, en 3-4 meses. **Lo importante no es la velocidad, es ejecutar cada paso, no solo leerlo.**

Buena suerte, Julio. 🚀

---

*Bootcamp construido en mayo 2026 — dbt 1.9 + Snowflake — Cuenta de práctica: VV98790*
