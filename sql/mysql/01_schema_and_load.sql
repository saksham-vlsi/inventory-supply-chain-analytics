-- =============================================================================
--  MySQL 8.0  --  SCHEMA + LOAD
-- =============================================================================
--  Five related tables. This is the reference relational implementation; the
--  DuckDB pipeline in ../ produces the committed outputs, and both implement
--  the identical metric definitions in docs/03_metric_definitions.md.
--
--  Run:
--      mysql -u root -p < 01_schema_and_load.sql
--
--  LOAD DATA LOCAL INFILE requires:
--      SET GLOBAL local_infile = 1;             -- server side
--      mysql --local-infile=1 -u root -p        -- client side
-- =============================================================================

DROP DATABASE IF EXISTS inventory_scm;
CREATE DATABASE inventory_scm CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE inventory_scm;

-- -----------------------------------------------------------------------------
-- 1. dim_product -- SKU master (derived: the source feed has no product table)
-- -----------------------------------------------------------------------------
CREATE TABLE dim_product (
    stock_code      VARCHAR(20)   NOT NULL,
    product_name    VARCHAR(255)  NOT NULL,
    category        VARCHAR(60)   NOT NULL DEFAULT 'Other',
    PRIMARY KEY (stock_code),
    KEY idx_product_category (category)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 2. fct_sales -- clean outbound demand
-- -----------------------------------------------------------------------------
CREATE TABLE fct_sales (
    sale_id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    invoice_no      VARCHAR(20)   NOT NULL,
    stock_code      VARCHAR(20)   NOT NULL,
    units_sold      INT           NOT NULL,
    unit_price      DECIMAL(12,4) NOT NULL,
    revenue         DECIMAL(14,4) NOT NULL,
    customer_id     BIGINT            NULL,
    country         VARCHAR(60)   NOT NULL,
    market          VARCHAR(30)   NOT NULL,
    invoice_date    DATE          NOT NULL,
    year_month_key  CHAR(7)       NOT NULL,
    week_start      DATE          NOT NULL,
    PRIMARY KEY (sale_id),
    KEY idx_sales_sku   (stock_code),
    KEY idx_sales_date  (invoice_date),
    KEY idx_sales_month (year_month_key),
    KEY idx_sales_week  (stock_code, week_start),
    CONSTRAINT fk_sales_product FOREIGN KEY (stock_code)
        REFERENCES dim_product (stock_code) ON DELETE RESTRICT,
    CONSTRAINT chk_sales_qty   CHECK (units_sold > 0),
    CONSTRAINT chk_sales_price CHECK (unit_price > 0)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 3. fct_returns -- real credit notes
-- -----------------------------------------------------------------------------
CREATE TABLE fct_returns (
    return_id       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    invoice_no      VARCHAR(20)   NOT NULL,
    stock_code      VARCHAR(20)   NOT NULL,
    units_returned  INT           NOT NULL,
    unit_price      DECIMAL(12,4) NOT NULL,
    return_value    DECIMAL(14,4) NOT NULL,
    customer_id     BIGINT            NULL,
    country         VARCHAR(60)   NOT NULL,
    market          VARCHAR(30)   NOT NULL,
    return_date     DATE          NOT NULL,
    year_month_key  CHAR(7)       NOT NULL,
    PRIMARY KEY (return_id),
    KEY idx_returns_sku  (stock_code),
    KEY idx_returns_date (return_date),
    CONSTRAINT chk_returns_qty CHECK (units_returned > 0)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 4. fct_purchase_order -- inbound procurement
-- -----------------------------------------------------------------------------
CREATE TABLE fct_purchase_order (
    po_row_id               VARCHAR(20)   NOT NULL,
    po_number               VARCHAR(60)       NULL,
    project_code            VARCHAR(60)       NULL,
    vendor                  VARCHAR(160)  NOT NULL,
    manufacturing_site      VARCHAR(160)      NULL,
    destination_country     VARCHAR(80)       NULL,
    product_group           VARCHAR(60)       NULL,
    sub_classification      VARCHAR(80)       NULL,
    shipment_mode           VARCHAR(40)       NULL,
    qty_ordered             BIGINT            NULL,
    line_value_usd          DECIMAL(16,4)     NULL,
    unit_price_usd          DECIMAL(14,6)     NULL,
    freight_cost_usd        DECIMAL(16,4)     NULL,
    weight_kg               DECIMAL(14,3)     NULL,
    po_sent_date            DATE              NULL,
    scheduled_date          DATE              NULL,
    delivered_date          DATE              NULL,
    lead_time_days          INT               NULL,
    delivery_variance_days  INT               NULL,
    is_on_time              TINYINT           NULL,
    delivery_month          CHAR(7)           NULL,
    PRIMARY KEY (po_row_id),
    KEY idx_po_vendor (vendor),
    KEY idx_po_month  (delivery_month),
    KEY idx_po_group  (product_group)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 5. sku_planning -- computed planning parameters, one row per SKU
-- -----------------------------------------------------------------------------
CREATE TABLE sku_planning (
    stock_code           VARCHAR(20)   NOT NULL,
    abc_class            CHAR(1)       NOT NULL,
    xyz_class            CHAR(1)       NOT NULL,
    abc_xyz_cell         CHAR(2)       NOT NULL,
    total_units          BIGINT        NOT NULL,
    total_revenue        DECIMAL(16,4) NOT NULL,
    revenue_rank         INT           NOT NULL,
    cum_revenue_pct      DECIMAL(8,4)  NOT NULL,
    avg_selling_price    DECIMAL(12,4) NOT NULL,
    unit_cost            DECIMAL(12,4) NOT NULL,
    avg_weekly_demand    DECIMAL(12,4) NOT NULL,
    sd_weekly_demand     DECIMAL(12,4) NOT NULL,
    demand_cv            DECIMAL(10,4)     NULL,
    lead_time_days       INT           NOT NULL,
    safety_stock_units   DECIMAL(12,2) NOT NULL,
    reorder_point_units  DECIMAL(12,2) NOT NULL,
    eoq_units            DECIMAL(12,2) NOT NULL,
    annual_demand_units  DECIMAL(14,2) NOT NULL,
    avg_inventory_units  DECIMAL(12,2) NOT NULL,
    avg_inventory_value  DECIMAL(16,4) NOT NULL,
    implied_turnover     DECIMAL(10,4)     NULL,
    days_of_inventory    DECIMAL(10,2)     NULL,
    demand_momentum      DECIMAL(10,4)     NULL,
    days_since_last_sale INT               NULL,
    stock_status         VARCHAR(40)   NOT NULL,
    PRIMARY KEY (stock_code),
    KEY idx_plan_abc    (abc_class, xyz_class),
    KEY idx_plan_status (stock_status),
    CONSTRAINT fk_plan_product FOREIGN KEY (stock_code)
        REFERENCES dim_product (stock_code) ON DELETE CASCADE
) ENGINE=InnoDB;

-- =============================================================================
--  LOAD  (from the pipeline outputs)
-- =============================================================================
--  Point these at the absolute path of your outputs/ folder.
--  Foreign keys are deferred during load for speed, then re-enabled.
-- -----------------------------------------------------------------------------
SET FOREIGN_KEY_CHECKS = 0;

LOAD DATA LOCAL INFILE 'outputs/mysql_load/dim_product.csv'
INTO TABLE dim_product
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 ROWS (stock_code, product_name, category);

LOAD DATA LOCAL INFILE 'outputs/mysql_load/fct_sales.csv'
INTO TABLE fct_sales
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(invoice_no, stock_code, @units, @price, @rev, @cust, country, market, @dt, year_month_key, @wk)
SET units_sold    = @units,
    unit_price    = @price,
    revenue       = @rev,
    customer_id   = NULLIF(@cust,''),
    invoice_date  = STR_TO_DATE(@dt,'%Y-%m-%d'),
    week_start    = STR_TO_DATE(@wk,'%Y-%m-%d');

LOAD DATA LOCAL INFILE 'outputs/mysql_load/fct_returns.csv'
INTO TABLE fct_returns
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(invoice_no, stock_code, @units, @price, @val, @cust, country, market, @dt, year_month_key)
SET units_returned = @units, unit_price = @price, return_value = @val,
    customer_id    = NULLIF(@cust,''), return_date = STR_TO_DATE(@dt,'%Y-%m-%d');

LOAD DATA LOCAL INFILE 'outputs/mysql_load/fct_purchase_order.csv'
INTO TABLE fct_purchase_order
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(po_row_id, po_number, project_code, vendor, manufacturing_site, destination_country,
 product_group, sub_classification, shipment_mode, @qty, @val, @up, @fc, @wt,
 @pod, @schd, @deld, @lt, @dv, @ot, @dm)
SET qty_ordered = NULLIF(@qty,''), line_value_usd = NULLIF(@val,''),
    unit_price_usd = NULLIF(@up,''), freight_cost_usd = NULLIF(@fc,''),
    weight_kg = NULLIF(@wt,''),
    po_sent_date   = NULLIF(STR_TO_DATE(@pod ,'%Y-%m-%d'),''),
    scheduled_date = NULLIF(STR_TO_DATE(@schd,'%Y-%m-%d'),''),
    delivered_date = NULLIF(STR_TO_DATE(@deld,'%Y-%m-%d'),''),
    lead_time_days = NULLIF(@lt,''), delivery_variance_days = NULLIF(@dv,''),
    is_on_time = NULLIF(@ot,''), delivery_month = NULLIF(@dm,'');

LOAD DATA LOCAL INFILE 'outputs/inventory_planning_by_sku.csv'
INTO TABLE sku_planning
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(stock_code, @pname, @cat, abc_class, xyz_class, abc_xyz_cell, total_units, total_revenue,
 revenue_rank, cum_revenue_pct, avg_selling_price, unit_cost, avg_weekly_demand,
 sd_weekly_demand, @cv, @wwd, @wo, @dfp, lead_time_days, @ltw, safety_stock_units,
 reorder_point_units, eoq_units, annual_demand_units, avg_inventory_units,
 avg_inventory_value, @turn, @doi, @u90, @uprior, days_since_last_sale, @lsd, @mom, stock_status)
SET demand_cv        = NULLIF(@cv,''),
    implied_turnover = NULLIF(@turn,''),
    days_of_inventory= NULLIF(@doi,''),
    demand_momentum  = NULLIF(@mom,'');

SET FOREIGN_KEY_CHECKS = 1;

-- Load receipt
SELECT 'dim_product' AS table_name, COUNT(*) AS row_count FROM dim_product
UNION ALL SELECT 'fct_sales',          COUNT(*) FROM fct_sales
UNION ALL SELECT 'fct_returns',        COUNT(*) FROM fct_returns
UNION ALL SELECT 'fct_purchase_order', COUNT(*) FROM fct_purchase_order
UNION ALL SELECT 'sku_planning',       COUNT(*) FROM sku_planning;

