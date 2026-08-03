-- =============================================================================
--  03_inventory_planning.sql   |   DEMAND -> PLANNING PARAMETERS -> MARTS
-- =============================================================================
--  Turns 1,036,043 real sales lines into the parameters an inventory planner
--  actually sets: safety stock, reorder point, EOQ, days of inventory and
--  implied turnover -- plus the ABC-XYZ segmentation that decides which SKUs
--  deserve which policy.
--
--  DOCUMENTED ASSUMPTIONS (all in one place, all overridable):
--    service_level   95%  -> Z = 1.65
--    lead_time_days  taken from the OBSERVED median vendor lead time in the
--                    procurement feed, not invented. See docs/03_metric_definitions.md
--    ordering_cost   GBP 50 per purchase order
--    holding_rate    25% of unit cost per year (capital + storage + obsolescence)
--    unit_cost       55% of average selling price (45% gross margin)
--
--  Everything below is derived from those five numbers plus real demand.
-- =============================================================================

CREATE OR REPLACE TABLE planning_assumptions AS
SELECT
    1.65                                                          AS z_service_95,
    (SELECT MEDIAN(lead_time_days) FROM fct_purchase_order
      WHERE lead_time_days BETWEEN 0 AND 365)                     AS lead_time_days,
    50.0                                                          AS ordering_cost_gbp,
    0.25                                                          AS holding_rate,
    0.55                                                          AS cost_ratio,
    (SELECT date_diff('day', MIN(invoice_date), MAX(invoice_date)) FROM fct_sales) AS window_days;

-- -----------------------------------------------------------------------------
-- 1. Weekly demand series per SKU -- the statistical base for safety stock.
--    Weeks with no demand are real zeros and MUST be included, otherwise the
--    standard deviation is computed only over selling weeks and safety stock
--    comes out far too low for intermittent SKUs.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sku_week_demand AS
WITH weeks AS (SELECT DISTINCT week_start FROM fct_sales),
     skus  AS (SELECT DISTINCT stock_code FROM fct_sales),
     grid  AS (SELECT s.stock_code, w.week_start FROM skus s CROSS JOIN weeks w),
     actual AS (SELECT stock_code, week_start, SUM(units_sold) units, SUM(revenue) revenue
                FROM fct_sales GROUP BY 1,2)
SELECT g.stock_code, g.week_start,
       COALESCE(a.units,0)   AS units,
       COALESCE(a.revenue,0) AS revenue
FROM grid g LEFT JOIN actual a USING (stock_code, week_start);

-- -----------------------------------------------------------------------------
-- 2. Demand statistics + ABC + XYZ
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sku_demand_stats AS
WITH stats AS (
    SELECT stock_code,
           SUM(units)                                   AS total_units,
           SUM(revenue)                                 AS total_revenue,
           AVG(units)                                   AS avg_weekly_units,
           COALESCE(STDDEV_SAMP(units),0)               AS sd_weekly_units,
           COUNT(*)                                     AS weeks_observed,
           SUM(CASE WHEN units > 0 THEN 1 ELSE 0 END)   AS weeks_with_demand
    FROM sku_week_demand GROUP BY stock_code
),
recency AS (
    SELECT stock_code,
           SUM(CASE WHEN invoice_date >= (SELECT MAX(invoice_date) FROM fct_sales) - INTERVAL 90 DAY
                    THEN units_sold ELSE 0 END)                     AS units_last_90d,
           SUM(CASE WHEN invoice_date <  (SELECT MAX(invoice_date) FROM fct_sales) - INTERVAL 90 DAY
                    THEN units_sold ELSE 0 END)                     AS units_prior,
           MAX(invoice_date)                                        AS last_sale_date,
           date_diff('day', MAX(invoice_date), (SELECT MAX(invoice_date) FROM fct_sales)) AS days_since_last_sale
    FROM fct_sales GROUP BY stock_code
),
priced AS (
    SELECT stock_code, AVG(unit_price) AS avg_selling_price FROM fct_sales GROUP BY stock_code
),
joined AS (
    SELECT s.*, r.units_last_90d, r.units_prior, r.last_sale_date, r.days_since_last_sale,
           p.avg_selling_price,
           CASE WHEN s.avg_weekly_units > 0 THEN s.sd_weekly_units / s.avg_weekly_units END AS demand_cv
    FROM stats s JOIN recency r USING(stock_code) JOIN priced p USING(stock_code)
),
abc AS (
    SELECT *,
           SUM(total_revenue) OVER (ORDER BY total_revenue DESC ROWS UNBOUNDED PRECEDING)
             / SUM(total_revenue) OVER ()                              AS cum_rev_share,
           ROW_NUMBER() OVER (ORDER BY total_revenue DESC)             AS revenue_rank,
           COUNT(*) OVER ()                                            AS sku_universe
    FROM joined
)
SELECT *,
    CASE WHEN cum_rev_share <= 0.80 THEN 'A'
         WHEN cum_rev_share <= 0.95 THEN 'B' ELSE 'C' END               AS abc_class,
    -- XYZ segments predictability, which is what decides how much safety stock
    -- a SKU needs. A high-revenue but erratic SKU (AZ) is the dangerous cell.
    CASE WHEN demand_cv IS NULL     THEN 'Z'
         WHEN demand_cv <= 0.75     THEN 'X'
         WHEN demand_cv <= 1.50     THEN 'Y' ELSE 'Z' END               AS xyz_class
