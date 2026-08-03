-- =============================================================================
--  01_build_model.sql   |   TWO REAL SOURCE FEEDS  ->  ANALYTICAL MODEL
-- =============================================================================
--  An inventory & supply chain analytics system reads from two different
--  operational systems, and this project keeps that shape:
--
--    DEMAND FEED       Online Retail II (UCI) -- 1,067,371 real sales lines,
--                      Dec 2009 - Dec 2011, 5,305 SKUs, 43 countries.
--                      Drives: turnover, days-of-inventory, safety stock,
--                      reorder point, ABC-XYZ, over/under-stock, returns.
--
--    PROCUREMENT FEED  SCMS Delivery History (USAID) -- 10,324 real purchase
--                      orders with vendor, scheduled vs actual delivery date,
--                      freight and manufacturing site.
--                      Drives: supplier lead time, supplier OTIF, supplier
--                      ranking, purchase frequency, site distribution.
--
--  The two feeds are NOT joined -- they describe different businesses. They are
--  two marts in one system, which is exactly how a real inventory analytics
--  platform is built. The only link between them is documented and deliberate:
--  the *observed* vendor lead time from the procurement feed is used as the
--  planning lead-time input for the demand feed's safety-stock model, instead
--  of an invented constant. See docs/03_metric_definitions.md.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Raw landing
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW raw_retail AS
SELECT * FROM read_csv_auto(
    ['data/raw/online_retail_2009_2010.csv','data/raw/online_retail_2010_2011.csv'],
    header=true, all_varchar=true);

CREATE OR REPLACE VIEW raw_scms AS
SELECT * FROM read_csv_auto('data/raw/scms_delivery_history.csv', header=true, all_varchar=true);

-- =============================================================================
--  DEMAND FEED
-- =============================================================================
-- InvoiceDate arrives as an Excel serial number (days since 1899-12-30) because
-- the source is distributed as .xlsx. Converting it is the first cleaning step;
-- leaving it numeric would silently break every time-series metric.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_retail AS
SELECT
    TRIM(Invoice)                                                        AS invoice_no,
    TRIM(StockCode)                                                      AS stock_code,
    UPPER(TRIM(COALESCE(Description,'UNKNOWN')))                         AS description,
    CAST(Quantity AS INTEGER)                                            AS quantity,
    CAST(Price AS DOUBLE)                                                AS unit_price,
    CAST(Quantity AS INTEGER) * CAST(Price AS DOUBLE)                    AS line_value,
    TRY_CAST("Customer ID" AS BIGINT)                                    AS customer_id,
    TRIM(Country)                                                        AS country,
    CAST(TIMESTAMP '1899-12-30 00:00:00'
         + INTERVAL (CAST(ROUND(CAST(InvoiceDate AS DOUBLE) * 86400) AS BIGINT)) SECOND
         AS TIMESTAMP)                                                   AS invoice_ts
FROM raw_retail
WHERE Quantity IS NOT NULL AND Price IS NOT NULL;

