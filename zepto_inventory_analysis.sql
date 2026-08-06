/* ============================================================================
   ZEPTO INVENTORY — END-TO-END SQL (PostgreSQL)

   Layers:
     zepto_raw       staging, exactly as loaded, prices still in paise
     zepto_rejects   quarantined rows + the reason they failed
     zepto           analytics table, deduplicated, prices in rupees

   Design decisions worth knowing before you read the code:

   1. Failing rows are QUARANTINED, not deleted. The count of what was
      rejected is itself a finding. Deleting it destroys the evidence.

   2. The analytics table carries no CHECK constraints that duplicate the
      quarantine rules. A CHECK that can never fire makes the matching
      "find the bad rows" query dead code — it can only ever return zero.

   3. The category column in this dataset is NOT trustworthy. Five category
      labels are byte-identical copies of another category's block. Step 4
      detects this before any category-level aggregate is computed.

   4. discounted_selling_price * available_quantity is INVENTORY VALUE,
      not revenue. Revenue requires units sold, which this dataset lacks.
   ============================================================================ */

-- ---------------------------------------------------------------------------
-- 0) RESET
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS zepto         CASCADE;
DROP TABLE IF EXISTS zepto_rejects CASCADE;
DROP TABLE IF EXISTS zepto_raw     CASCADE;


-- ---------------------------------------------------------------------------
-- 1) STAGING — load verbatim, keep money in paise so it can only be
--    converted once, in one place, further down.
-- ---------------------------------------------------------------------------
CREATE TABLE zepto_raw (
  row_id                          BIGSERIAL PRIMARY KEY,
  category                        TEXT,
  name                            TEXT,
  mrp_paise                       BIGINT,
  discount_percent                NUMERIC(6,2),
  available_quantity              INT,
  discounted_selling_price_paise  BIGINT,
  weight_in_gms                   INT,
  out_of_stock                    BOOLEAN,
  quantity                        INT
);

/*  LOAD  (update the path; the file is UTF-8 with a BOM)

COPY zepto_raw (category, name, mrp_paise, discount_percent, available_quantity,
                discounted_selling_price_paise, weight_in_gms, out_of_stock, quantity)
FROM 'C:\Users\YOURNAME\Downloads\zepto_v2.csv'
WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
*/

-- Row order matters later: the file stores categories in contiguous blocks,
-- and first-occurrence order is used to pick the surviving duplicate.
-- BIGSERIAL row_id preserves that order.


-- ---------------------------------------------------------------------------
-- 2) QUARANTINE — one row per failure, with a reason
-- ---------------------------------------------------------------------------
CREATE TABLE zepto_rejects (
  row_id         BIGINT,
  category       TEXT,
  name           TEXT,
  reject_reason  TEXT,
  detail         TEXT
);

INSERT INTO zepto_rejects (row_id, category, name, reject_reason, detail)
SELECT row_id, category, name, 'blank_name_or_category', NULL
FROM zepto_raw
WHERE COALESCE(TRIM(name), '') = '' OR COALESCE(TRIM(category), '') = ''

UNION ALL
SELECT row_id, category, name, 'mrp_zero', 'mrp_paise = 0'
FROM zepto_raw WHERE COALESCE(mrp_paise, 0) = 0

UNION ALL
SELECT row_id, category, name, 'selling_price_zero', 'dsp_paise = 0'
FROM zepto_raw WHERE COALESCE(discounted_selling_price_paise, 0) = 0

UNION ALL
SELECT row_id, category, name, 'selling_above_mrp',
       'dsp ' || discounted_selling_price_paise || ' > mrp ' || mrp_paise
FROM zepto_raw
WHERE COALESCE(mrp_paise, 0) > 0
  AND COALESCE(discounted_selling_price_paise, 0) > mrp_paise

UNION ALL
SELECT row_id, category, name, 'weight_zero', NULL
FROM zepto_raw WHERE COALESCE(weight_in_gms, 0) = 0

UNION ALL
SELECT row_id, category, name, 'oos_but_stock_present',
       'available_quantity = ' || available_quantity
FROM zepto_raw
WHERE COALESCE(out_of_stock, FALSE) AND COALESCE(available_quantity, 0) > 0

UNION ALL
SELECT row_id, category, name, 'in_stock_but_no_stock', NULL
FROM zepto_raw
WHERE NOT COALESCE(out_of_stock, FALSE) AND COALESCE(available_quantity, 0) = 0;

-- Quarantine summary — this is a reportable number, not a side effect.
SELECT reject_reason, COUNT(*) AS rows_rejected
FROM zepto_rejects
GROUP BY reject_reason
ORDER BY rows_rejected DESC;