FROM abc;

-- -----------------------------------------------------------------------------
-- 3. Planning parameters -- safety stock, ROP, EOQ, DOI, implied turnover
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sku_planning AS
SELECT
    d.stock_code, p.product_name, p.category,
    d.abc_class, d.xyz_class, d.abc_class || d.xyz_class          AS abc_xyz_cell,
    d.total_units, ROUND(d.total_revenue,2)                        AS total_revenue,
    d.revenue_rank, ROUND(100.0*d.cum_rev_share,3)                 AS cum_revenue_pct,
    ROUND(d.avg_selling_price,2)                                   AS avg_selling_price,
    ROUND(d.avg_selling_price * a.cost_ratio,2)                    AS unit_cost,
    ROUND(d.avg_weekly_units,2)                                    AS avg_weekly_demand,
    ROUND(d.sd_weekly_units,2)                                     AS sd_weekly_demand,
    ROUND(d.demand_cv,3)                                           AS demand_cv,
    d.weeks_with_demand, d.weeks_observed,
    ROUND(100.0*d.weeks_with_demand/NULLIF(d.weeks_observed,0),1)  AS demand_frequency_pct,

    a.lead_time_days,
    ROUND(a.lead_time_days/7.0,2)                                  AS lead_time_weeks,

    -- Safety stock = Z x sigma_weekly x sqrt(lead time in weeks)
    ROUND(a.z_service_95 * d.sd_weekly_units * SQRT(a.lead_time_days/7.0),1) AS safety_stock_units,
    -- Reorder point = expected demand over lead time + safety stock
    ROUND(d.avg_weekly_units * (a.lead_time_days/7.0)
          + a.z_service_95 * d.sd_weekly_units * SQRT(a.lead_time_days/7.0),1) AS reorder_point_units,
    -- EOQ = sqrt(2 D S / H)
    ROUND(SQRT( (2.0 * (d.total_units * 365.0/NULLIF(a.window_days,0)) * a.ordering_cost_gbp)
                / NULLIF(a.holding_rate * d.avg_selling_price * a.cost_ratio, 0) ),1) AS eoq_units,

    ROUND(d.total_units * 365.0/NULLIF(a.window_days,0),1)         AS annual_demand_units
FROM sku_demand_stats d
JOIN dim_product p USING (stock_code)
CROSS JOIN planning_assumptions a;

