# Inventory & Supply Chain Analytics

**SQL-driven inventory planning and supplier performance analysis on 1,036,043 real sales lines and 10,324 real purchase orders.**

Retailers hold too much of the wrong stock and too little of the right stock at the same time. This
project takes two real operational feeds and produces the numbers an inventory planner actually sets:
**safety stock, reorder point, EOQ, days of inventory, ABC-XYZ class and supplier rank** — with a data
quality gate in front of every one of them.

| | |
|---|---|
| **Demand feed** | [Online Retail II (UCI)](https://archive.ics.uci.edu/dataset/502/online+retail+ii) — 1,067,371 real transactions, Dec 2009 – Dec 2011 |
| **Procurement feed** | [SCMS Delivery History (USAID)](https://data.usaid.gov/) — 10,324 real purchase orders with vendor, scheduled vs actual delivery |
| **Scale** | 4,876 SKUs · 11.4 M units · £20.10 M revenue · 43 countries · 73 vendors |
| **Stack** | MySQL 8 (5 related tables, 18 queries) · SQL · Excel · Power BI |
| **Run it** | `.\run_pipeline.ps1` — builds the model and publishes 22 marts |

---

## Headline results

| KPI | Value |
|---|---:|
| SKUs analysed | **4,876** |
| Sales lines | **1,036,043** |
| Units sold | **11,400,260** |
| Revenue | **£20,097,148** |
| Real returns (credit notes) | **19,493 lines · 490,993 units · £1,527,041** |
| **Return rate** | **7.60%** of revenue |
| Median days of inventory | **320.6 days** |
| Inventory value at planned levels | **£2,979,404** |
| Stock-out risk SKUs | **1,476** |
| Overstock SKUs | **720** |
| Dead stock SKUs | **1,443** |
| Purchase orders / vendors | **10,324 / 73** |
| **Supplier OTIF** | **88.51%** |
| Median vendor lead time | **91 days** |

---

## The four findings that matter

### 1 · The Pareto is almost exactly 80/20 — and the tail is where the money is trapped

| ABC class | SKUs | % of SKUs | Revenue | % of revenue | Avg days of inventory |
|---|---:|---:|---:|---:|---:|
| **A** | 1,033 | **21.19%** | £16,075,891 | **79.99%** | 141.7 |
| B | 1,276 | 26.17% | £3,016,022 | 15.01% | 243.6 |
| **C** | 2,567 | **52.65%** | £1,005,235 | **5.00%** | **914.8** |

**21.19% of SKUs generate 79.99% of revenue.** The operationally important half of that finding is the
C tail: **52.65% of the catalogue produces 5% of revenue and sits on 915 days of cover** — two and a half
years of stock for products nobody is buying. £519,009 of planned inventory value is committed to it.

**Recommendation:** move C-class to make-to-order or supplier-managed stock, and stop applying a service
level to SKUs that do not earn one. Delisting the bottom decile alone releases capital with no revenue
consequence worth measuring.

### 2 · The AZ cell is the real stock-out engine

Segmenting by value (ABC) **and predictability** (XYZ, from the coefficient of variation of weekly demand)
finds the cell that a single-axis ABC analysis hides:

| Cell | SKUs | Revenue | Avg demand CV | Planned inventory |
|---|---:|---:|---:|---:|
| AX — high value, stable | 49 | £1,937,918 | 0.64 | £94,105 |
| AY — high value, variable | 422 | £7,678,965 | 1.11 | £606,797 |
| **AZ — high value, erratic** | **562** | **£6,459,008** | **2.46** | **£964,785** |
| BZ | 1,065 | £2,478,496 | 2.89 | £711,440 |
| CZ | 2,518 | £966,496 | 4.67 | £509,587 |

**562 AZ SKUs carry £6.46 M — 32% of total revenue — at a demand CV of 2.46.** Because safety stock scales
with demand variability, these SKUs alone absorb £964,785 of planned inventory, more than the entire
A-class stable segment ten times over.

**Recommendation:** AZ is where forecasting effort pays. Anything that reduces demand variability here —
promotion calendar discipline, order-cadence smoothing with large buyers, min-order quantities — cuts
safety stock quadratically. Blanket safety-stock increases treat the symptom.

### 3 · Nearly a third of the catalogue is dead

| Stock status | SKUs | % of SKUs | Capital tied up |
|---|---:|---:|---:|
| Stock-out risk — volatile growth | 1,352 | 27.73% | £906,715 |
| **Dead stock** (no sale in 180 days) | **1,443** | **29.59%** | **£562,227** |
| Healthy | 1,013 | 20.78% | £627,969 |
| Overstock risk | 720 | 14.77% | £538,241 |
| Stock-out risk — erratic A-item | 118 | 2.42% | £187,799 |

Status is assigned from **demand momentum** — last-90-day run rate against the prior-period run rate —
so "overstock" means demand has actually collapsed, not that stock looks high in isolation.

**£1.10 M (37% of planned inventory value) sits in dead or overstocked SKUs**, while 1,470 SKUs are
simultaneously at stock-out risk. That is the classic retail failure: too much of the wrong stock and too
little of the right stock, at the same time.

### 4 · OTIF hides lead-time volatility — the suppliers that look best plan worst

Supplier OTIF is 88.51% overall, and 24 of 30 measurable vendors sit in Band A (≥95%). Ranking on
adherence alone is misleading. Adding lead-time **predictability** (60% adherence / 40% consistency)
reorders the list:

| Vendor | POs | OTIF | Avg lead time | Lead-time CV | Score |
|---|---:|---:|---:|---:|---:|
| GLAXOSMITHKLINE EXPORT | 20 | 100.0% | 194.8 d | **0.34** | **86.6** |
| MICRO LABS LIMITED | 35 | 100.0% | 147.9 d | 0.36 | 85.7 |
| HETERO LABS LIMITED | 277 | 99.3% | 127.1 d | 0.37 | 85.0 |
| … | | | | | |
| PHARMACY DIRECT | 326 | **100.0%** | 83.4 d | **1.59** | **60.0** |
| S. BUYS WHOLESALER | 715 | 98.5% | 31.1 d | **1.28** | 59.1 |
| JSI R&T INSTITUTE | 38 | 97.4% | 39.4 d | **1.10** | 58.4 |

**PHARMACY DIRECT hits its date 100% of the time on a lead time whose standard deviation exceeds its
mean.** That is not reliability — it is a schedule set so loosely that it cannot be missed. A supplier
averaging 195 days ±34% is far easier to plan around than one averaging 83 days ±159%, because safety
stock is driven by *variance*, not by average speed.

**Recommendation:** contract on lead-time variance, not just on OTIF. Renegotiate quoted lead times down
toward the P50 for the high-CV vendors, which converts hidden buffer into a measurable commitment.

---

## Architecture

```
data/raw/                     Online Retail II (2 CSV)  +  SCMS delivery history (1 CSV)
        │
        ▼
sql/01_build_model.sql        Cleaning + typing + classification
        │                     - Excel serial dates -> real timestamps
        │                     - line_type: SALE / RETURN / ADMIN / ADJUSTMENT / ZERO_PRICE
        │                     - rules-based category derivation
        │                     - per-column date masks for the procurement feed
        │                     -> dim_product, fct_sales, fct_returns, fct_purchase_order
        ▼
sql/02_data_quality.sql       20 rules -> outputs/data_quality_report.csv
        ▼
sql/03_inventory_planning.sql Weekly demand grid -> demand stats -> ABC-XYZ
        │                     -> safety stock, ROP, EOQ, DOI, turnover, stock status
        ▼
sql/04_supplier_analysis.sql  Vendor scorecard, lead-time distribution, purchase frequency
        ▼
sql/05_export_for_mysql.sql   Load files for the MySQL implementation
        │
        ├──▶ sql/mysql/       5-table schema + 18 analysis queries (MySQL 8)
        ├──▶ excel/           PivotTables, KPI cards, conditional formatting
        └──▶ powerbi/         DAX measure library
```

---

## The five related tables

| Table | Grain | Rows | Key columns |
|---|---|---:|---|
| `dim_product` | SKU | 4,876 | `stock_code` (PK), `product_name`, `category` |
| `fct_sales` | sales line | 1,036,043 | FK → `dim_product`, units, price, revenue, market, dates |
| `fct_returns` | credit-note line | 19,493 | FK → `dim_product`, units returned, return value |
| `fct_purchase_order` | purchase order | 10,324 | vendor, scheduled vs delivered, lead time, OTIF flag |
| `sku_planning` | SKU | 4,876 | FK → `dim_product`, ABC-XYZ, safety stock, ROP, EOQ, status |

Full DDL with primary keys, foreign keys, check constraints and indexes:
[`sql/mysql/01_schema_and_load.sql`](sql/mysql/01_schema_and_load.sql).
18 commented analysis queries: [`sql/mysql/02_analysis_queries.sql`](sql/mysql/02_analysis_queries.sql).

---

## Data quality — what the gate caught

Inventory analytics is unusually sensitive to dirty data: one uncleaned `MANUAL ADJUSTMENT` line with a
quantity of −9,600 corrupts a demand average, a safety stock and a reorder point in one pass.

| Rule | Severity | Rows | Handling |
|---|---|---:|---|
| Admin postings (postage, bank charges, samples, adjustments) | WARN | 6,442 | Labelled `ADMIN`, excluded from demand — **not** silently dropped |
| Non-credit negative-quantity adjustments | WARN | 2,856 | Excluded from demand |
| Zero-price lines | WARN | 2,536 | Excluded from demand |
| Sales with no customer ID (cash/guest) | WARN | 234,082 | Retained — valid demand, just unattributed |
| SKUs unmatched by category rules | WARN | 1,835 | Left as `Other` rather than force-fitted |
| **Scheduled delivery date unparseable** | WARN | **10,324 → 0** | **See below** |
| PO issue date unparseable | WARN | 8,612 | 5,404 are RDC-sourced (no vendor PO exists) + 328 `Date Not Captured` |

### The bug the gate caught

The first pipeline run reported **all 10,324** scheduled delivery dates as unparseable, which would have
silently nulled supplier OTIF entirely and produced a blank supplier scorecard that still *looked*
plausible. The cause: this source uses **a different date format per column** and neither is ISO —
`d-MMM-yy` for delivery dates, `M/d/yy` for the PO date — plus sentinel strings (`N/A - From RDC`,
`Date Not Captured`) where a real system would use NULL.

Fixing it with per-column `STRPTIME` masks recovered the real figure: **88.51% supplier OTIF across
10,324 orders.** Without the quality gate this would have shipped as a silent zero.

---

## Documented assumptions

Inventory theory needs inputs the transaction log does not contain. All five live in one place
(`planning_assumptions` in `sql/03_inventory_planning.sql`) and are overridable:

| Input | Value | Basis |
|---|---|---|
| Service level | 95% (Z = 1.65) | Standard retail target |
| **Lead time** | **91 days** | **Observed median vendor lead time from the procurement feed — measured, not invented** |
| Ordering cost | £50 / PO | Documented planning constant |
| Holding rate | 25% / year | Capital + storage + obsolescence |
| Unit cost | 55% of selling price | 45% gross margin |

The lead-time input is the one deliberate link between the two feeds: rather than assume a constant, the
demand-side safety stock model is parameterised with a lead time actually measured on real purchase
orders. Everything else is derived from real demand.

Formulas: `SS = Z × σ_weekly × √LT_weeks` · `ROP = μ_weekly × LT_weeks + SS` · `EOQ = √(2DS/H)` ·
`DOI = 365 / turnover`. Full derivations in [`docs/03_metric_definitions.md`](docs/03_metric_definitions.md).

---

## Known gaps (stated, not hidden)

- **No stock-on-hand column exists in any public retail dataset** — it is proprietary ERP data. Inventory
  *positions* here are therefore **planned levels computed from real demand**, labelled `avg_inventory_*`
  and `implied_turnover` throughout, never presented as measured stock. Every downstream metric that
  depends on them says so.
- **The two feeds are not joined.** They describe different businesses and are two marts in one system,
  which is how a real inventory platform is built. No cross-feed key is fabricated.
- **Category is derived** from product descriptions by documented keyword rules; 1,835 SKUs remain `Other`
  and the coverage is reported in the quality gate rather than hidden.

---

## Reproduce

```powershell
git clone https://github.com/saksham-vlsi/inventory-supply-chain-analytics.git
cd inventory-supply-chain-analytics
.\run_pipeline.ps1
```

Downloads both datasets, fetches a portable SQL engine, builds the model, runs the quality gate and
publishes 22 marts to `outputs/`. No database server required. To use the MySQL implementation instead,
run the pipeline then `sql/mysql/01_schema_and_load.sql`.

---

## Repository map

```
sql/            01 model · 02 quality · 03 inventory planning · 04 supplier · 05 MySQL export
sql/mysql/      5-table schema + 18 analysis queries (MySQL 8)
outputs/        22 published marts (committed — inspect without running anything)
excel/          BUILD_GUIDE.md — PivotTables, KPI cards, conditional formatting
powerbi/        measures.dax
docs/           business problem · data dictionary · metric definitions · findings
data/           download_data.ps1 (raw data gitignored)
```

---

*Data: Online Retail II (UCI, CC BY 4.0) and SCMS Delivery History (USAID, public domain). Analysis and code: MIT.*