-- ---------------------------------------------------------------------------
-- 3) STRUCTURAL CHECK — run BEFORE trusting any category aggregate.
--    If two categories have identical SKU counts and identical inventory
--    value, they are almost certainly the same rows twice.
-- ---------------------------------------------------------------------------
SELECT
  category,
  COUNT(*)                                                     AS sku_count,
  SUM(discounted_selling_price_paise * available_quantity)/100 AS inv_value_rupees
FROM zepto_raw
GROUP BY category
ORDER BY sku_count DESC, inv_value_rupees DESC;
-- Categories sharing a (sku_count, inv_value) pair are duplicate blocks.

-- Prove it: how many rows are byte-identical apart from the category label?
SELECT
  COUNT(*)                                       AS duplicate_groups,
  SUM(n)                                         AS rows_involved,
  SUM(n) - COUNT(*)                              AS redundant_rows
FROM (
  SELECT name, mrp_paise, discounted_selling_price_paise, discount_percent,
         available_quantity, weight_in_gms, out_of_stock, quantity,
         COUNT(*) AS n
  FROM zepto_raw
  GROUP BY 1,2,3,4,5,6,7,8
  HAVING COUNT(*) > 1
) d;

-- Which category pairs overlap, and by how much?
SELECT a.category AS category_a, b.category AS category_b, COUNT(*) AS shared_rows
FROM zepto_raw a
JOIN zepto_raw b
  ON  a.name = b.name
  AND a.mrp_paise = b.mrp_paise
  AND a.weight_in_gms = b.weight_in_gms
  AND a.category < b.category
GROUP BY 1, 2
ORDER BY shared_rows DESC;


-- ---------------------------------------------------------------------------
-- 4) ANALYTICS TABLE — clean rows only, deduplicated, paise converted once.
--    Surviving duplicate = first occurrence in file order. In this dataset
--    the first block of each pair carries the semantically correct label
--    (paneer appears under Dairy before it reappears under Beverages).
-- ---------------------------------------------------------------------------
CREATE TABLE zepto (
  sku_id                    SERIAL PRIMARY KEY,
  source_row_id             BIGINT,
  category                  TEXT          NOT NULL,
  name                      TEXT          NOT NULL,
  mrp                       NUMERIC(12,2) NOT NULL,
  discount_percent          NUMERIC(6,2)  NOT NULL,
  available_quantity        INT           NOT NULL,
  discounted_selling_price  NUMERIC(12,2) NOT NULL,
  weight_in_gms             INT           NOT NULL,
  out_of_stock              BOOLEAN       NOT NULL,
  quantity                  INT           NOT NULL
);

INSERT INTO zepto (source_row_id, category, name, mrp, discount_percent,
                   available_quantity, discounted_selling_price,
                   weight_in_gms, out_of_stock, quantity)
SELECT source_row_id, category, name, mrp, discount_percent,
       available_quantity, discounted_selling_price,
       weight_in_gms, out_of_stock, quantity
FROM (
  SELECT
    r.row_id                                       AS source_row_id,
    TRIM(r.category)                               AS category,
    TRIM(r.name)                                   AS name,
    r.mrp_paise / 100.0                            AS mrp,
    r.discount_percent                             AS discount_percent,
    r.available_quantity                           AS available_quantity,
    r.discounted_selling_price_paise / 100.0       AS discounted_selling_price,
    r.weight_in_gms                                AS weight_in_gms,
    r.out_of_stock                                 AS out_of_stock,
    r.quantity                                     AS quantity,
    ROW_NUMBER() OVER (
      PARTITION BY TRIM(r.name), r.mrp_paise, r.discounted_selling_price_paise,
                   r.discount_percent, r.available_quantity, r.weight_in_gms,
                   r.out_of_stock, r.quantity
      ORDER BY r.row_id
    ) AS occurrence
  FROM zepto_raw r
  WHERE NOT EXISTS (SELECT 1 FROM zepto_rejects x WHERE x.row_id = r.row_id)
) ranked
WHERE occurrence = 1;

-- Natural key: a product is identified by name + pack weight + pack quantity.
-- Grouping on name alone treats different pack sizes as duplicates.
CREATE UNIQUE INDEX ux_zepto_natural_key
  ON zepto (name, weight_in_gms, quantity, mrp);

-- Load reconciliation — the headline data-quality number.
SELECT
  (SELECT COUNT(*) FROM zepto_raw)                       AS rows_loaded,
  (SELECT COUNT(DISTINCT row_id) FROM zepto_rejects)     AS rows_quarantined,
  (SELECT COUNT(*) FROM zepto)                           AS rows_analysed,
  (SELECT COUNT(*) FROM zepto_raw)
    - (SELECT COUNT(DISTINCT row_id) FROM zepto_rejects)
    - (SELECT COUNT(*) FROM zepto)                       AS rows_dropped_as_duplicate;