-- Derived cover / turnover metrics (kept in a second pass so the EOQ and safety
-- stock expressions above are not repeated inside them)
CREATE OR REPLACE TABLE sku_inventory_metrics AS
SELECT s.*,
    ROUND(s.safety_stock_units + s.eoq_units/2.0, 1)                            AS avg_inventory_units,
    ROUND((s.safety_stock_units + s.eoq_units/2.0) * s.unit_cost, 2)            AS avg_inventory_value,
    ROUND(s.annual_demand_units
          / NULLIF(s.safety_stock_units + s.eoq_units/2.0, 0), 2)               AS implied_turnover,
    ROUND(365.0 / NULLIF(s.annual_demand_units
          / NULLIF(s.safety_stock_units + s.eoq_units/2.0, 0), 0), 1)           AS days_of_inventory,
    d.units_last_90d, d.units_prior, d.days_since_last_sale, d.last_sale_date,
    -- Demand momentum: last 90 days vs the equivalent run-rate before it.
    -- This is what separates "we hold stock for demand that has gone" from
    -- "demand is accelerating and we will stock out".
    ROUND(
      (d.units_last_90d / 90.0)
      / NULLIF(d.units_prior / NULLIF(GREATEST(a.window_days - 90, 1), 0), 0), 3) AS demand_momentum
FROM sku_planning s
JOIN sku_demand_stats d USING (stock_code)
CROSS JOIN planning_assumptions a;

-- -----------------------------------------------------------------------------
-- 4. Stock status classification
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE sku_stock_status AS
SELECT *,
    CASE
        WHEN days_since_last_sale > 180                          THEN 'Dead stock'
        WHEN demand_momentum IS NULL                             THEN 'Insufficient history'
        WHEN demand_momentum < 0.5 AND total_units >= 50          THEN 'Overstock risk'
        WHEN demand_momentum > 1.5 AND demand_cv > 0.75           THEN 'Stockout risk - volatile growth'
        WHEN demand_momentum > 1.5                                THEN 'Stockout risk - growing'
        WHEN xyz_class = 'Z' AND abc_class = 'A'                  THEN 'Stockout risk - erratic A-item'
        ELSE 'Healthy'
    END AS stock_status
FROM sku_inventory_metrics;

COPY (SELECT * FROM sku_stock_status ORDER BY total_revenue DESC)
  TO 'outputs/inventory_planning_by_sku.csv' (HEADER, DELIMITER ',');

-- =============================================================================
--  PUBLISHED MARTS
-- =============================================================================

-- Executive KPI row --------------------------------------------------------------
COPY (
SELECT
    (SELECT COUNT(*) FROM dim_product)                                   AS total_skus,
    (SELECT COUNT(*) FROM fct_sales)                                     AS sales_lines,
    (SELECT SUM(units_sold) FROM fct_sales)                              AS units_sold,
    (SELECT ROUND(SUM(revenue),2) FROM fct_sales)                        AS total_revenue,
    (SELECT COUNT(*) FROM fct_returns)                                   AS return_lines,
    (SELECT SUM(units_returned) FROM fct_returns)                        AS units_returned,
    (SELECT ROUND(SUM(return_value),2) FROM fct_returns)                 AS return_value,
    ROUND(100.0 * (SELECT SUM(return_value) FROM fct_returns)
                / (SELECT SUM(revenue) FROM fct_sales), 2)               AS return_rate_pct,
    (SELECT ROUND(AVG(implied_turnover),2) FROM sku_stock_status
       WHERE implied_turnover IS NOT NULL)                               AS avg_implied_turnover,
    (SELECT ROUND(MEDIAN(days_of_inventory),1) FROM sku_stock_status)    AS median_days_of_inventory,
    (SELECT ROUND(SUM(avg_inventory_value),2) FROM sku_stock_status)     AS total_inventory_value,
    (SELECT COUNT(*) FROM sku_stock_status WHERE stock_status LIKE 'Stockout%') AS stockout_risk_skus,
    (SELECT COUNT(*) FROM sku_stock_status WHERE stock_status='Overstock risk') AS overstock_skus,
    (SELECT COUNT(*) FROM sku_stock_status WHERE stock_status='Dead stock')     AS dead_stock_skus,
    (SELECT COUNT(*) FROM fct_purchase_order)                            AS purchase_orders,
    (SELECT COUNT(DISTINCT vendor) FROM fct_purchase_order)              AS vendors,
    (SELECT ROUND(100.0*AVG(is_on_time),2) FROM fct_purchase_order WHERE is_on_time IS NOT NULL) AS supplier_otif_pct,
    (SELECT ROUND(MEDIAN(lead_time_days),1) FROM fct_purchase_order WHERE lead_time_days BETWEEN 0 AND 365) AS median_vendor_lead_days
) TO 'outputs/inventory_kpi_executive.csv' (HEADER, DELIMITER ',');