-- -----------------------------------------------------------------------------
--  Classify every line. The raw feed mixes real product movement with
--  administrative postings (postage, bank charges, manual adjustments, samples).
--  Counting those as demand corrupts every inventory metric downstream, so they
--  are labelled here and excluded from the demand facts -- not silently dropped,
--  so the volume is auditable in the data-quality report.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_retail_typed AS
SELECT *,
    CASE
        WHEN invoice_no LIKE 'C%'                                   THEN 'RETURN'
        WHEN UPPER(stock_code) IN ('POST','DOT','M','D','C2','BANK CHARGES','CRUK',
                                   'S','AMAZONFEE','B','PADS','GIFT','TEST001','TEST002',
                                   'ADJUST','ADJUST2','SP1002','DCGS0003','DCGS0004')
                                                                    THEN 'ADMIN'
        WHEN REGEXP_MATCHES(UPPER(stock_code), '^(GIFT|BANK|TEST|ADJUST|AMAZON)')  THEN 'ADMIN'
        WHEN description LIKE '%MANUAL%' OR description LIKE '%POSTAGE%'
          OR description LIKE '%CARRIAGE%' OR description LIKE '%SAMPLE%'
          OR description LIKE '%DOTCOM%'  OR description LIKE '%AMAZON%'
          OR description LIKE '%BANK CHARGE%' OR description LIKE '%ADJUST%'
          OR description LIKE '%CHECK%'   OR description LIKE '%DAMAGE%'
          OR description LIKE '%FOUND%'   OR description LIKE '%LOST%'
          OR description LIKE '%SMASHED%' OR description LIKE '%WRONG%'
          OR description LIKE '%MISSING%' OR description LIKE '%?%'
                                                                    THEN 'ADMIN'
        WHEN quantity <= 0                                          THEN 'ADJUSTMENT'
        WHEN unit_price <= 0                                        THEN 'ZERO_PRICE'
        ELSE 'SALE'
    END AS line_type,

    -- Rules-based category. The source has no category column; this derives one
    -- from the product description. Coverage is reported in the DQ gate --
    -- anything unmatched stays 'OTHER' rather than being force-fitted.
    CASE
        WHEN description LIKE '%CHRISTMAS%' OR description LIKE '%ADVENT%'
          OR description LIKE '%SANTA%'    OR description LIKE '%EASTER%'  THEN 'Seasonal & Occasion'
        WHEN description LIKE '%BAG%'      OR description LIKE '%LUNCH%'
          OR description LIKE '%CASE%'     OR description LIKE '%WALLET%'  THEN 'Bags & Luggage'
        WHEN description LIKE '%CANDLE%'   OR description LIKE '%LANTERN%'
          OR description LIKE '%HOLDER%'   OR description LIKE '%T-LIGHT%' THEN 'Candles & Lighting'
        WHEN description LIKE '%MUG%'      OR description LIKE '%CUP%'
          OR description LIKE '%TEAPOT%'   OR description LIKE '%PLATE%'
          OR description LIKE '%BOWL%'     OR description LIKE '%JUG%'
          OR description LIKE '%CUTLERY%'  OR description LIKE '%CAKE STAND%' THEN 'Kitchen & Dining'
        WHEN description LIKE '%CARD%'     OR description LIKE '%WRAP%'
          OR description LIKE '%GIFT TAG%' OR description LIKE '%RIBBON%'  THEN 'Stationery & Giftwrap'
        WHEN description LIKE '%HEART%'    OR description LIKE '%DECORATION%'
          OR description LIKE '%ORNAMENT%' OR description LIKE '%HANGING%'
          OR description LIKE '%SIGN%'     OR description LIKE '%FRAME%'   THEN 'Home Decor'
        WHEN description LIKE '%TOY%'      OR description LIKE '%GAME%'
          OR description LIKE '%PUZZLE%'   OR description LIKE '%DOLL%'
          OR description LIKE '%PLAYHOUSE%' OR description LIKE '%SKITTLE%' THEN 'Toys & Games'
        WHEN description LIKE '%JEWEL%'    OR description LIKE '%NECKLACE%'
          OR description LIKE '%BRACELET%' OR description LIKE '%EARRING%' THEN 'Jewellery'
        WHEN description LIKE '%GARDEN%'   OR description LIKE '%PLANT%'
          OR description LIKE '%WATERING%' OR description LIKE '%BIRD%'    THEN 'Garden & Outdoor'
        WHEN description LIKE '%TOWEL%'    OR description LIKE '%CUSHION%'
          OR description LIKE '%APRON%'    OR description LIKE '%TEA COSY%'
          OR description LIKE '%HOT WATER BOTTLE%'                         THEN 'Textiles & Soft Furnishing'
        WHEN description LIKE '%BOX%'      OR description LIKE '%TIN%'
          OR description LIKE '%JAR%'      OR description LIKE '%STORAGE%'
          OR description LIKE '%DRAWER%'   OR description LIKE '%BASKET%'  THEN 'Storage & Organisation'
        ELSE 'Other'
    END AS category
