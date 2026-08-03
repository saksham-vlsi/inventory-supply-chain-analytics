# Metric Definitions

Every metric published by this project, with its formula, its inputs, and the reasoning behind each
modelling choice.

---

## Planning assumptions

Five inputs that inventory theory requires but a transaction log does not contain. All are declared in
`planning_assumptions` (`sql/03_inventory_planning.sql`) and can be changed in one place.

| Input | Symbol | Value | Basis |
|---|---|---|---|
| Service level | Z | 1.65 (95%) | Standard retail cycle-service target |
| Lead time | LT | **91 days** | **Median observed vendor lead time from the procurement feed** |
| Ordering cost | S | £50 per PO | Planning constant |
| Holding rate | H% | 25% / year | Capital + storage + obsolescence |
| Unit cost | c | 0.55 × selling price | 45% gross margin |

**On the lead time.** Most portfolio projects hard-code "lead time = 7 days". Here it is *measured*:
the median of `delivered_date − po_sent_date` across the 4,592 purchase orders that carry both dates.
This is the single deliberate link between the two feeds — the demand-side safety-stock model is
parameterised with a real, observed procurement lead time instead of an invented constant.

---

## Demand statistics

### Weekly demand grid

```sql
grid = all SKUs × all weeks in the window   (CROSS JOIN)
units(sku, week) = COALESCE(actual units, 0)
```

**Weeks with zero demand are included deliberately.** If the standard deviation is computed only over
weeks where a SKU actually sold, an intermittent SKU looks *stable* and its safety stock comes out far too
low — the single most common error in demand analysis. A SKU selling 100 units in one week out of 26 has
a genuinely high variance and must be treated as such.

| Metric | Formula |
|---|---|
| Average weekly demand | `μ = AVG(units per week)` |
| Demand std deviation | `σ = STDDEV_SAMP(units per week)` |
| Coefficient of variation | `CV = σ / μ` |
| Demand frequency | `weeks with demand / weeks observed` |
| Annual demand | `total units × 365 / window_days` |

---

## ABC-XYZ segmentation

### ABC — value

Cumulative revenue share, descending:

| Class | Cumulative revenue |
|---|---|
| A | ≤ 80% |
| B | ≤ 95% |
| C | remainder |

### XYZ — predictability

| Class | Demand CV | Meaning |
|---|---|---|
| X | ≤ 0.75 | Stable, forecastable |
| Y | 0.75 – 1.50 | Variable |
| Z | > 1.50 | Erratic |

**Why both axes.** ABC alone tells you what is worth money; XYZ tells you what is *plannable*. The
dangerous cell is **AZ** — high revenue, erratic demand — which single-axis ABC analysis buries inside
"class A, manage closely". Safety stock scales with σ, so AZ SKUs consume inventory capital out of all
proportion to their volume.

---

## Inventory planning parameters

### Safety stock

```
SS = Z × σ_weekly × √(LT_weeks)
```

Buffers against **demand** variability over the lead time. The √LT term is standard: variance accumulates
linearly over time, so the standard deviation grows with the square root.

> This formulation assumes lead time itself is constant. `outputs/supplier_lead_time.csv` shows it is not
> — several vendors have a lead-time CV above 1.0. Where lead-time variance matters, the fuller form
> `SS = Z × √(LT × σ_d² + d² × σ_LT²)` applies; the supplier scorecard exists to identify exactly which
> vendors make that necessary.

### Reorder point

```
ROP = μ_weekly × LT_weeks + SS
```

Expected demand over the lead time, plus the buffer. Order when on-hand crosses this.

### Economic order quantity

```
EOQ = √( 2 × D × S / H )        D = annual demand units
                                S = ordering cost (£50)
                                H = holding cost per unit per year = 25% × unit cost
```

The order size that minimises the sum of ordering and holding cost.

### Cover and turnover

```
avg_inventory_units = SS + EOQ / 2          -- saw-tooth cycle stock + buffer
avg_inventory_value = avg_inventory_units × unit_cost
implied_turnover    = annual_demand_units / avg_inventory_units
days_of_inventory   = 365 / implied_turnover
```

