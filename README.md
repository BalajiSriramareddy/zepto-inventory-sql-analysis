# Zepto Inventory Analysis — PostgreSQL

**The standard data-quality checks flagged 4 bad rows out of 3,732. A structural check flagged 1,931.**

This project analyses Zepto's public inventory dataset in PostgreSQL. The headline finding is not a business insight — it is that **52% of the dataset is duplicated**, in a way that no null check, range check or constraint would ever catch, and that inflates every category-level number by up to 112%.

---

## The finding

Standard cleaning found almost nothing:

| Check | Rows failing |
|---|---:|
| Blank name or category | 0 |
| MRP = 0 | 1 |
| Selling price = 0 | 1 |
| Selling price > MRP | 0 |
| Weight = 0 | 2 |
| Flagged out-of-stock but stock present | 0 |
| Stated discount % disagrees with price maths by >1pp | 0 |
| **Total** | **4 distinct rows** |

By every conventional measure this is a clean dataset.

Then I compared SKU counts by category:

| Category | SKUs | Inventory value |
|---|---:|---:|
| Cooking Essentials | 514 | ₹337,369 |
| Munchies | 514 | ₹337,369 |
| Personal Care | 344 | ₹270,849 |
| Paan Corner | 344 | ₹270,849 |
| Packaged Food | 388 | ₹224,385 |
| Ice Cream & Desserts | 388 | ₹224,385 |
| Chocolates & Candies | 388 | ₹224,385 |

Identical to the rupee. These are not similar categories — they are **the same rows, stored twice under different labels**.

Verified position-for-position:

| Block A | Block B | Rows identical in sequence |
|---|---|---:|
| Cooking Essentials | Munchies | 514 / 514 |
| Personal Care | Paan Corner | 344 / 344 |
| Packaged Food | Ice Cream & Desserts | 388 / 388 |
| Packaged Food | Chocolates & Candies | 388 / 388 |
| Dairy, Bread & Batter | Beverages | 129 / 129 |

The CSV stores categories in contiguous blocks, and five of those blocks are byte-for-byte copies of an earlier block. The semantics confirm which label is correct: *Gowardhan Fresh Paneer* appears under **Dairy** and again under **Beverages**; *Old Spice After Shave* appears under **Personal Care** and again under **Paan Corner**. In every pair the first block carries the plausible label.

### Impact on the reported numbers

| Metric | Before dedup | After dedup | Error |
|---|---:|---:|---|
| Product records | 3,732 | 1,801 | +107% |
| Categories | 14 | 9 | 5 phantom |
| Total inventory value | ₹2,243,081 | ₹1,058,454 | **+112%** |
| SKUs >₹300 out of stock | 8 | 4 | +100% |
| Products >₹500 with <10% discount | 82 | 39 | +110% |
| Top-5 categories by avg discount | — | — | **3 of 5 were phantoms** |

Every duplicated row was individually valid. Row-level validation cannot detect a dataset-shape problem.

---

## Corrected business insights

### Availability is the real operational story

| Category | SKUs | Out of stock | % OOS |
|---|---:|---:|---:|
| Biscuits | 147 | 42 | **28.6%** |
| Dairy, Bread & Batter | 113 | 27 | **23.9%** |
| Meats, Fish & Eggs | 32 | 7 | 21.9% |
| Cooking Essentials | 514 | 64 | 12.5% |
| Home & Cleaning | 194 | 19 | 9.8% |
| Packaged Food | 303 | 27 | 8.9% |
| Fruits & Vegetables | 93 | 6 | 6.5% |
| Health & Hygiene | 62 | 4 | 6.5% |
| Personal Care | 343 | 21 | 6.1% |

Catalogue average is 12.0%. Biscuits runs at nearly five times Personal Care's rate — a fast-moving, low-value category with a replenishment problem, not a pricing one. Worth checking whether that's demand forecasting or supplier lead time before touching price.

### Inventory value concentrates in two categories

