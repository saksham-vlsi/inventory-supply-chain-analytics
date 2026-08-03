-- =============================================================================
--  MySQL 8.0  --  ANALYSIS QUERY PACK   (18 queries across 5 related tables)
-- =============================================================================
--  Every query is standalone and commented with the business question it
--  answers. Uses CTEs and window functions (MySQL 8.0+).
--
--     USE inventory_scm;
--
--  Sections
--     A. Inventory analysis        Q1  - Q6
--     B. Product analysis          Q7  - Q10
--     C. Supplier analysis         Q11 - Q14
--     D. Warehouse / market        Q15 - Q16
--     E. Returns & data quality    Q17 - Q18
-- =============================================================================


-- ============================== A. INVENTORY ================================

-- Q1. Overall inventory position -- the one-row executive summary.
SELECT
    COUNT(*)                                                        AS total_skus,
    SUM(total_units)                                                AS units_sold,
    ROUND(SUM(total_revenue), 2)                                    AS revenue,
    ROUND(SUM(avg_inventory_value), 2)                              AS inventory_value,
    ROUND(SUM(annual_demand_units) / SUM(avg_inventory_units), 2)   AS overall_turnover,
    ROUND(365 / (SUM(annual_demand_units) / SUM(avg_inventory_units)), 1) AS days_of_inventory,
    SUM(stock_status LIKE 'Stockout%')                              AS stockout_risk_skus,
    SUM(stock_status = 'Overstock risk')                            AS overstock_skus,
    SUM(stock_status = 'Dead stock')                                AS dead_stock_skus
FROM sku_planning;


-- Q2. Inventory turnover by category -- where is capital moving, and where is it stuck?
--     Turnover = annual demand units / average inventory units.
SELECT
    p.category,
    COUNT(*)                                                        AS skus,
    SUM(s.total_units)                                              AS units_sold,
    ROUND(SUM(s.total_revenue), 2)                                  AS revenue,
    ROUND(SUM(s.avg_inventory_value), 2)                            AS inventory_value,
    ROUND(SUM(s.annual_demand_units) / NULLIF(SUM(s.avg_inventory_units), 0), 2) AS turnover,
    ROUND(365 / NULLIF(SUM(s.annual_demand_units) / NULLIF(SUM(s.avg_inventory_units), 0), 0), 1) AS days_of_inventory
FROM sku_planning s
JOIN dim_product p ON p.stock_code = s.stock_code
GROUP BY p.category
ORDER BY inventory_value DESC;


-- Q3. ABC classification -- proving the Pareto concentration.
--     Recomputed from raw sales rather than read from sku_planning, so the
--     result is independently verifiable.
WITH sku_rev AS (
    SELECT stock_code, SUM(revenue) AS revenue, SUM(units_sold) AS units
    FROM fct_sales GROUP BY stock_code
),
ranked AS (
    SELECT stock_code, revenue, units,
           SUM(revenue) OVER (ORDER BY revenue DESC
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(revenue) OVER ()                                 AS cum_share
    FROM sku_rev
),
classed AS (
    SELECT *, CASE WHEN cum_share <= 0.80 THEN 'A'
                   WHEN cum_share <= 0.95 THEN 'B' ELSE 'C' END     AS abc_class
    FROM ranked
)
SELECT abc_class,
       COUNT(*)                                                     AS skus,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)           AS pct_of_skus,
       SUM(units)                                                   AS units,
       ROUND(SUM(revenue), 2)                                       AS revenue,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2)   AS pct_of_revenue
FROM classed GROUP BY abc_class ORDER BY abc_class;


-- Q4. ABC-XYZ matrix -- value against predictability.
--     The AZ cell (high value, erratic demand) is where stockouts are born.
SELECT abc_xyz_cell, abc_class, xyz_class,
       COUNT(*)                             AS skus,
       ROUND(SUM(total_revenue), 2)         AS revenue,
       ROUND(AVG(demand_cv), 3)             AS avg_demand_cv,
       ROUND(SUM(safety_stock_units), 0)    AS safety_stock_units,
       ROUND(SUM(avg_inventory_value), 2)   AS inventory_value
FROM sku_planning
GROUP BY abc_xyz_cell, abc_class, xyz_class
ORDER BY abc_class, xyz_class;


