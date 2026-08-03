-- =============================================================================
--  04_supplier_analysis.sql   |   PROCUREMENT MART
-- =============================================================================
--  Supplier lead time, schedule adherence, ranking and purchase frequency, from
--  10,324 real purchase orders with vendor, scheduled date and actual receipt.
--
--  Lead-time averages exclude negative and >365-day values -- the source carries
--  a small number of impossible date pairs (see PO-04/PO-05 in the DQ gate).
--  They are excluded from averages, never from counts.
-- =============================================================================

CREATE OR REPLACE VIEW v_po AS
SELECT *,
       CASE WHEN lead_time_days BETWEEN 0 AND 365 THEN 1 ELSE 0 END AS is_leadtime_valid
FROM fct_purchase_order;

-- -----------------------------------------------------------------------------
--  Supplier scorecard -- the ranking table
-- -----------------------------------------------------------------------------
COPY (
WITH v AS (
  SELECT vendor,
         COUNT(*)                                                          AS purchase_orders,
         COUNT(DISTINCT po_number)                                         AS distinct_pos,
         SUM(qty_ordered)                                                  AS units_ordered,
         ROUND(SUM(line_value_usd),2)                                      AS spend_usd,
         ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN lead_time_days END),1)  AS avg_lead_days,
         ROUND(MEDIAN(CASE WHEN is_leadtime_valid=1 THEN lead_time_days END),1) AS median_lead_days,
         ROUND(STDDEV_SAMP(CASE WHEN is_leadtime_valid=1 THEN lead_time_days END),1) AS sd_lead_days,
         ROUND(100.0*AVG(is_on_time),2)                                    AS otif_pct,
         ROUND(AVG(delivery_variance_days),1)                              AS avg_days_late,
         ROUND(SUM(freight_cost_usd),2)                                    AS freight_usd,
         COUNT(DISTINCT product_group)                                     AS product_groups,
         COUNT(DISTINCT destination_country)                               AS countries_served
  FROM v_po GROUP BY vendor
)
SELECT vendor, purchase_orders, distinct_pos, units_ordered, spend_usd,
       avg_lead_days, median_lead_days, sd_lead_days,
       -- Reliability = consistency of lead time. A supplier averaging 60 days
       -- +/- 5 is far easier to plan around than one averaging 40 +/- 40.
       ROUND(sd_lead_days / NULLIF(avg_lead_days,0), 3)                    AS lead_time_cv,
       otif_pct, avg_days_late, freight_usd, product_groups, countries_served,
       CASE WHEN otif_pct >= 95 THEN 'A - Preferred'
            WHEN otif_pct >= 85 THEN 'B - Approved'
            WHEN otif_pct >= 70 THEN 'C - Conditional'
            ELSE 'D - Remediation' END                                     AS supplier_band,
       -- Composite score: schedule adherence (60%) + lead-time predictability (40%).
       --
       -- 5,404 of the 10,324 orders are sourced from a regional distribution
       -- centre rather than a vendor PO, so they carry no PO-issue date and no
       -- lead time can be computed. Scoring those on a 0 predictability term
       -- would rank the single largest channel last on missing data alone.
       -- They are scored on adherence only, and `score_basis` says so, so the
       -- ranking is never silently comparing two different things.
       CASE WHEN avg_lead_days IS NULL OR sd_lead_days IS NULL
            THEN 'OTIF only (no lead-time data)'
            ELSE 'OTIF + lead-time predictability' END                      AS score_basis,
       CASE WHEN avg_lead_days IS NULL OR sd_lead_days IS NULL
            THEN ROUND(COALESCE(otif_pct,0),2)
            ELSE ROUND(0.6*COALESCE(otif_pct,0)
                     + 0.4*(100*(1-LEAST(sd_lead_days/NULLIF(avg_lead_days,0),1))),2) END AS supplier_score,
       RANK() OVER (ORDER BY
            CASE WHEN avg_lead_days IS NULL OR sd_lead_days IS NULL
                 THEN COALESCE(otif_pct,0)
                 ELSE 0.6*COALESCE(otif_pct,0)
                    + 0.4*(100*(1-LEAST(sd_lead_days/NULLIF(avg_lead_days,0),1))) END DESC) AS supplier_rank
FROM v WHERE purchase_orders >= 10
ORDER BY supplier_score DESC
) TO 'outputs/supplier_scorecard.csv' (HEADER, DELIMITER ',');