-- ---------------------------------------------------------------------------
-- 5) DATA EXPLORATION
-- ---------------------------------------------------------------------------

-- 5.1 Categories that survive deduplication
SELECT category, COUNT(*) AS sku_count
FROM zepto GROUP BY category ORDER BY sku_count DESC;

-- 5.2 Genuine multi-SKU products (same name, different pack size)
SELECT name, COUNT(*) AS pack_variants,
       STRING_AGG(weight_in_gms::text || 'g', ', ' ORDER BY weight_in_gms) AS packs
FROM zepto
GROUP BY name
HAVING COUNT(*) > 1
ORDER BY pack_variants DESC, name;

-- 5.3 Is the stated discount rounded or truncated?
--     If every row matches FLOOR, the field systematically understates.
SELECT
  COUNT(*)                                                                   AS priced_rows,
  COUNT(*) FILTER (WHERE discount_percent = FLOOR((mrp - discounted_selling_price) / mrp * 100)) AS matches_floor,
  COUNT(*) FILTER (WHERE discount_percent = ROUND((mrp - discounted_selling_price) / mrp * 100)) AS matches_round,
  ROUND(MAX(ABS(discount_percent - (mrp - discounted_selling_price) / mrp * 100)), 2) AS max_gap_pp
FROM zepto
WHERE mrp > 0;


-- ---------------------------------------------------------------------------
-- 6) BUSINESS INSIGHTS
-- ---------------------------------------------------------------------------

-- Q1. Availability risk by category — where is the operational problem?
SELECT
  category,
  COUNT(*)                                                     AS skus,
  COUNT(*) FILTER (WHERE out_of_stock)                         AS out_of_stock_skus,
  ROUND(100.0 * COUNT(*) FILTER (WHERE out_of_stock) / COUNT(*), 1) AS pct_out_of_stock,
  ROUND(SUM(mrp) FILTER (WHERE out_of_stock), 2)               AS unavailable_mrp_value
FROM zepto
GROUP BY category
ORDER BY pct_out_of_stock DESC;

-- Q2. Inventory value by category  (NOT revenue — no units-sold data exists)
SELECT
  category,
  ROUND(SUM(discounted_selling_price * available_quantity), 2) AS inventory_value_at_selling_price,
  ROUND(SUM(mrp * available_quantity), 2)                      AS inventory_value_at_mrp,
  ROUND(SUM((mrp - discounted_selling_price) * available_quantity), 2) AS margin_given_away
FROM zepto
GROUP BY category
ORDER BY inventory_value_at_selling_price DESC;

-- Q3. High-value products sitting out of stock
SELECT name, category, mrp, discount_percent
FROM zepto
WHERE out_of_stock AND mrp > 300
ORDER BY mrp DESC;

-- Q4. Premium products barely discounted — pricing power, or missed volume?
SELECT name, category, mrp, discount_percent, available_quantity
FROM zepto
WHERE mrp > 500 AND discount_percent < 10
ORDER BY mrp DESC;

-- Q5. Deepest average discount by category
SELECT category,
       ROUND(AVG(discount_percent), 2) AS avg_discount_pct,
       COUNT(*)                        AS skus
FROM zepto
GROUP BY category
ORDER BY avg_discount_pct DESC;

-- Q6. Best value per gram (packs of 100g and above)
SELECT name, category, weight_in_gms, discounted_selling_price,
       ROUND(discounted_selling_price / NULLIF(weight_in_gms, 0), 4) AS price_per_gram
FROM zepto
WHERE weight_in_gms >= 100
ORDER BY price_per_gram
LIMIT 25;

-- Q7. Pack-size mix and the warehouse weight it implies
SELECT
  CASE WHEN weight_in_gms < 1000 THEN 'Low (<1kg)'
       WHEN weight_in_gms < 5000 THEN 'Medium (1-5kg)'
       ELSE 'Bulk (5kg+)' END                              AS weight_band,
  COUNT(*)                                                 AS skus,
  ROUND(SUM(weight_in_gms * available_quantity) / 1000.0, 1) AS total_kg_on_hand
FROM zepto
GROUP BY weight_band
ORDER BY skus DESC;

-- Q8. Total inventory weight per category
SELECT category,
       ROUND(SUM(weight_in_gms * available_quantity) / 1000.0, 1) AS total_kg_on_hand
FROM zepto
GROUP BY category
ORDER BY total_kg_on_hand DESC;

-- Q9. Discount depth vs availability — are we discounting what we can't supply?
SELECT
  category,
  ROUND(AVG(discount_percent), 2) AS avg_discount_pct,
  ROUND(100.0 * COUNT(*) FILTER (WHERE out_of_stock) / COUNT(*), 1) AS pct_out_of_stock
FROM zepto
GROUP BY category
ORDER BY avg_discount_pct DESC;