-- ABC-XYZ summary -- the 80/20 proof ---------------------------------------------
COPY (
SELECT abc_class,
       COUNT(*)                                                     AS skus,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2)                AS pct_of_skus,
       SUM(total_units)                                             AS units,
       ROUND(SUM(total_revenue),2)                                  AS revenue,
       ROUND(100.0*SUM(total_revenue)/SUM(SUM(total_revenue)) OVER (),2) AS pct_of_revenue,
       ROUND(SUM(avg_inventory_value),2)                            AS inventory_value,
       ROUND(AVG(implied_turnover),2)                               AS avg_turnover,
       ROUND(AVG(days_of_inventory),1)                              AS avg_days_of_inventory
FROM sku_stock_status GROUP BY 1 ORDER BY 1
) TO 'outputs/abc_summary.csv' (HEADER, DELIMITER ',');

COPY (
SELECT abc_xyz_cell, abc_class, xyz_class,
       COUNT(*) AS skus, SUM(total_units) AS units,
       ROUND(SUM(total_revenue),2) AS revenue,
       ROUND(AVG(demand_cv),3) AS avg_demand_cv,
       ROUND(SUM(safety_stock_units),0) AS total_safety_stock_units,
       ROUND(SUM(avg_inventory_value),2) AS inventory_value
FROM sku_stock_status GROUP BY 1,2,3 ORDER BY 2,3
) TO 'outputs/abc_xyz_matrix.csv' (HEADER, DELIMITER ',');

-- Fast / slow movers --------------------------------------------------------------
COPY (
SELECT stock_code, product_name, category, abc_class, xyz_class,
       total_units, total_revenue, avg_weekly_demand, demand_cv,
       reorder_point_units, safety_stock_units, eoq_units,
       implied_turnover, days_of_inventory, stock_status
FROM sku_stock_status ORDER BY total_units DESC LIMIT 200
) TO 'outputs/fast_moving_products.csv' (HEADER, DELIMITER ',');

COPY (
SELECT stock_code, product_name, category, abc_class, xyz_class,
       total_units, total_revenue, days_since_last_sale, last_sale_date,
       avg_inventory_value, stock_status
FROM sku_stock_status
WHERE total_units <= 20 OR days_since_last_sale > 180
ORDER BY total_units ASC, days_since_last_sale DESC
) TO 'outputs/slow_moving_products.csv' (HEADER, DELIMITER ',');

-- Risk registers -------------------------------------------------------------------
COPY (
SELECT stock_code, product_name, category, abc_class, xyz_class, stock_status,
       total_units, total_revenue, avg_weekly_demand, demand_cv, demand_momentum,
       units_last_90d, reorder_point_units, safety_stock_units
FROM sku_stock_status WHERE stock_status LIKE 'Stockout%'
ORDER BY total_revenue DESC
) TO 'outputs/stockout_risk_products.csv' (HEADER, DELIMITER ',');

COPY (
SELECT stock_code, product_name, category, abc_class, xyz_class, stock_status,
       total_units, total_revenue, demand_momentum, units_last_90d, units_prior,
       days_since_last_sale, avg_inventory_value, days_of_inventory
FROM sku_stock_status WHERE stock_status IN ('Overstock risk','Dead stock')
ORDER BY avg_inventory_value DESC
) TO 'outputs/overstock_products.csv' (HEADER, DELIMITER ',');

COPY (
SELECT stock_status, COUNT(*) AS skus,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS pct_of_skus,
       SUM(total_units) AS units, ROUND(SUM(total_revenue),2) AS revenue,
       ROUND(SUM(avg_inventory_value),2) AS inventory_value
FROM sku_stock_status GROUP BY 1 ORDER BY inventory_value DESC
) TO 'outputs/stock_status_summary.csv' (HEADER, DELIMITER ',');