-- Lead-time distribution per supplier ------------------------------------------
COPY (
SELECT vendor,
       COUNT(*) AS orders_measured,
       MIN(lead_time_days) AS min_days,
       ROUND(QUANTILE_CONT(lead_time_days, 0.25),1) AS p25_days,
       ROUND(MEDIAN(lead_time_days),1)              AS median_days,
       ROUND(QUANTILE_CONT(lead_time_days, 0.75),1) AS p75_days,
       ROUND(QUANTILE_CONT(lead_time_days, 0.95),1) AS p95_days,
       MAX(lead_time_days) AS max_days,
       -- P95 is the number a planner should actually buffer against, not the mean
       ROUND(QUANTILE_CONT(lead_time_days, 0.95) - MEDIAN(lead_time_days),1) AS tail_risk_days
FROM v_po WHERE is_leadtime_valid = 1
GROUP BY vendor HAVING COUNT(*) >= 10 ORDER BY median_days DESC
) TO 'outputs/supplier_lead_time.csv' (HEADER, DELIMITER ',');

-- Purchase frequency ------------------------------------------------------------
COPY (
SELECT vendor,
       COUNT(*)                                                     AS purchase_orders,
       MIN(po_sent_date)                                            AS first_po,
       MAX(po_sent_date)                                            AS last_po,
       date_diff('day', MIN(po_sent_date), MAX(po_sent_date))       AS active_days,
       ROUND(date_diff('day', MIN(po_sent_date), MAX(po_sent_date))
             / NULLIF(COUNT(*)-1,0), 1)                             AS avg_days_between_orders,
       ROUND(COUNT(*) * 365.0
             / NULLIF(date_diff('day', MIN(po_sent_date), MAX(po_sent_date)),0), 1) AS orders_per_year,
       ROUND(SUM(line_value_usd),2)                                 AS spend_usd,
       ROUND(AVG(line_value_usd),2)                                 AS avg_order_value_usd
FROM v_po WHERE po_sent_date IS NOT NULL
GROUP BY vendor HAVING COUNT(*) >= 10 ORDER BY purchase_orders DESC
) TO 'outputs/purchase_frequency.csv' (HEADER, DELIMITER ',');

-- Shipment mode: the cost/speed trade-off ----------------------------------------
COPY (
SELECT COALESCE(shipment_mode,'Not specified') AS shipment_mode,
       COUNT(*) AS purchase_orders,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2)                AS pct_of_orders,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN lead_time_days END),1) AS avg_lead_days,
       ROUND(100.0*AVG(is_on_time),2)                               AS otif_pct,
       ROUND(SUM(line_value_usd),2)                                 AS spend_usd,
       ROUND(SUM(freight_cost_usd),2)                               AS freight_usd,
       ROUND(100.0*SUM(freight_cost_usd)/NULLIF(SUM(line_value_usd),0),2) AS freight_pct_of_spend,
       ROUND(SUM(weight_kg),0)                                      AS weight_kg,
       ROUND(SUM(freight_cost_usd)/NULLIF(SUM(weight_kg),0),2)      AS freight_per_kg
FROM v_po GROUP BY 1 ORDER BY purchase_orders DESC
) TO 'outputs/shipment_mode_analysis.csv' (HEADER, DELIMITER ',');

-- Product group procurement ------------------------------------------------------
COPY (
SELECT product_group, sub_classification,
       COUNT(*) AS purchase_orders, SUM(qty_ordered) AS units,
       ROUND(SUM(line_value_usd),2) AS spend_usd,
       ROUND(AVG(unit_price_usd),4) AS avg_unit_price,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN lead_time_days END),1) AS avg_lead_days,
       ROUND(100.0*AVG(is_on_time),2) AS otif_pct
FROM v_po GROUP BY 1,2 ORDER BY spend_usd DESC
) TO 'outputs/product_group_procurement.csv' (HEADER, DELIMITER ',');

-- Manufacturing site / warehouse distribution -------------------------------------
COPY (
SELECT manufacturing_site,
       COUNT(*) AS purchase_orders,
       COUNT(DISTINCT vendor) AS vendors,
       COUNT(DISTINCT destination_country) AS destinations,
       SUM(qty_ordered) AS units, ROUND(SUM(line_value_usd),2) AS spend_usd,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN lead_time_days END),1) AS avg_lead_days,
       ROUND(100.0*AVG(is_on_time),2) AS otif_pct,
       ROUND(100.0*SUM(line_value_usd)/SUM(SUM(line_value_usd)) OVER (),2) AS pct_of_spend
FROM v_po GROUP BY 1 HAVING COUNT(*) >= 10 ORDER BY spend_usd DESC
) TO 'outputs/site_distribution.csv' (HEADER, DELIMITER ',');

-- Monthly procurement trend ---------------------------------------------------------
COPY (
SELECT delivery_month,
       COUNT(*) AS purchase_orders, SUM(qty_ordered) AS units,
       ROUND(SUM(line_value_usd),2) AS spend_usd,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN lead_time_days END),1) AS avg_lead_days,
       ROUND(100.0*AVG(is_on_time),2) AS otif_pct
FROM v_po WHERE delivery_month IS NOT NULL
GROUP BY 1 ORDER BY 1
) TO 'outputs/procurement_monthly.csv' (HEADER, DELIMITER ',');

SELECT 'supplier marts written' AS status;
