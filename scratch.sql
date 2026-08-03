CREATE OR REPLACE VIEW s AS SELECT * FROM read_csv_auto('data/raw/scms_delivery_history.csv', header=true, all_varchar=true);
.print === raw date samples ===
SELECT "Scheduled Delivery Date" AS sd, "Delivered to Client Date" AS dd,
       "PO Sent to Vendor Date" AS po, "Delivery Recorded Date" AS rd FROM s LIMIT 6;
.print === PO date value frequency ===
SELECT "PO Sent to Vendor Date" AS po, COUNT(*) AS n FROM s GROUP BY 1 ORDER BY n DESC LIMIT 5;
.print === strptime test d-b-y ===
SELECT COUNT(*) AS total,
  SUM(CASE WHEN TRY_STRPTIME("Scheduled Delivery Date", '%d-%b-%y') IS NULL THEN 1 ELSE 0 END) AS bad_sched,
  SUM(CASE WHEN TRY_STRPTIME("Delivered to Client Date", '%d-%b-%y') IS NULL THEN 1 ELSE 0 END) AS bad_deliv,
  SUM(CASE WHEN TRY_STRPTIME("PO Sent to Vendor Date", '%d-%b-%y') IS NULL THEN 1 ELSE 0 END) AS bad_po
FROM s;
.print === OTIF with correct parsing ===
SELECT COUNT(*) AS measured,
  ROUND(100.0*AVG(CASE WHEN TRY_STRPTIME("Delivered to Client Date",'%d-%b-%y')
                         <= TRY_STRPTIME("Scheduled Delivery Date",'%d-%b-%y') THEN 1.0 ELSE 0 END),2) AS otif_pct,
  ROUND(MEDIAN(date_diff('day', TRY_STRPTIME("PO Sent to Vendor Date",'%d-%b-%y'),
                                TRY_STRPTIME("Delivered to Client Date",'%d-%b-%y'))),1) AS median_lead_days
FROM s
WHERE TRY_STRPTIME("Delivered to Client Date",'%d-%b-%y') IS NOT NULL
  AND TRY_STRPTIME("Scheduled Delivery Date",'%d-%b-%y') IS NOT NULL;