**`implied_` is not decoration.** These are inventory levels the model says you *should* hold given real
demand — not measured stock, which the source does not contain. Every column derived from them carries
the prefix so a reader can never mistake a planned level for an observed one.

---

## Demand momentum and stock status

```
demand_momentum = (units_last_90d / 90) ÷ (units_prior / (window_days − 90))
```

A ratio of recent daily run-rate to prior daily run-rate. `1.0` = flat, `< 1` = decaying, `> 1` = growing.

| Status | Rule |
|---|---|
| Dead stock | No sale in the last 180 days |
| Overstock risk | `momentum < 0.5` and lifetime units ≥ 50 |
| Stock-out risk — volatile growth | `momentum > 1.5` and `CV > 0.75` |
| Stock-out risk — growing | `momentum > 1.5` |
| Stock-out risk — erratic A-item | Class `AZ` |
| Insufficient history | `momentum` undefined (no prior-period demand) |
| Healthy | Everything else |

**Why momentum rather than a stock threshold.** Without measured stock, "overstock" cannot mean "on-hand
> X". It can mean something more useful: *demand for this SKU has collapsed relative to its own history,
so whatever is held for it is now excess.* That is derivable entirely from real demand, and it is closer
to the decision a planner makes than a static threshold anyway.

The 50-unit floor on overstock stops a SKU that sold 2 units then 0 from being flagged as an inventory
problem — it is a long-tail SKU, and the dead-stock rule already covers it.

---

## Returns

Real credit notes, not a proxy. In this source an invoice number prefixed `C` is a credit note and
carries a negative quantity.

| Metric | Formula |
|---|---|
| Units returned | `ABS(quantity)` where `invoice LIKE 'C%'` |
| Return value | `ABS(quantity × price)` |
| Return rate | `SUM(return_value) / SUM(sales revenue)` |

Return rate is computed **by value**, not by line count — one returned pallet matters more than fifty
returned greeting cards.

---

## Supplier metrics

| Metric | Formula |
|---|---|
| Lead time | `delivered_date − po_sent_date`, days |
| Delivery variance | `delivered_date − scheduled_date`; positive = late |
| OTIF | `% of POs where delivered_date ≤ scheduled_date` |
| Lead-time CV | `σ(lead_time) / μ(lead_time)` |
| Tail risk | `P95(lead_time) − median(lead_time)` |

Lead-time averages exclude negative and >365-day values (impossible date pairs in the source). They are
excluded from **averages**, never from counts.

### Supplier score

```
score = 0.6 × OTIF + 0.4 × (100 × (1 − min(CV_lead_time, 1)))
```

| Band | OTIF |
|---|---|
| A · Preferred | ≥ 95% |
| B · Approved | 85 – 95% |
| C · Conditional | 70 – 85% |
| D · Remediation | < 70% |

**Why predictability carries 40%.** A vendor that always delivers in 195 ± 34% is easier to plan around
than one delivering in 83 ± 159%, because safety stock is driven by variance, not by average speed. OTIF
alone rewards a supplier whose quoted lead time is so padded it cannot be missed — the data contains
exactly that case (PHARMACY DIRECT: 100% OTIF, lead-time CV 1.59).

**Handling missing lead times.** 5,404 of 10,324 orders are sourced from a regional distribution centre
rather than a vendor PO, so no lead time exists. Scoring them on a zero predictability term would rank
the largest single channel last on missing data alone. They are scored on adherence only and the
`score_basis` column records which basis was used — the ranking never silently compares two different
things.

---

## Conventions

- Percentages are stored out of 100 (`88.51`), not as fractions.
- Currency: demand feed in GBP (£), procurement feed in USD ($). **Never summed together** — they are
  different businesses and no FX conversion is applied.
- `NULLIF(...,0)` guards every denominator.
- Supplier rankings require ≥10 purchase orders; SKU rankings use the full universe.