| Category | Inventory value | Share |
|---|---:|---:|
| Cooking Essentials | ₹337,369 | 31.9% |
| Personal Care | ₹270,039 | 25.5% |
| Packaged Food | ₹192,427 | 18.2% |
| Home & Cleaning | ₹122,661 | 11.6% |
| Dairy, Bread & Batter | ₹46,695 | 4.4% |
| Health & Hygiene | ₹43,707 | 4.1% |
| Biscuits | ₹25,008 | 2.4% |
| Fruits & Vegetables | ₹10,846 | 1.0% |
| Meats, Fish & Eggs | ₹9,702 | 0.9% |

**Note on terminology:** this is *inventory value at current selling price*, not revenue. The dataset has no units-sold column, so revenue cannot be derived from it. Labelling it "estimated revenue" — as the common version of this project does — silently converts a stock measure into a sales measure.

### Discounting

Catalogue-wide average discount is 7.62%. Fruits & Vegetables discounts hardest at 15.5%, roughly double, which is consistent with perishability rather than promotion strategy. Total margin given away across on-hand stock is ₹115,512 against ₹1,173,966 of MRP value — about 9.8%.

### The discount field is truncated, not rounded

All 1,800 priced rows satisfy `discount_percent = FLOOR((mrp - dsp) / mrp * 100)`. None match `ROUND`. Maximum gap is 0.99 percentage points.

This is why a naive "does the stated discount match the maths" check returns zero rows at a 1pp tolerance and looks like a pass. It isn't a pass — it's a systematic understatement of every discount in the catalogue by up to a full percentage point. Any report built on `discount_percent` rather than recomputing from prices will be quietly low.

### Only 4 high-value SKUs are unavailable

| Product | Category | MRP |
|---|---|---:|
| Patanjali Cow's Ghee | Cooking Essentials | ₹565 |
| MamyPoko Pants Standard, XL | Personal Care | ₹399 |
| Aashirvaad Atta with Multigrains | Cooking Essentials | ₹315 |
| Everest Kashmiri Lal Chilli Powder | Cooking Essentials | ₹310 |

Small enough to act on individually — which is the point of getting the number right. Eight would have looked like a pattern; four is a shortlist.

---

## How it's built

```
zepto_raw       staging — loaded verbatim, money still in paise
zepto_rejects   quarantined rows + reject_reason
zepto           analytics — deduplicated, paise converted once
```

Three decisions that differ from the usual approach to this dataset:

**1. Rows are quarantined, not deleted.** `DELETE FROM zepto WHERE mrp = 0` destroys the evidence before you've counted it. Rejected rows go to `zepto_rejects` with a reason, so "how many rows failed and why" is a query, not a memory.

**2. The analytics table carries no CHECK constraints that duplicate the quarantine rules.** A `CHECK (discounted_selling_price <= mrp)` guarantees the matching diagnostic query returns zero rows — it becomes dead code that looks like a passing test. Worse, if the raw data *does* violate it, the entire INSERT aborts and you get no table at all. Validation belongs in the quarantine step, where it produces a number.

**3. Prices stay in paise until exactly one conversion point.** The common version of this project runs `UPDATE zepto SET mrp = mrp/100.0` as a separate step, which silently divides by 100 again every time it's re-run. Converting inside the single INSERT makes double-conversion impossible.

**4. The natural key is `name + weight + pack quantity`, not `name`.** Grouping on name alone reports 1,211 "duplicate" products, most of which are legitimately different pack sizes. The real figure is 111 products with multiple pack variants.

## Running it

```bash
psql -d yourdb -f zepto_inventory_analysis.sql
```

Update the `COPY` path in section 1 first. The CSV is UTF-8 with a BOM, so `ENCODING 'UTF8'` matters.

## Dataset

[Zepto Inventory Dataset](https://www.kaggle.com/datasets/palvinder2006/zepto-inventory-dataset) (Kaggle) — `zepto_v2.csv`, 3,732 rows.

## Stack

PostgreSQL · pgAdmin

---

**Balaji Manjulamma Sriramareddy**
