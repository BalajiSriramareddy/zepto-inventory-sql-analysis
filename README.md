# zepto-inventory-sql-analysis
A PostgreSQL SQL project that loads Zepto inventory data from a raw CSV into a clean analytics table, performs data cleaning/validation, and answers key business questions on discounts, stock availability, estimated revenue by category, and inventory weight.

````md
# Zepto Inventory SQL Analysis (PostgreSQL)

A SQL portfolio project using PostgreSQL to load Zepto inventory data from a raw CSV into a clean analytics table, run data cleaning/validation checks, and generate business insights on discounts, stock availability, estimated revenue by category, and inventory weight.

## Dataset
- Source: Zepto Inventory Dataset (Kaggle)
- File: `zepto_v2.csv`
- Link: https://www.kaggle.com/datasets/palvinder2006/zepto-inventory-dataset?resource=download&select=zepto_v2.csv

## Tech Stack
- PostgreSQL
- SQL
- pgAdmin / psql (any SQL client)

## How to Run
1) Run your schema script to create `zepto_raw` and `zepto`.
2) Load CSV into `zepto_raw` (update the path):
```sql
COPY zepto_raw(category,name,mrp_paise,discount_percent,available_quantity,discounted_selling_price_paise,weight_in_gms,out_of_stock,quantity)
FROM 'C:\Users\YOURNAME\Downloads\zepto_v2.csv'
WITH (FORMAT csv, HEADER true);

3) Run the insert step to populate `zepto` (clean table).
4) Execute exploration, cleaning, and business insight queries.

## Questions Covered

### Data Exploration

* How many total rows are in the dataset?
* What does a sample of the data look like?
* Are there missing or invalid values in key columns?
* What are the distinct categories?
* How many SKUs are in stock vs out of stock?
* Which product names appear multiple times (duplicate names across SKUs)?

### Data Cleaning & Validation

* Which rows are suspicious (MRP=0, selling=0, selling>MRP, weight=0)?
* Remove products where MRP=0
* Check inconsistencies where out_of_stock=TRUE but available_quantity>0
* Compare provided discount_percent vs computed discount from prices

### Business Insights

* Top 10 best-value products by total savings potential: (MRP − discounted price) × available quantity
* High MRP products that are out of stock (MRP > ₹300)
* Estimated revenue per category: discounted price × available quantity
* Products with MRP > ₹500 and discount < 10%
* Top 5 categories with highest average discount %
* Best value products by price per gram (>= 100g)
* Bucket products into Low / Medium / Bulk by weight
* Total inventory weight per category
* Top categories by number of SKUs

## Notes

* Paise → Rupees conversion is handled during insert into the clean table to avoid double conversion.
* Price-per-gram uses NULLIF to prevent divide-by-zero errors.

## Author

Balaji
````

```
```