FROM stg_retail;

-- Region rollup so warehouse/market analysis has a hierarchy
CREATE OR REPLACE MACRO market_of(c) AS
  CASE WHEN c IN ('United Kingdom','Channel Islands')                          THEN 'UK Domestic'
       WHEN c IN ('EIRE','France','Germany','Netherlands','Belgium','Spain','Portugal',
                  'Italy','Austria','Switzerland','Denmark','Sweden','Norway','Finland',
                  'Poland','Czech Republic','Greece','Malta','Cyprus','Lithuania','Iceland') THEN 'Europe'
       WHEN c IN ('USA','Canada','Brazil')                                     THEN 'Americas'
       WHEN c IN ('Australia','Japan','Singapore','Hong Kong','Korea','Thailand') THEN 'Asia-Pacific'
       WHEN c IN ('United Arab Emirates','Saudi Arabia','Israel','Bahrain','Lebanon') THEN 'Middle East'
       WHEN c IN ('RSA','Nigeria')                                             THEN 'Africa'
       ELSE 'Unspecified' END;

-- -----------------------------------------------------------------------------
--  FCT_SALES -- clean demand only (line_type='SALE')
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE fct_sales AS
SELECT invoice_no, stock_code, description, category,
       quantity AS units_sold, unit_price, line_value AS revenue,
       customer_id, country, market_of(country) AS market,
       invoice_ts,
       CAST(invoice_ts AS DATE)                AS invoice_date,
       strftime(invoice_ts, '%Y-%m')           AS year_month,
       date_trunc('week', invoice_ts)          AS week_start,
       EXTRACT(year FROM invoice_ts)           AS year_num
FROM stg_retail_typed
WHERE line_type = 'SALE';

-- -----------------------------------------------------------------------------
--  FCT_RETURNS -- real credit notes. Quantity is negative in the source; it is
--  flipped to a positive "units returned" so the mart reads naturally.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE fct_returns AS
SELECT invoice_no, stock_code, description, category,
       ABS(quantity) AS units_returned, unit_price,
       ABS(line_value) AS return_value,
       customer_id, country, market_of(country) AS market,
       CAST(invoice_ts AS DATE)      AS return_date,
       strftime(invoice_ts, '%Y-%m') AS year_month
FROM stg_retail_typed
WHERE line_type = 'RETURN' AND quantity < 0;

-- -----------------------------------------------------------------------------
--  DIM_PRODUCT -- one row per SKU, with its dominant description and category
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_product AS
SELECT stock_code,
       ARG_MAX(description, cnt)  AS product_name,
       ARG_MAX(category, cnt)     AS category
FROM (SELECT stock_code, description, category, COUNT(*) cnt
      FROM stg_retail_typed WHERE line_type='SALE' GROUP BY 1,2,3)
GROUP BY stock_code;

