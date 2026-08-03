-- =============================================================================
--  05_export_for_mysql.sql
-- =============================================================================
--  Writes the five model tables in exactly the column order that
--  sql/mysql/01_schema_and_load.sql expects, so the MySQL path is a straight
--  LOAD DATA with no manual column mapping.
--
--  These land in outputs/mysql_load/ and are gitignored -- fct_sales alone is
--  ~1M rows. Regenerate with .\run_pipeline.ps1.
-- =============================================================================

COPY (SELECT stock_code, product_name, category FROM dim_product ORDER BY stock_code)
  TO 'outputs/mysql_load/dim_product.csv' (HEADER, DELIMITER ',');

COPY (SELECT invoice_no, stock_code, units_sold, unit_price, revenue,
             customer_id, country, market, invoice_date, year_month, week_start
      FROM fct_sales ORDER BY invoice_date)
  TO 'outputs/mysql_load/fct_sales.csv' (HEADER, DELIMITER ',');

COPY (SELECT invoice_no, stock_code, units_returned, unit_price, return_value,
             customer_id, country, market, return_date, year_month
      FROM fct_returns ORDER BY return_date)
  TO 'outputs/mysql_load/fct_returns.csv' (HEADER, DELIMITER ',');

COPY (SELECT po_row_id, po_number, project_code, vendor, manufacturing_site,
             destination_country, product_group, sub_classification, shipment_mode,
             qty_ordered, line_value_usd, unit_price_usd, freight_cost_usd, weight_kg,
             po_sent_date, scheduled_date, delivered_date,
             lead_time_days, delivery_variance_days, is_on_time, delivery_month
      FROM fct_purchase_order)
  TO 'outputs/mysql_load/fct_purchase_order.csv' (HEADER, DELIMITER ',');

SELECT 'mysql load files written' AS status;
