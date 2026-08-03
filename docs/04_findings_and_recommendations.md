# Findings & Recommendations

Every figure is reproducible with `.\run_pipeline.ps1` and traceable to a file in `outputs/`.

---

## Finding 1 — 21.19% of SKUs drive 79.99% of revenue; the tail holds 915 days of cover

**Evidence** — `outputs/abc_summary.csv`

| Class | SKUs | % of SKUs | Revenue | % of revenue | Inventory value | Avg DOI |
|---|---:|---:|---:|---:|---:|---:|
| A | 1,033 | 21.19% | £16,075,891 | 79.99% | £1,665,688 | 141.7 d |
| B | 1,276 | 26.17% | £3,016,022 | 15.01% | £794,707 | 243.6 d |
| **C** | **2,567** | **52.65%** | £1,005,235 | **5.00%** | £519,009 | **914.8 d** |

The Pareto is textbook. The actionable half is the tail: **more than half the catalogue produces 5% of
revenue and carries two and a half years of cover.**

**Recommendation.** Apply differentiated policy by class rather than one service level to everything:

| Class | Policy |
|---|---|
| A | 95% service level, weekly review, automated reorder at ROP |
| B | 90% service level, monthly review |
| C | Make-to-order or supplier-managed; no safety stock; delist bottom decile |

**Owner:** Category Planning. **Effort:** Low — it is a policy change, not a systems change.

---

## Finding 2 — AZ is the stock-out engine: 562 SKUs, 32% of revenue, CV 2.46

**Evidence** — `outputs/abc_xyz_matrix.csv`

| Cell | SKUs | Revenue | Avg CV | Planned inventory |
|---|---:|---:|---:|---:|
| AX | 49 | £1,937,918 | 0.64 | £94,105 |
| AY | 422 | £7,678,965 | 1.11 | £606,797 |
| **AZ** | **562** | **£6,459,008** | **2.46** | **£964,785** |

Safety stock is `Z × σ × √LT`, so it scales with **variability**, not volume. AZ SKUs carry 32% of
revenue but absorb the largest single block of planned inventory capital in the business.

**Recommendation.** Spend forecasting effort where variance is, not where volume is:

1. Promotion-calendar discipline on AZ items — much of retail demand variance is self-inflicted.
2. Order-cadence smoothing with the largest buyers (minimum order quantities, agreed order windows).
3. Only then increase safety stock. Raising buffers first treats the symptom at the highest cost per
   unit of service gained.

**Owner:** Demand Planning. **Effort:** Medium. **Impact:** High — this is the highest-leverage finding.

---

## Finding 3 — £1.10 M is trapped in dead and overstocked SKUs while 1,470 SKUs risk stocking out

**Evidence** — `outputs/stock_status_summary.csv`, `outputs/overstock_products.csv`

| Status | SKUs | % | Capital tied up |
|---|---:|---:|---:|
| Stock-out risk — volatile growth | 1,352 | 27.73% | £906,715 |
| Dead stock (no sale in 180 d) | 1,443 | 29.59% | £562,227 |
| Healthy | 1,013 | 20.78% | £627,969 |
| Overstock risk | 720 | 14.77% | £538,241 |
| Stock-out risk — erratic A-item | 118 | 2.42% | £187,799 |
| Stock-out risk — growing | 6 | 0.12% | £9,048 |
| Insufficient history | 224 | 4.59% | £147,405 |

Only **20.78% of the catalogue is healthy.** The two failure modes are running concurrently, which is why
a single "reduce inventory" or "increase inventory" instruction always fails — it makes one half worse.

**Recommendation.** Two separate workstreams, run simultaneously, never as one target:

- **Release** — clear the 1,443 dead SKUs (markdown, bundling, delist). £562,227 of planned capital, with
  no revenue consequence worth measuring.
- **Protect** — expedite and re-buffer the 1,470 stock-out-risk SKUs, prioritised by revenue.

**Owner:** Inventory Control + Merchandising. **Effort:** Medium.

---

## Finding 4 — Supplier OTIF hides lead-time volatility

**Evidence** — `outputs/supplier_scorecard.csv`, `outputs/supplier_lead_time.csv`

Overall OTIF is **88.51%** and 24 of 30 measurable vendors are Band A (≥95%). Ranking on adherence alone
would conclude the supply base is healthy. Scoring predictability alongside it (60/40) inverts the list:

| Vendor | POs | OTIF | Avg lead time | Lead-time CV | Score |
|---|---:|---:|---:|---:|---:|
| GLAXOSMITHKLINE EXPORT | 20 | 100.0% | 194.8 d | 0.34 | 86.6 |
| MICRO LABS | 35 | 100.0% | 147.9 d | 0.36 | 85.7 |
| HETERO LABS | 277 | 99.3% | 127.1 d | 0.37 | 85.0 |
| PHARMACY DIRECT | 326 | **100.0%** | 83.4 d | **1.59** | 60.0 |
| S. BUYS WHOLESALER | 715 | 98.5% | 31.1 d | **1.28** | 59.1 |
| JSI R&T INSTITUTE | 38 | 97.4% | 39.4 d | **1.10** | 58.4 |

**PHARMACY DIRECT never misses a date on a lead time whose standard deviation exceeds its mean.** That is
a loosely-set schedule, not reliability. A vendor at 195 days ±34% is easier to plan around than one at
83 days ±159%.

**Recommendation.** Contract on lead-time **variance**, not only on OTIF. Renegotiate quoted lead times
toward the observed P50 for high-CV vendors — converting hidden buffer into a measurable commitment — and
add lead-time CV to the quarterly vendor review alongside OTIF.

**Owner:** Procurement. **Effort:** Medium.

---

## Finding 5 — Returns run at 7.60% of revenue

**Evidence** — `outputs/returns_analysis.csv`

19,493 real credit notes, 490,993 units, **£1,527,041 — 7.60% of revenue.** Measured by value rather than
line count, so a returned pallet outweighs a returned greeting card.

**Recommendation.** Feed the return rate back into the planning model: for high-return categories, net
demand is materially below gross demand, and planning on gross systematically overstocks them. Add a
category-level return factor to the demand input.

**Owner:** Demand Planning. **Effort:** Low.

---

## Priority

| # | Finding | Effort | Impact | Sequence |
|---|---|---|---|---|
| 1 | Class-differentiated stocking policy | Low | High | **First** — policy change, immediate |
| 3 | Release dead stock / protect at-risk | Medium | High | Second — frees the capital that funds the rest |
| 5 | Return factor in demand input | Low | Medium | Second — trivial to implement |
| 2 | AZ variance reduction | Medium | High | Third — highest leverage, needs planning capacity |
| 4 | Contract on lead-time variance | Medium | Medium | Fourth — supplier negotiation cycle |

Finding 1 comes first not because it is the largest, but because it costs nothing and stops the business
spending service level on 2,567 SKUs that generate 5% of revenue.
