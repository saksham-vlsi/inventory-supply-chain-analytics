-- =============================================================================
--  02_data_quality.sql   |   DATA QUALITY GATE  (both feeds)
-- =============================================================================
--  Inventory analytics is unusually sensitive to dirty data: one uncleaned
--  "MANUAL ADJUSTMENT" line with a quantity of -9,600 will wreck a demand
--  average, a safety stock and a reorder point in one go. This gate runs before
--  any planning parameter is computed.
-- =============================================================================

CREATE OR REPLACE TABLE dq_report AS
WITH checks AS (

    -- ---- DEMAND FEED : composition ------------------------------------------
    SELECT 'CMP-01' AS rule_id,'INFO' AS severity,'Total raw lines ingested' AS rule_name,
           COUNT(*) AS row_count FROM stg_retail_typed
    UNION ALL SELECT 'CMP-02','INFO','Lines classified as clean SALE',COUNT(*)
           FROM stg_retail_typed WHERE line_type='SALE'
    UNION ALL SELECT 'CMP-03','INFO','Lines classified as RETURN (credit notes)',COUNT(*)
           FROM stg_retail_typed WHERE line_type='RETURN'
    UNION ALL SELECT 'CMP-04','WARN','Admin postings excluded from demand (postage, fees, adjustments)',COUNT(*)
           FROM stg_retail_typed WHERE line_type='ADMIN'
    UNION ALL SELECT 'CMP-05','WARN','Zero-price lines excluded from demand',COUNT(*)
           FROM stg_retail_typed WHERE line_type='ZERO_PRICE'
    UNION ALL SELECT 'CMP-06','WARN','Non-credit negative-quantity adjustments excluded',COUNT(*)
           FROM stg_retail_typed WHERE line_type='ADJUSTMENT'

    -- ---- DEMAND FEED : integrity --------------------------------------------
    UNION ALL SELECT 'VAL-01','BLOCK','SALE line with non-positive quantity',COUNT(*)
           FROM fct_sales WHERE units_sold <= 0
    UNION ALL SELECT 'VAL-02','BLOCK','SALE line with non-positive price',COUNT(*)
           FROM fct_sales WHERE unit_price <= 0
    UNION ALL SELECT 'VAL-03','BLOCK','Invoice date outside the stated 2009-2011 window',COUNT(*)
           FROM fct_sales WHERE invoice_date < DATE '2009-12-01' OR invoice_date > DATE '2011-12-31'
    UNION ALL SELECT 'VAL-04','WARN','Extreme single-line quantity (>10,000 units)',COUNT(*)
           FROM fct_sales WHERE units_sold > 10000
    UNION ALL SELECT 'VAL-05','WARN','Sales lines with no customer ID (cash / guest sales)',COUNT(*)
           FROM fct_sales WHERE customer_id IS NULL

    -- ---- DEMAND FEED : classification coverage -------------------------------
    UNION ALL SELECT 'CAT-01','WARN','SKUs not matched by the category rules (fall back to Other)',COUNT(*)
           FROM dim_product WHERE category = 'Other'
    UNION ALL SELECT 'CAT-02','WARN','SKUs whose description varies across lines',COUNT(*)
           FROM (SELECT stock_code FROM fct_sales GROUP BY 1 HAVING COUNT(DISTINCT description) > 1)

    -- ---- PROCUREMENT FEED ----------------------------------------------------
    UNION ALL SELECT 'PO-01','INFO','Purchase orders ingested',COUNT(*) FROM fct_purchase_order
    UNION ALL SELECT 'PO-02','WARN','PO date unparseable (source holds "Date Not Captured" / "Pre-PQ Process")',COUNT(*)
           FROM fct_purchase_order WHERE po_sent_date IS NULL
    UNION ALL SELECT 'PO-03','WARN','Scheduled delivery date unparseable',COUNT(*)
           FROM fct_purchase_order WHERE scheduled_date IS NULL
    UNION ALL SELECT 'PO-04','BLOCK','Delivered before the PO was raised',COUNT(*)
           FROM fct_purchase_order WHERE delivered_date < po_sent_date
    UNION ALL SELECT 'PO-05','WARN','Negative lead time excluded from supplier averages',COUNT(*)
           FROM fct_purchase_order WHERE lead_time_days < 0
    UNION ALL SELECT 'PO-06','WARN','Freight cost not numeric in source (text such as "Invoiced Separately")',COUNT(*)
           FROM fct_purchase_order WHERE freight_cost_usd IS NULL
    UNION ALL SELECT 'PO-07','BLOCK','PO with non-positive quantity',COUNT(*)
           FROM fct_purchase_order WHERE qty_ordered <= 0
)
SELECT rule_id, severity, rule_name, row_count,
       CASE WHEN severity='INFO' THEN 'INFO'
            WHEN row_count = 0   THEN 'PASS' ELSE 'FAIL' END AS status
FROM checks
ORDER BY CASE severity WHEN 'BLOCK' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END, row_count DESC;

COPY dq_report TO 'outputs/data_quality_report.csv' (HEADER, DELIMITER ',');
SELECT * FROM dq_report;