-- Q5. Stock-out risk register -- SKUs to expedite.
SELECT s.stock_code, p.product_name, p.category, s.abc_xyz_cell,
       s.total_units, ROUND(s.total_revenue, 2) AS revenue,
       ROUND(s.avg_weekly_demand, 2)            AS avg_weekly_demand,
       ROUND(s.demand_cv, 3)                    AS demand_cv,
       ROUND(s.demand_momentum, 2)              AS demand_momentum,
       ROUND(s.reorder_point_units, 0)          AS reorder_point,
       ROUND(s.safety_stock_units, 0)           AS safety_stock,
       s.stock_status
FROM sku_planning s
JOIN dim_product p ON p.stock_code = s.stock_code
WHERE s.stock_status LIKE 'Stockout%'
ORDER BY s.total_revenue DESC
LIMIT 100;


-- Q6. Overstock and dead stock -- capital to release, ranked by what it ties up.
SELECT s.stock_code, p.product_name, p.category, s.abc_class,
       s.total_units, ROUND(s.total_revenue, 2)      AS revenue,
       s.days_since_last_sale,
       ROUND(s.demand_momentum, 2)                   AS demand_momentum,
       ROUND(s.days_of_inventory, 0)                 AS days_of_inventory,
       ROUND(s.avg_inventory_value, 2)               AS capital_tied_up,
       s.stock_status
FROM sku_planning s
JOIN dim_product p ON p.stock_code = s.stock_code
WHERE s.stock_status IN ('Overstock risk', 'Dead stock')
ORDER BY s.avg_inventory_value DESC
LIMIT 100;


-- ============================== B. PRODUCT ==================================

-- Q7. Top 20 selling products by units, with revenue rank alongside.
--     The two rankings disagreeing is itself the finding: high-volume,
--     low-value SKUs consume picking capacity without funding it.
SELECT s.stock_code, p.product_name, p.category,
       SUM(s.units_sold)                                            AS units_sold,
       ROUND(SUM(s.revenue), 2)                                     AS revenue,
       RANK() OVER (ORDER BY SUM(s.units_sold) DESC)                AS units_rank,
       RANK() OVER (ORDER BY SUM(s.revenue) DESC)                   AS revenue_rank
FROM fct_sales s
JOIN dim_product p ON p.stock_code = s.stock_code
GROUP BY s.stock_code, p.product_name, p.category
ORDER BY units_sold DESC
LIMIT 20;


-- Q8. Least selling products -- candidates for delisting.
SELECT s.stock_code, p.product_name, p.category,
       SUM(s.units_sold)                                            AS units_sold,
       ROUND(SUM(s.revenue), 2)                                     AS revenue,
       MAX(s.invoice_date)                                          AS last_sale_date,
       DATEDIFF((SELECT MAX(invoice_date) FROM fct_sales), MAX(s.invoice_date)) AS days_since_last_sale
FROM fct_sales s
JOIN dim_product p ON p.stock_code = s.stock_code
GROUP BY s.stock_code, p.product_name, p.category
HAVING units_sold <= 20
ORDER BY units_sold ASC, days_since_last_sale DESC
LIMIT 100;


-- Q9. Monthly sales trend with month-on-month growth.
WITH m AS (
    SELECT year_month_key,
           COUNT(DISTINCT invoice_no)   AS invoices,
           SUM(units_sold)              AS units,
           ROUND(SUM(revenue), 2)       AS revenue,
           COUNT(DISTINCT stock_code)   AS active_skus
    FROM fct_sales GROUP BY year_month_key
)
SELECT year_month_key, invoices, units, revenue, active_skus,
       LAG(revenue) OVER (ORDER BY year_month_key)                  AS prev_revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY year_month_key))
             / NULLIF(LAG(revenue) OVER (ORDER BY year_month_key), 0), 2) AS mom_growth_pct
FROM m ORDER BY year_month_key;


-- Q10. Category performance with revenue share and stock-health counts.
SELECT p.category,
       COUNT(DISTINCT s.stock_code)                                 AS skus,
       SUM(s.total_units)                                           AS units,
       ROUND(SUM(s.total_revenue), 2)                               AS revenue,
       ROUND(100.0 * SUM(s.total_revenue) / SUM(SUM(s.total_revenue)) OVER (), 2) AS pct_of_revenue,
       ROUND(AVG(s.avg_selling_price), 2)                           AS avg_price,
       SUM(s.stock_status LIKE 'Stockout%')                         AS stockout_risk_skus,
       SUM(s.stock_status = 'Dead stock')                           AS dead_skus
