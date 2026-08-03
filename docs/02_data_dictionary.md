# Data Dictionary

## Source feeds

### Demand feed — Online Retail II (UCI)

Real transactions from a UK-based online giftware retailer, Dec 2009 – Dec 2011. Distributed as `.xlsx`
with one sheet per year. CC BY 4.0.

| Column | Type | Note |
|---|---|---|
| `Invoice` | text | Prefix `C` = **credit note (return)** |
| `StockCode` | text | SKU identifier; also carries admin codes (`POST`, `M`, `BANK CHARGES`) |
| `Description` | text | Free text; the only basis for category derivation |
| `Quantity` | int | **Negative on credit notes and adjustments** |
| `InvoiceDate` | numeric | **Excel serial number**, days since 1899-12-30 — not a date |
| `Price` | decimal | Unit price, GBP |
| `Customer ID` | int | Null on cash/guest sales (234,082 lines) |
| `Country` | text | 43 destination countries |

### Procurement feed — SCMS Delivery History (USAID)

10,324 real purchase orders for health commodities. Public domain.

| Column | Note |
|---|---|
| `Vendor` | 73 vendors incl. the pseudo-vendor `SCMS from RDC` (regional distribution centre) |
| `PO Sent to Vendor Date` | Format `M/d/yy`; sentinels `N/A - From RDC` (5,404), `Date Not Captured` (328) |
| `Scheduled Delivery Date` | Format `d-MMM-yy` |
| `Delivered to Client Date` | Format `d-MMM-yy` |
| `Product Group` / `Sub Classification` | Procurement category hierarchy |
| `Manufacturing Site` | Origin node |
| `Line Item Quantity` / `Line Item Value` / `Unit Price` | USD |
| `Freight Cost (USD)` | Often the text `Invoiced Separately` (4,126 rows) — not numeric |
| `Shipment Mode` | Air / Truck / Air Charter / Ocean |
| `Weight (Kilograms)` | Also carries non-numeric sentinels |

---

## Cleaning decisions

### 1 · Excel serial dates

`InvoiceDate` arrives as `40148.322916` because the source is an `.xlsx`. Left unconverted, every
time-series metric silently breaks.

```sql
invoice_ts = TIMESTAMP '1899-12-30 00:00:00'
             + INTERVAL (ROUND(InvoiceDate * 86400)) SECOND
```

### 2 · Per-column date masks

The procurement feed uses **a different format per column**, and neither is ISO. A plain `CAST` returns
NULL for all of them — which on the first run nulled supplier OTIF entirely while still producing a
scorecard that looked plausible.

```sql
po_sent_date   = STRPTIME("PO Sent to Vendor Date",   '%m/%d/%y')   -- 8/27/14
scheduled_date = STRPTIME("Scheduled Delivery Date",  '%d-%b-%y')   -- 2-Jun-06
delivered_date = STRPTIME("Delivered to Client Date", '%d-%b-%y')
```

### 3 · Line classification

Every raw line is labelled, then only `SALE` feeds the demand facts. Nothing is dropped silently — the
excluded volumes are reported in the quality gate.

| `line_type` | Rule | Rows |
|---|---|---:|
| `SALE` | Everything else | 1,036,043 |
| `RETURN` | `Invoice LIKE 'C%'` | 19,493 |
| `ADMIN` | Admin stock codes, or description matching postage / carriage / sample / manual / bank charge / damage / lost / found / adjustment | 6,442 |
| `ADJUSTMENT` | `quantity <= 0` and not a credit note | 2,856 |
| `ZERO_PRICE` | `unit_price <= 0` | 2,536 |

Counting a £0 "MANUAL ADJUSTMENT" of −9,600 units as demand corrupts a mean, a standard deviation, a
safety stock and a reorder point in one pass. This is the single highest-value cleaning step in the
project.

### 4 · Category derivation

The source has no category column. Categories are derived from `Description` by documented keyword rules
into 12 classes (Kitchen & Dining, Home Decor, Seasonal & Occasion, Storage & Organisation, Bags &
Luggage, Candles & Lighting, Stationery & Giftwrap, Toys & Games, Jewellery, Garden & Outdoor, Textiles
& Soft Furnishing, Other).

**1,835 SKUs remain `Other`** and are reported as rule CAT-01 in the quality gate. They are not
force-fitted into a category to make the coverage look better.

---

## Model tables

### `dim_product` — 4,876 rows

| Column | Definition |
|---|---|
| `stock_code` | PK. SKU identifier |
| `product_name` | Most frequent description for that SKU (621 SKUs have inconsistent descriptions — the modal one wins) |
| `category` | Derived class |

### `fct_sales` — 1,036,043 rows

| Column | Definition |
|---|---|
| `invoice_no`, `stock_code` | Keys |
| `units_sold`, `unit_price`, `revenue` | Line economics, GBP |
| `customer_id` | Nullable |
| `country`, `market` | Destination; market = macro-region rollup |
| `invoice_date`, `year_month`, `week_start` | Calendar attributes; `week_start` drives the demand grid |

### `fct_returns` — 19,493 rows

Same shape; `units_returned` and `return_value` are the absolute values of the negative source figures.

### `fct_purchase_order` — 10,324 rows

| Column | Definition |
|---|---|
| `vendor`, `manufacturing_site`, `destination_country` | Supply network |
| `qty_ordered`, `line_value_usd`, `unit_price_usd`, `freight_cost_usd`, `weight_kg` | Commercials, USD |
| `po_sent_date`, `scheduled_date`, `delivered_date` | Parsed dates |
| `lead_time_days` | `delivered − po_sent`. Null for RDC-sourced orders |
| `delivery_variance_days` | `delivered − scheduled`; positive = late |
| `is_on_time` | 1/0/NULL |

### `sku_planning` / `sku_stock_status` — 4,876 rows

Planning parameters per SKU: `abc_class`, `xyz_class`, `abc_xyz_cell`, `avg_weekly_demand`,
`sd_weekly_demand`, `demand_cv`, `safety_stock_units`, `reorder_point_units`, `eoq_units`,
`avg_inventory_units`, `avg_inventory_value`, `implied_turnover`, `days_of_inventory`,
`demand_momentum`, `stock_status`. Formulas in [`03_metric_definitions.md`](03_metric_definitions.md).

---

## Mappings

| Brief field | Mapped to | Justification |
|---|---|---|
| Product ID / Name | `stock_code` / `product_name` | Direct |
| Category | Derived from description | Documented rules; coverage reported |
| Quantity Sold | `units_sold` | Direct, real |
| Purchase Date | `invoice_date` | Direct, real |
| Selling Price | `unit_price` | Direct, real |
| Supplier | `vendor` (procurement feed) | Direct, real — 73 vendors with real lead times and delivery dates |
| Warehouse | `market` / `manufacturing_site` | Demand feed has destination markets; procurement feed has origin sites |
| **Quantity Available** | `avg_inventory_units` | **Planned level computed from real demand** — see gaps |
| **Stock Status** | `stock_status` | Derived from demand momentum, not from measured stock |

## Known gaps

- **Stock on hand does not exist in any public retail dataset** — it is proprietary ERP data. Every
  inventory *position* here is a planned level derived from real demand, prefixed `avg_inventory_*` or
  `implied_*` so it can never be mistaken for a measurement.
- **The two feeds are not joined.** Different businesses, different currencies, different periods. They
  are two marts in one system. The only connection is the documented use of the observed procurement
  lead time as a planning input.
- **Freight cost is partly non-numeric** (4,126 rows read `Invoiced Separately`). Freight metrics are
  computed over the numeric subset and the excluded count is reported.
