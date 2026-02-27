/*
   ZEPTO INVENTORY - END TO END SQL (PostgreSQL)
   - Robust schema
   - Safe paise -> rupees conversion
   - Cleaning + business insights
*/

-- RESET
DROP TABLE IF EXISTS zepto CASCADE;
DROP TABLE IF EXISTS zepto_raw CASCADE;

-- 1) STAGING TABLE (RAW)
--    Keep paise as INT here to avoid conversion mistakes

CREATE TABLE zepto_raw (
  category                          TEXT,
  name                              TEXT,
  mrp_paise                         BIGINT,
  discount_percent                  NUMERIC(6,2),
  available_quantity                INT,
  discounted_selling_price_paise    BIGINT,
  weight_in_gms                     INT,
  out_of_stock                      BOOLEAN,
  quantity                          INT
);

/* LOAD DATA
COPY zepto_raw(category,name,mrp_paise,discount_percent,available_quantity,discounted_selling_price_paise,weight_in_gms,out_of_stock,quantity)
FROM 'C:\Users\YOURNAME\Downloads\zepto_v2.csv' (local path)
WITH (FORMAT csv, HEADER true);
*/

-- 2) FINAL TABLE (CLEAN / ANALYTICS)

CREATE TABLE zepto (
  sku_id                    SERIAL PRIMARY KEY,
  category                  TEXT NOT NULL,
  name                      TEXT NOT NULL,
  mrp                       NUMERIC(12,2) NOT NULL CHECK (mrp >= 0),
  discount_percent          NUMERIC(6,2)  NOT NULL CHECK (discount_percent >= 0 AND discount_percent <= 100),
  available_quantity        INT NOT NULL CHECK (available_quantity >= 0),
  discounted_selling_price  NUMERIC(12,2) NOT NULL CHECK (discounted_selling_price >= 0),
  weight_in_gms             INT NOT NULL CHECK (weight_in_gms >= 0),
  out_of_stock              BOOLEAN NOT NULL,
  quantity                  INT NOT NULL CHECK (quantity >= 0),
  CHECK (discounted_selling_price <= mrp OR mrp = 0)
);

-- 3) INSERT & BASIC STANDARDISATION
--    - trimming strings
--    - paise -> rupees

INSERT INTO zepto (
  category, name, mrp, discount_percent, available_quantity,
  discounted_selling_price, weight_in_gms, out_of_stock, quantity
)
SELECT
  NULLIF(TRIM(category), '') AS category,
  NULLIF(TRIM(name), '')     AS name,
  COALESCE(mrp_paise, 0) / 100.0 AS mrp,
  COALESCE(discount_percent, 0)  AS discount_percent,
  COALESCE(available_quantity, 0) AS available_quantity,
  COALESCE(discounted_selling_price_paise, 0) / 100.0 AS discounted_selling_price,
  COALESCE(weight_in_gms, 0) AS weight_in_gms,
  COALESCE(out_of_stock, FALSE) AS out_of_stock,
  COALESCE(quantity, 0) AS quantity
FROM zepto_raw
WHERE TRIM(COALESCE(name, '')) <> ''   -- reject blank names
  AND TRIM(COALESCE(category, '')) <> '';

-- 4) DATA EXPLORATION

-- 4.1 Count of rows
SELECT COUNT(*) AS total_rows
FROM zepto;

-- 4.2 Sample data
SELECT *
FROM zepto
ORDER BY sku_id
LIMIT 10;

-- 4.3 Check missing/invalid values (real-world checks)
SELECT *
FROM zepto
WHERE category IS NULL OR name IS NULL
   OR mrp IS NULL OR discounted_selling_price IS NULL
   OR discount_percent IS NULL
   OR available_quantity IS NULL
   OR weight_in_gms IS NULL
   OR out_of_stock IS NULL
   OR quantity IS NULL
   OR mrp < 0 OR discounted_selling_price < 0
   OR available_quantity < 0 OR weight_in_gms < 0 OR quantity < 0;

-- 4.4 Distinct categories
SELECT DISTINCT category
FROM zepto
ORDER BY category;

-- 4.5 In stock vs out of stock counts
SELECT out_of_stock, COUNT(*) AS sku_count
FROM zepto
GROUP BY out_of_stock
ORDER BY out_of_stock;