FROM sku_planning s
JOIN dim_product p ON p.stock_code = s.stock_code
GROUP BY p.category
ORDER BY revenue DESC;


-- ============================== C. SUPPLIER =================================

-- Q11. Supplier ranking -- schedule adherence + lead-time predictability.
--      Vendors with no PO-issue date (RDC-sourced) are scored on adherence
--      only and flagged, so the ranking never compares two different bases.
WITH v AS (
    SELECT vendor,
           COUNT(*)                                                 AS purchase_orders,
           SUM(qty_ordered)                                         AS units_ordered,
           ROUND(SUM(line_value_usd), 2)                            AS spend_usd,
           ROUND(AVG(NULLIF(lead_time_days, NULL)), 1)              AS avg_lead_days,
           ROUND(STDDEV_SAMP(lead_time_days), 1)                    AS sd_lead_days,
           ROUND(100.0 * AVG(is_on_time), 2)                        AS otif_pct
    FROM fct_purchase_order
    WHERE lead_time_days IS NULL OR lead_time_days BETWEEN 0 AND 365
    GROUP BY vendor
    HAVING COUNT(*) >= 10
)
SELECT vendor, purchase_orders, units_ordered, spend_usd,
       avg_lead_days, sd_lead_days,
       ROUND(sd_lead_days / NULLIF(avg_lead_days, 0), 3)            AS lead_time_cv,
       otif_pct,
       CASE WHEN avg_lead_days IS NULL OR sd_lead_days IS NULL
            THEN 'OTIF only (no lead-time data)'
            ELSE 'OTIF + lead-time predictability' END              AS score_basis,
       ROUND(CASE WHEN avg_lead_days IS NULL OR sd_lead_days IS NULL
                  THEN COALESCE(otif_pct, 0)
                  ELSE 0.6 * COALESCE(otif_pct, 0)
                     + 0.4 * (100 * (1 - LEAST(sd_lead_days / NULLIF(avg_lead_days, 0), 1)))
             END, 2)                                                AS supplier_score,
       CASE WHEN otif_pct >= 95 THEN 'A - Preferred'
            WHEN otif_pct >= 85 THEN 'B - Approved'
            WHEN otif_pct >= 70 THEN 'C - Conditional'
            ELSE 'D - Remediation' END                              AS supplier_band
FROM v
ORDER BY supplier_score DESC;


-- Q12. Supplier lead-time distribution.
--      P95 is what a planner should buffer against -- never the mean.
SELECT vendor,
       COUNT(*)                                                     AS orders_measured,
       MIN(lead_time_days)                                          AS min_days,
       ROUND(AVG(lead_time_days), 1)                                AS avg_days,
       MAX(lead_time_days)                                          AS max_days,
       ROUND(STDDEV_SAMP(lead_time_days), 1)                        AS sd_days,
       MAX(lead_time_days) - ROUND(AVG(lead_time_days), 0)          AS tail_risk_days
FROM fct_purchase_order
WHERE lead_time_days BETWEEN 0 AND 365
GROUP BY vendor
HAVING COUNT(*) >= 10
ORDER BY avg_days DESC;


-- Q13. Purchase frequency and order cadence per supplier.
SELECT vendor,
       COUNT(*)                                                     AS purchase_orders,
       MIN(po_sent_date)                                            AS first_po,
       MAX(po_sent_date)                                            AS last_po,
       DATEDIFF(MAX(po_sent_date), MIN(po_sent_date))               AS active_days,
       ROUND(DATEDIFF(MAX(po_sent_date), MIN(po_sent_date))
             / NULLIF(COUNT(*) - 1, 0), 1)                          AS avg_days_between_orders,
       ROUND(SUM(line_value_usd), 2)                                AS spend_usd,
       ROUND(AVG(line_value_usd), 2)                                AS avg_order_value
FROM fct_purchase_order
WHERE po_sent_date IS NOT NULL
GROUP BY vendor
HAVING COUNT(*) >= 10
ORDER BY purchase_orders DESC;


