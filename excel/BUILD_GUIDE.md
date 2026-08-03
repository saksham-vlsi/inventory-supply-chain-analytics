# Excel Build Guide

Builds a refreshable inventory workbook from `outputs/`. Excel 2016+ or Microsoft 365.
Run `.\run_pipeline.ps1` first.

---

## 1 · Connect with Power Query

**Data → Get Data → From File → From Folder →** `outputs\`. Import each as a connection; tick
**Add this data to the Data Model**.

| Query | File | Load as |
|---|---|---|
| `Planning` | `inventory_planning_by_sku.csv` | Table + Data Model (4,876 rows) |
| `ABC` | `abc_summary.csv` | Table + Data Model |
| `ABCXYZ` | `abc_xyz_matrix.csv` | Table + Data Model |
| `StockStatus` | `stock_status_summary.csv` | Table + Data Model |
| `Fast` | `fast_moving_products.csv` | Table |
| `Slow` | `slow_moving_products.csv` | Table |
| `Stockout` | `stockout_risk_products.csv` | Table |
| `Overstock` | `overstock_products.csv` | Table |
| `Categories` | `category_performance.csv` | Table + Data Model |
| `Monthly` | `monthly_sales.csv` | Table + Data Model |
| `Returns` | `returns_analysis.csv` | Table + Data Model |
| `Suppliers` | `supplier_scorecard.csv` | Table + Data Model |
| `LeadTime` | `supplier_lead_time.csv` | Table |
| `PurchaseFreq` | `purchase_frequency.csv` | Table |
| `Markets` | `market_distribution.csv` | Table + Data Model |
| `Quality` | `data_quality_report.csv` | Table |

### Transform steps on `Planning`

1. **Set types explicitly.** `total_units`, `revenue_rank`, `days_since_last_sale` → Whole Number;
   all `*_units`, `*_value`, `demand_cv`, `implied_turnover`, `days_of_inventory`, `demand_momentum`
   → Decimal Number; the rest → Text.
2. **Add Column → Conditional Column** `Risk Flag`:
   `stock_status` contains `Stockout` → `At risk`; `= Dead stock` → `Dead`;
   `= Overstock risk` → `Excess`; else `OK`.
3. **Add Column → Custom Column** `Capital Band`:
   ```
   if [avg_inventory_value] >= 1000 then "High (1k+)"
   else if [avg_inventory_value] >= 250 then "Mid (250-1k)"
   else "Low (<250)"
   ```
4. **Home → Remove Rows → Remove Errors**, then **Close & Apply**.

> Keep transforms in Power Query, not in worksheet formulas — the workbook then refreshes end-to-end with
> **Data → Refresh All** after the pipeline reruns.

---

## 2 · Sheet 1 — Inventory KPI Dashboard

Card formulas, driven off the loaded tables so they refresh automatically:

```excel
Total SKUs              =COUNTA(Planning[stock_code])
Units Sold              =SUM(Planning[total_units])
Revenue                 =SUM(Planning[total_revenue])
Inventory Value         =SUM(Planning[avg_inventory_value])
Overall Turnover        =SUM(Planning[annual_demand_units])/SUM(Planning[avg_inventory_units])
Days of Inventory       =365/[Overall Turnover]
A-Class SKU Share       =COUNTIFS(Planning[abc_class],"A")/COUNTA(Planning[stock_code])
A-Class Revenue Share   =SUMIFS(Planning[total_revenue],Planning[abc_class],"A")/SUM(Planning[total_revenue])
Stockout Risk SKUs      =COUNTIF(Planning[stock_status],"Stockout*")
Dead Stock SKUs         =COUNTIFS(Planning[stock_status],"Dead stock")
Dead Stock Capital      =SUMIFS(Planning[avg_inventory_value],Planning[stock_status],"Dead stock")
Return Rate %           =SUM(Returns[return_value])/SUM(Returns[revenue])
Supplier OTIF %         =SUMPRODUCT(Suppliers[otif_pct],Suppliers[purchase_orders])/SUM(Suppliers[purchase_orders])
Median Vendor Lead Time =MEDIAN(LeadTime[median_days])
```

> Note `Overall Turnover` divides **totals**, not an average of per-SKU ratios — averaging ratios
> overweights tiny SKUs and produces a number that disagrees with the SQL. Same reasoning drives the
> `SUMPRODUCT` weighting on Supplier OTIF.

**Formatting:** merge a 3×2 block per card, value on top, label beneath, hairline border.
**Conditional Formatting → Icon Sets** on Supplier OTIF % (green ≥ 0.95, amber ≥ 0.85, red below) and on
Days of Inventory (reverse — high is bad).

---

## 3 · Sheet 2 — PivotTables

**Insert → PivotTable → Use this workbook's Data Model.**

| PivotTable | Rows | Columns | Values | Chart |
|---|---|---|---|---|
| ABC concentration | `abc_class` | — | Count SKUs, Sum revenue, **% of Grand Total** | Pareto (bar + cumulative line) |
| **ABC-XYZ matrix** | `abc_class` | `xyz_class` | Sum revenue, Sum inventory value | Heatmap via conditional formatting |
| Stock status | `stock_status` | — | Count SKUs, Sum `avg_inventory_value` | Donut |
| Category performance | `category` | — | Sum revenue, Avg turnover, Count dead SKUs | Bar |
| Monthly demand | `year_month` | — | Sum units, Sum revenue | Line |
| Returns by category | `category` | — | Sum `return_value`, Avg `return_rate_pct` | Bar |
| Supplier ranking | `vendor` | — | Avg `otif_pct`, Avg `lead_time_cv`, Sum `spend_usd` | Bar, Top 15 |
| Market distribution | `market` | — | Sum revenue, Count SKUs | Treemap |

The **ABC-XYZ matrix** is the one to build carefully — rows `abc_class`, columns `xyz_class`, values
`Sum of inventory_value`, then **Conditional Formatting → Colour Scales** across the 3×3 body. The AZ
cell lighting up is the finding.

**Value Field Settings → Number Format** on every measure (set it in the PivotTable, not by formatting
cells — cell formatting resets on refresh).

---

## 4 · Slicers

**PivotTable Analyze → Insert Slicer:** `abc_class`, `xyz_class`, `category`, `stock_status`, `market`.
Then **Report Connections** on each → tick every PivotTable so one click filters the workbook.
Park them down the left of Sheet 1.

---

## 5 · Conditional formatting

| Range | Rule |
|---|---|
| `Planning[days_of_inventory]` | 3-colour scale, green low → red high |
| `Planning[demand_cv]` | Data bars — makes XYZ visible without a chart |
| `Planning[stock_status]` | Custom: red fill on `Dead stock`, amber on `Overstock risk` |
| `Planning[avg_inventory_value]` | Top 10 items → bold red (the capital concentration) |
| `Suppliers[lead_time_cv]` | Icon set, ▼ above 1.0 (variance exceeds the mean) |
| `Suppliers[otif_pct]` | 3-colour scale, red 70 → green 100 |
| `Quality[status]` | Red fill where `FAIL` |

---

## 6 · Sheet 3 — Reorder action list

The operational output — what a planner works from on Monday morning.

Filtered table from `Planning` where `stock_status LIKE "Stockout*"`, columns:
`stock_code`, `product_name`, `category`, `abc_xyz_cell`, `avg_weekly_demand`, `demand_cv`,
`reorder_point_units`, `safety_stock_units`, `eoq_units`, `total_revenue`.

Sort by `total_revenue` descending. Add:

```excel
Suggested Order Qty  =ROUND([@eoq_units],0)
Priority             =IF([@abc_class]="A","P1",IF([@abc_class]="B","P2","P3"))
```

---

## 7 · Sheet 4 — Capital release list

From `Overstock`: `stock_code`, `product_name`, `category`, `days_since_last_sale`, `demand_momentum`,
`days_of_inventory`, `avg_inventory_value`, `stock_status`. Sort by `avg_inventory_value` descending —
the top of this list is where the money is.

Add a running total to show how far down the list you get to a target:

```excel
=SUM($H$2:H2)
```

---

## 8 · Sheet 5 — Data Quality

Paste-link `Quality`. Header cell:

```excel
=COUNTIFS(Quality[severity],"BLOCK",Quality[status],"FAIL") & " blocking rules failing"
```

---

## 9 · Refresh

Re-run `.\run_pipeline.ps1`, then **Data → Refresh All**. Save as `.xlsx` so the Data Model and queries
stay inspectable.
