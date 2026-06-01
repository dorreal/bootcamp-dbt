"""
Generador de seeds para el bootcamp dbt.
Crea CSVs realistas para 3 dominios: ecommerce, clickstream, finance.

Diseño:
- Tamaños chicos (seeds están pensadas para datos de referencia, no big data).
- Datos con "ruidos" intencionales para que los labs de data quality tengan algo que detectar.
- Fechas relativas a hoy para que los labs de freshness funcionen al correrlos.
"""
import csv
import random
import os
from datetime import datetime, timedelta
from pathlib import Path

random.seed(42)  # reproducible
HERE = Path(__file__).resolve().parent
SEEDS = HERE.parent / "seeds"
TODAY = datetime(2026, 5, 28)  # fecha fija para que los labs sean reproducibles

def write_csv(path: Path, headers, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(headers)
        w.writerows(rows)
    print(f"  ✓ {path.relative_to(HERE.parent)}  ({len(rows)} filas)")

# =========================================================
# DOMINIO 1: ECOMMERCE (Jaffle Shop extendido)
# =========================================================
print("\n[1/3] Generando seeds de ecommerce...")

# --- raw_customers ---
customer_rows = []
first_names = ["Michael","Shawn","Kathleen","Jennifer","Lisa","Robert","Sarah","Daniel","Mary","Mateo","Brian","Patricia","Anna","Carlos","Sofia","David","Maria","Luis","Elena","James","Olivia","Noah","Emma","Liam","Ava"]
last_names = ["Perez","Smith","King","Brown","Davis","Wilson","Martinez","Anderson","Taylor","Lopez","Garcia","Hernandez","Gonzalez","Rodriguez","Lee","Walker","Hall","Young","Allen","Wright"]
for cid in range(1, 101):
    fn = random.choice(first_names)
    ln = random.choice(last_names)
    # Intencional: algunos emails en mayúsculas y con espacios (lab de limpieza)
    email_variants = [
        f"{fn.lower()}.{ln.lower()}@example.com",
        f"{fn.upper()}.{ln.lower()}@example.com",
        f"  {fn.lower()}{ln.lower()}@example.com  ",
    ]
    email = random.choice(email_variants)
    signup_date = TODAY - timedelta(days=random.randint(30, 900))
    # 5% de clientes sin email (NULL) para tests de not_null
    if random.random() < 0.05:
        email = ""
    customer_rows.append([cid, fn, ln, email, signup_date.strftime("%Y-%m-%d")])

write_csv(SEEDS/"ecommerce"/"raw_customers.csv",
          ["id","first_name","last_name","email","signup_date"], customer_rows)

# --- raw_products ---
products_data = [
    (1, "Espresso", "beverages", 350),
    (2, "Cappuccino", "beverages", 450),
    (3, "Latte", "beverages", 500),
    (4, "Americano", "beverages", 400),
    (5, "Cold Brew", "beverages", 550),
    (6, "Croissant", "bakery", 350),
    (7, "Muffin", "bakery", 300),
    (8, "Bagel", "bakery", 400),
    (9, "Cookie", "bakery", 200),
    (10, "Donut", "bakery", 250),
    (11, "Sandwich", "food", 850),
    (12, "Salad", "food", 950),
    (13, "Wrap", "food", 750),
    (14, "Soup", "food", 650),
    (15, "Pasta", "food", 1100),
]
product_rows = []
for pid, name, cat, price_cents in products_data:
    is_active = "true" if random.random() > 0.1 else "false"
    product_rows.append([pid, name, cat, price_cents, is_active])
# Producto intencionalmente DUPLICADO (lab de detección)
product_rows.append([15, "Pasta", "food", 1100, "true"])
write_csv(SEEDS/"ecommerce"/"raw_products.csv",
          ["product_id","product_name","category","price_cents","is_active"], product_rows)

# --- raw_orders ---
order_rows = []
statuses = ["placed", "shipped", "completed", "completed", "completed", "returned"]
for oid in range(1, 501):
    cust_id = random.randint(1, 100)
    order_date = TODAY - timedelta(days=random.randint(0, 730))
    status = random.choice(statuses)
    # 2% de órdenes con customer_id que no existe (lab de relationships test)
    if random.random() < 0.02:
        cust_id = random.randint(900, 999)
    order_rows.append([oid, cust_id, order_date.strftime("%Y-%m-%d"), status])
write_csv(SEEDS/"ecommerce"/"raw_orders.csv",
          ["order_id","customer_id","order_date","status"], order_rows)

# --- raw_order_items ---
item_rows = []
line_id = 1
for oid in range(1, 501):
    n_items = random.randint(1, 4)
    chosen = random.sample(range(1, 16), n_items)
    for pid in chosen:
        qty = random.randint(1, 3)
        # Precio en el momento de la orden (puede diferir del precio actual: lab SCD2)
        price_at_time = next(p[3] for p in products_data if p[0] == pid)
        # 3% de variación de precio histórica
        if random.random() < 0.3:
            price_at_time = int(price_at_time * random.uniform(0.85, 1.15))
        item_rows.append([line_id, oid, pid, qty, price_at_time])
        line_id += 1
write_csv(SEEDS/"ecommerce"/"raw_order_items.csv",
          ["line_id","order_id","product_id","quantity","price_cents_at_order"], item_rows)

# --- raw_payments ---
payment_rows = []
methods = ["credit_card","credit_card","credit_card","debit_card","paypal","apple_pay","gift_card"]
for oid in range(1, 501):
    n = random.randint(1, 2)  # algunas órdenes pagan en 2 métodos (split payments)
    for _ in range(n):
        amount = random.randint(500, 5000)
        payment_rows.append([len(payment_rows)+1, oid, random.choice(methods), amount])
write_csv(SEEDS/"ecommerce"/"raw_payments.csv",
          ["payment_id","order_id","payment_method","amount_cents"], payment_rows)

# --- raw_product_prices_history (para SCD2 lab) ---
price_history_rows = []
ph_id = 1
for pid, name, cat, base_price in products_data:
    # cada producto tiene 1-3 cambios de precio
    n_changes = random.randint(1, 3)
    current_price = int(base_price * 0.8)  # arranca 20% más barato
    valid_from = TODAY - timedelta(days=900)
    for i in range(n_changes):
        valid_to = valid_from + timedelta(days=random.randint(180, 400))
        if i == n_changes - 1:
            valid_to_str = ""  # último: vigente, sin fecha fin
        else:
            valid_to_str = valid_to.strftime("%Y-%m-%d")
        price_history_rows.append([ph_id, pid, current_price,
                                   valid_from.strftime("%Y-%m-%d"), valid_to_str])
        ph_id += 1
        current_price = int(current_price * random.uniform(1.03, 1.20))
        valid_from = valid_to
write_csv(SEEDS/"ecommerce"/"raw_product_prices_history.csv",
          ["price_history_id","product_id","price_cents","valid_from","valid_to"], price_history_rows)

# =========================================================
# DOMINIO 2: CLICKSTREAM (eventos web tipo Netflix/Amazon)
# =========================================================
print("\n[2/3] Generando seeds de clickstream...")

# --- raw_users (separado de customers a propósito: lab de identity resolution) ---
user_rows = []
device_types = ["mobile","mobile","desktop","tablet","tv"]
plans = ["free","basic","standard","premium","premium"]
for uid in range(1, 201):
    user_rows.append([
        f"u_{uid:05d}",
        random.choice(plans),
        random.choice(device_types),
        (TODAY - timedelta(days=random.randint(1, 1200))).strftime("%Y-%m-%d"),
        random.choice(["US","MX","BR","AR","ES","CO","CL","PE"])
    ])
write_csv(SEEDS/"clickstream"/"raw_users.csv",
          ["user_id","plan","primary_device","signup_date","country"], user_rows)

# --- raw_content (catálogo tipo Netflix) ---
content_rows = []
genres = ["drama","action","comedy","documentary","kids","thriller","sci-fi"]
content_types = ["movie","series","series","series","movie"]
for cid in range(1, 51):
    content_rows.append([
        f"c_{cid:04d}",
        f"Title_{cid}",
        random.choice(content_types),
        random.choice(genres),
        random.randint(2015, 2026),
        random.randint(60, 7200)  # duración en segundos
    ])
write_csv(SEEDS/"clickstream"/"raw_content.csv",
          ["content_id","title","content_type","genre","release_year","duration_seconds"], content_rows)

# --- raw_events (eventos de visualización, pequeño para seed; el lab grande usa generador SQL) ---
event_rows = []
event_types = ["play_start","play_pause","play_resume","play_complete","play_abandon"]
for i in range(1, 2001):
    user = f"u_{random.randint(1,200):05d}"
    content = f"c_{random.randint(1,50):04d}"
    event_time = TODAY - timedelta(
        days=random.randint(0, 60),
        hours=random.randint(0, 23),
        minutes=random.randint(0, 59),
        seconds=random.randint(0, 59)
    )
    # 1% de duplicados intencionales (lab de deduplicación)
    event_rows.append([
        f"e_{i:07d}",
        event_time.strftime("%Y-%m-%d %H:%M:%S"),
        user,
        content,
        random.choice(event_types),
        random.randint(0, 7200)
    ])
# Inyectar duplicados con el MISMO event_id
for _ in range(20):
    orig = random.choice(event_rows[:100])
    event_rows.append(orig.copy())
# Inyectar eventos con timestamp futuro (data quality: anomalía)
for _ in range(5):
    bad_time = TODAY + timedelta(days=random.randint(1, 30))
    event_rows.append([
        f"e_BAD{random.randint(1,99):02d}",
        bad_time.strftime("%Y-%m-%d %H:%M:%S"),
        f"u_{random.randint(1,200):05d}",
        f"c_{random.randint(1,50):04d}",
        random.choice(event_types),
        random.randint(0, 7200)
    ])
write_csv(SEEDS/"clickstream"/"raw_events.csv",
          ["event_id","event_time","user_id","content_id","event_type","playback_position_sec"], event_rows)

# =========================================================
# DOMINIO 3: FINANCE (estado de cuenta y FX)
# =========================================================
print("\n[3/3] Generando seeds de finance...")

# --- raw_transactions ---
tx_rows = []
currencies = ["USD","MXN","USD","USD","EUR","BRL","ARS"]
for tid in range(1, 1001):
    customer_id = random.randint(1, 100)
    tx_date = TODAY - timedelta(days=random.randint(0, 730))
    amount = round(random.uniform(5.0, 850.0), 2)
    currency = random.choice(currencies)
    # 0.5% de transacciones LATE-ARRIVING (timestamp viejo pero "ingestadas" hoy)
    ingestion_date = tx_date + timedelta(days=random.randint(0, 30))
    tx_type = random.choice(["debit","debit","debit","credit","refund"])
    tx_rows.append([tid, customer_id, tx_date.strftime("%Y-%m-%d"),
                    ingestion_date.strftime("%Y-%m-%d %H:%M:%S"),
                    amount, currency, tx_type])
write_csv(SEEDS/"finance"/"raw_transactions.csv",
          ["transaction_id","customer_id","transaction_date","ingested_at",
           "amount","currency","transaction_type"], tx_rows)

# --- raw_fx_rates (tasas de cambio diarias contra USD) ---
fx_rows = []
fx_id = 1
base_rates = {"MXN": 17.5, "EUR": 0.92, "BRL": 5.1, "ARS": 980.0, "USD": 1.0}
# 60 días de tasas diarias
for d in range(60):
    rate_date = TODAY - timedelta(days=d)
    for ccy, base in base_rates.items():
        # variación diaria pequeña
        rate = round(base * random.uniform(0.98, 1.02), 4)
        fx_rows.append([fx_id, rate_date.strftime("%Y-%m-%d"), ccy, "USD", rate])
        fx_id += 1
write_csv(SEEDS/"finance"/"raw_fx_rates.csv",
          ["fx_id","rate_date","from_currency","to_currency","rate"], fx_rows)

# --- raw_chargebacks (fraude/disputas) ---
cb_rows = []
for cid in range(1, 41):
    tx_id = random.randint(1, 1000)
    cb_date = TODAY - timedelta(days=random.randint(0, 90))
    reason = random.choice(["fraud","not_recognized","item_not_received","duplicate","other"])
    cb_rows.append([cid, tx_id, cb_date.strftime("%Y-%m-%d"), reason])
write_csv(SEEDS/"finance"/"raw_chargebacks.csv",
          ["chargeback_id","transaction_id","chargeback_date","reason"], cb_rows)

print("\n✅ Todos los seeds generados.")