-- Q14. Shipment mode -- the cost / speed trade-off.
SELECT COALESCE(shipment_mode, 'Not specified')                     AS shipment_mode,
       COUNT(*)                                                     AS purchase_orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)           AS pct_of_orders,
       ROUND(AVG(lead_time_days), 1)                                AS avg_lead_days,
       ROUND(100.0 * AVG(is_on_time), 2)                            AS otif_pct,
       ROUND(SUM(freight_cost_usd), 2)                              AS freight_usd,
       ROUND(100.0 * SUM(freight_cost_usd) / NULLIF(SUM(line_value_usd), 0), 2) AS freight_pct_of_spend,
       ROUND(SUM(freight_cost_usd) / NULLIF(SUM(weight_kg), 0), 2)  AS freight_per_kg
FROM fct_purchase_order
GROUP BY shipment_mode
ORDER BY purchase_orders DESC;


-- =========================== D. WAREHOUSE / MARKET ==========================

-- Q15. Inventory and demand distribution by market and country.
SELECT market, country,
       COUNT(DISTINCT invoice_no)                                   AS invoices,
       COUNT(DISTINCT stock_code)                                   AS skus_shipped,
       SUM(units_sold)                                              AS units,
       ROUND(SUM(revenue), 2)                                       AS revenue,
       ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 3)   AS pct_of_revenue
FROM fct_sales
GROUP BY market, country
ORDER BY revenue DESC;


-- Q16. Warehouse utilisation proxy -- how much of the assortment each market
--      actually pulls. A market pulling 5% of the catalogue does not need a
--      full-range forward stock holding.
WITH total AS (SELECT COUNT(DISTINCT stock_code) AS all_skus FROM fct_sales)
SELECT f.market,
       COUNT(DISTINCT f.stock_code)                                 AS skus_pulled,
       t.all_skus,
       ROUND(100.0 * COUNT(DISTINCT f.stock_code) / t.all_skus, 2)  AS assortment_coverage_pct,
       SUM(f.units_sold)                                            AS units,
       ROUND(SUM(f.revenue), 2)                                     AS revenue,
       ROUND(SUM(f.revenue) / COUNT(DISTINCT f.stock_code), 2)      AS revenue_per_sku
FROM fct_sales f CROSS JOIN total t
GROUP BY f.market, t.all_skus
ORDER BY revenue DESC;


-- ========================= E. RETURNS & DATA QUALITY ========================

-- Q17. Return rate by category -- from real credit notes, not a proxy.
WITH s AS (SELECT p.category, SUM(f.revenue) AS revenue, SUM(f.units_sold) AS units
           FROM fct_sales f JOIN dim_product p ON p.stock_code = f.stock_code
           GROUP BY p.category),
     r AS (SELECT p.category, SUM(t.return_value) AS return_value,
                  SUM(t.units_returned) AS units_returned, COUNT(*) AS return_lines
           FROM fct_returns t JOIN dim_product p ON p.stock_code = t.stock_code
           GROUP BY p.category)
SELECT s.category,
       ROUND(s.revenue, 2)                                          AS revenue,
       s.units                                                      AS units_sold,
       COALESCE(r.return_lines, 0)                                  AS return_lines,
       COALESCE(r.units_returned, 0)                                AS units_returned,
       ROUND(COALESCE(r.return_value, 0), 2)                        AS return_value,
       ROUND(100.0 * COALESCE(r.return_value, 0) / NULLIF(s.revenue, 0), 2) AS return_rate_pct
FROM s LEFT JOIN r ON r.category = s.category
ORDER BY return_rate_pct DESC;


-- Q18. Referential and value integrity -- run before trusting anything above.
SELECT 'Sales lines with no matching product' AS check_name, COUNT(*) AS failing_rows
FROM fct_sales f LEFT JOIN dim_product p ON p.stock_code = f.stock_code
WHERE p.stock_code IS NULL
UNION ALL
SELECT 'Sales with non-positive quantity', COUNT(*) FROM fct_sales WHERE units_sold <= 0
UNION ALL
SELECT 'Sales with non-positive price',    COUNT(*) FROM fct_sales WHERE unit_price <= 0
UNION ALL
SELECT 'Planning rows with no sales history', COUNT(*)
FROM sku_planning s LEFT JOIN fct_sales f ON f.stock_code = s.stock_code
WHERE f.stock_code IS NULL
UNION ALL
SELECT 'POs delivered before being raised', COUNT(*)
FROM fct_purchase_order WHERE delivered_date < po_sent_date
UNION ALL
SELECT 'POs with unparseable scheduled date', COUNT(*)
FROM fct_purchase_order WHERE scheduled_date IS NULL;