-- Category performance --------------------------------------------------------------
COPY (
SELECT category,
       COUNT(*) AS skus, SUM(total_units) AS units,
       ROUND(SUM(total_revenue),2) AS revenue,
       ROUND(100.0*SUM(total_revenue)/SUM(SUM(total_revenue)) OVER (),2) AS pct_of_revenue,
       ROUND(AVG(avg_selling_price),2) AS avg_price,
       ROUND(AVG(implied_turnover),2)  AS avg_turnover,
       ROUND(AVG(days_of_inventory),1) AS avg_days_of_inventory,
       ROUND(SUM(avg_inventory_value),2) AS inventory_value,
       SUM(CASE WHEN stock_status LIKE 'Stockout%' THEN 1 ELSE 0 END) AS stockout_risk_skus,
       SUM(CASE WHEN stock_status='Dead stock' THEN 1 ELSE 0 END)     AS dead_skus
FROM sku_stock_status GROUP BY 1 ORDER BY revenue DESC
) TO 'outputs/category_performance.csv' (HEADER, DELIMITER ',');

-- Monthly sales trend ------------------------------------------------------------
COPY (
SELECT year_month,
       COUNT(DISTINCT invoice_no) AS invoices,
       COUNT(*) AS lines, SUM(units_sold) AS units,
       ROUND(SUM(revenue),2) AS revenue,
       COUNT(DISTINCT stock_code) AS active_skus,
       COUNT(DISTINCT customer_id) AS active_customers,
       ROUND(SUM(revenue)/NULLIF(COUNT(DISTINCT invoice_no),0),2) AS avg_order_value
FROM fct_sales GROUP BY 1 ORDER BY 1
) TO 'outputs/monthly_sales.csv' (HEADER, DELIMITER ',');

-- Returns (real credit notes) ------------------------------------------------------
COPY (
WITH s AS (SELECT category, SUM(revenue) rev, SUM(units_sold) u FROM fct_sales GROUP BY 1),
     r AS (SELECT category, SUM(return_value) rv, SUM(units_returned) ru, COUNT(*) rl FROM fct_returns GROUP BY 1)
SELECT s.category, ROUND(s.rev,2) AS revenue, s.u AS units_sold,
       COALESCE(r.rl,0) AS return_lines, COALESCE(r.ru,0) AS units_returned,
       ROUND(COALESCE(r.rv,0),2) AS return_value,
       ROUND(100.0*COALESCE(r.rv,0)/NULLIF(s.rev,0),2) AS return_rate_pct
FROM s LEFT JOIN r USING(category) ORDER BY return_rate_pct DESC
) TO 'outputs/returns_analysis.csv' (HEADER, DELIMITER ',');

-- Warehouse / market distribution --------------------------------------------------
COPY (
SELECT market, country,
       COUNT(DISTINCT invoice_no) AS invoices,
       COUNT(DISTINCT stock_code) AS skus_shipped,
       SUM(units_sold) AS units, ROUND(SUM(revenue),2) AS revenue,
       ROUND(100.0*SUM(revenue)/SUM(SUM(revenue)) OVER (),3) AS pct_of_revenue,
       ROUND(AVG(unit_price),2) AS avg_unit_price
FROM fct_sales GROUP BY 1,2 ORDER BY revenue DESC
) TO 'outputs/market_distribution.csv' (HEADER, DELIMITER ',');

-- Product availability: how consistently a SKU is actually sellable -----------------
COPY (
SELECT stock_code, product_name, category, abc_class,
       weeks_with_demand, weeks_observed, demand_frequency_pct,
       days_since_last_sale,
       CASE WHEN demand_frequency_pct >= 80 THEN 'Continuously available'
            WHEN demand_frequency_pct >= 50 THEN 'Mostly available'
            WHEN demand_frequency_pct >= 20 THEN 'Intermittent'
            ELSE 'Rarely available' END AS availability_band
FROM sku_stock_status ORDER BY demand_frequency_pct DESC
) TO 'outputs/product_availability.csv' (HEADER, DELIMITER ',');

SELECT 'inventory marts written' AS status;