-- =============================================================================
--  PROCUREMENT FEED  (SCMS)
-- =============================================================================
--  Dates arrive as text in mixed formats and some carry the literal strings
--  'Date Not Captured' / 'Pre-PQ Process'. TRY_CAST returns NULL rather than
--  failing the load; the DQ gate reports how many.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE fct_purchase_order AS
SELECT
    TRIM(ID)                                     AS po_row_id,
    TRIM("PO / SO #")                            AS po_number,
    TRIM("Project Code")                         AS project_code,
    TRIM(Vendor)                                 AS vendor,
    TRIM("Manufacturing Site")                   AS manufacturing_site,
    TRIM(Country)                                AS destination_country,
    TRIM("Product Group")                        AS product_group,
    TRIM("Sub Classification")                   AS sub_classification,
    TRIM("Item Description")                     AS item_description,
    TRIM("Shipment Mode")                        AS shipment_mode,
    TRIM("Fulfill Via")                          AS fulfil_via,
    TRIM("Vendor INCO Term")                     AS inco_term,
    TRY_CAST("Line Item Quantity" AS BIGINT)     AS qty_ordered,
    TRY_CAST("Line Item Value"    AS DOUBLE)     AS line_value_usd,
    TRY_CAST("Unit Price"         AS DOUBLE)     AS unit_price_usd,
    TRY_CAST("Freight Cost (USD)" AS DOUBLE)     AS freight_cost_usd,
    TRY_CAST("Weight (Kilograms)" AS DOUBLE)     AS weight_kg,

    -- Date formats differ BY COLUMN in this source and none of them is ISO:
    --   Scheduled / Delivered / Recorded : 'd-MMM-yy'  e.g. 2-Jun-06
    --   PO Sent to Vendor                : 'M/d/yy'    e.g. 8/27/14
    -- and the PO column also carries the sentinel strings 'N/A - From RDC'
    -- (5,404 rows, sourced from a regional distribution centre rather than a
    -- vendor PO) and 'Date Not Captured' (328 rows).
    -- A plain CAST silently returns NULL for every one of these, which would
    -- have nulled supplier OTIF entirely. TRY_STRPTIME with the correct mask
    -- per column is the fix; the DQ gate reports what remains unparseable.
    CAST(TRY_STRPTIME("PO Sent to Vendor Date",   '%m/%d/%y') AS DATE) AS po_sent_date,
    CAST(TRY_STRPTIME("Scheduled Delivery Date",  '%d-%b-%y') AS DATE) AS scheduled_date,
    CAST(TRY_STRPTIME("Delivered to Client Date", '%d-%b-%y') AS DATE) AS delivered_date,
    CAST(TRY_STRPTIME("Delivery Recorded Date",   '%d-%b-%y') AS DATE) AS recorded_date,

    -- Lead time = PO issued -> goods received. The core supplier metric.
    date_diff('day', CAST(TRY_STRPTIME("PO Sent to Vendor Date",   '%m/%d/%y') AS DATE),
                     CAST(TRY_STRPTIME("Delivered to Client Date", '%d-%b-%y') AS DATE)) AS lead_time_days,
    -- Schedule adherence: positive = late
    date_diff('day', CAST(TRY_STRPTIME("Scheduled Delivery Date",  '%d-%b-%y') AS DATE),
                     CAST(TRY_STRPTIME("Delivered to Client Date", '%d-%b-%y') AS DATE)) AS delivery_variance_days,
    CASE WHEN TRY_STRPTIME("Delivered to Client Date", '%d-%b-%y') IS NULL
              OR TRY_STRPTIME("Scheduled Delivery Date", '%d-%b-%y') IS NULL THEN NULL
         WHEN CAST(TRY_STRPTIME("Delivered to Client Date", '%d-%b-%y') AS DATE)
              <= CAST(TRY_STRPTIME("Scheduled Delivery Date", '%d-%b-%y') AS DATE) THEN 1 ELSE 0 END AS is_on_time,
    strftime(CAST(TRY_STRPTIME("Delivered to Client Date", '%d-%b-%y') AS DATE), '%Y-%m') AS delivery_month
FROM raw_scms;

-- -----------------------------------------------------------------------------
--  Build receipt
-- -----------------------------------------------------------------------------
SELECT 'stg_retail_typed' AS table_name, COUNT(*) AS row_count FROM stg_retail_typed
UNION ALL SELECT 'fct_sales',           COUNT(*) FROM fct_sales
UNION ALL SELECT 'fct_returns',         COUNT(*) FROM fct_returns
UNION ALL SELECT 'dim_product',         COUNT(*) FROM dim_product
UNION ALL SELECT 'fct_purchase_order',  COUNT(*) FROM fct_purchase_order
ORDER BY 1;