-- 4.6 Product names repeated (multiple SKUs)
SELECT name, COUNT(*) AS sku_count
FROM zepto
GROUP BY name
HAVING COUNT(*) > 1
ORDER BY sku_count DESC, name;


-- 5) DATA CLEANING 

-- 5.1 Identify suspicious rows (prices 0, weights 0, selling > mrp)
SELECT *
FROM zepto
WHERE mrp = 0
   OR discounted_selling_price = 0
   OR discounted_selling_price > mrp
   OR weight_in_gms = 0;

-- 5.2 Remove products where MRP is 0 
DELETE FROM zepto
WHERE mrp = 0;

-- 5.4 Ensure out_of_stock aligns with available_quantity
-- If out_of_stock is TRUE, available_quantity ideally should be 0.
SELECT *
FROM zepto
WHERE out_of_stock = TRUE AND available_quantity > 0;

-- 6) BUSINESS INSIGHTS 

/* Q1: Top 10 best-value products
 rank by TOTAL SAVINGS POTENTIAL = (mrp - dsp) * available_quantity
*/

SELECT
  name,
  category,
  mrp,
  discounted_selling_price,
  (mrp - discounted_selling_price) AS savings_per_unit,
  available_quantity,
  ROUND((mrp - discounted_selling_price) * available_quantity, 2) AS total_savings_potential
FROM zepto
WHERE mrp > 0
ORDER BY total_savings_potential DESC
LIMIT 10;

/* Q2: High MRP products that are out of stock
*/
SELECT
  name,
  category,
  mrp
FROM zepto
WHERE out_of_stock = TRUE
  AND mrp > 300
ORDER BY mrp DESC
LIMIT 50;

/* Q3: Estimated revenue per category
   Using DESC order.
*/
SELECT
  category,
  ROUND(SUM(discounted_selling_price * available_quantity), 2) AS total_revenue
FROM zepto
GROUP BY category
ORDER BY total_revenue DESC;

/* Q4: Products where MRP > 500 and discount < 10% */
SELECT
  name,
  category,
  mrp,
  discount_percent
FROM zepto
WHERE mrp > 500
  AND discount_percent < 10
ORDER BY mrp DESC, discount_percent ASC;

/* Q5: Top 5 categories with highest average discount */
SELECT
  category,
  ROUND(AVG(discount_percent), 2) AS avg_discount_percent
FROM zepto
GROUP BY category
ORDER BY avg_discount_percent DESC
LIMIT 5;

/* Q6: Price per gram for products >= 100g */
SELECT
  name,
  category,
  weight_in_gms,
  discounted_selling_price,
  ROUND(discounted_selling_price / NULLIF(weight_in_gms, 0), 4) AS price_per_gram
FROM zepto
WHERE weight_in_gms >= 100
  AND weight_in_gms > 0
ORDER BY price_per_gram ASC;

/* Q7: Group products into Low / Medium / Bulk by weight */
SELECT
  name,
  category,
  weight_in_gms,
  CASE
    WHEN weight_in_gms < 1000 THEN 'Low'
    WHEN weight_in_gms < 5000 THEN 'Medium'
    ELSE 'Bulk'
  END AS weight_category
FROM zepto
ORDER BY weight_in_gms ASC;

/* Q8: Total inventory weight per category */
SELECT
  category,
  SUM(weight_in_gms * available_quantity) AS total_inventory_weight_gms
FROM zepto
GROUP BY category
ORDER BY total_inventory_weight_gms DESC;



-- B1) Top categories by number of SKUs
SELECT category, COUNT(*) AS sku_count
FROM zepto
GROUP BY category
ORDER BY sku_count DESC;

-- B2) Compute discount from prices & compare to provided discount_percent (data quality check)
SELECT
  name, category, mrp, discounted_selling_price, discount_percent,
  ROUND(((mrp - discounted_selling_price) / NULLIF(mrp,0)) * 100, 2) AS computed_discount_percent,
  ROUND(ABS(discount_percent - (((mrp - discounted_selling_price) / NULLIF(mrp,0)) * 100)), 2) AS diff_pct
FROM zepto
WHERE mrp > 0
ORDER BY diff_pct DESC
LIMIT 25;