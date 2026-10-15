/*==============================================================================
  04 - DATA QUALITY CHECKS  (read-only exploration of stg.SalesRaw)
  ------------------------------------------------------------------------------
  Nothing in this file changes data. Each block asks one question about the raw
  data; the answers drive the cleaning rules implemented in
  06_clean_and_analytics_views.sql.

  Run the blocks one by one (highlight a block and press F5) and read the result.

    Block 1  Size, coverage and missing values
    Block 2  Cancellations
    Block 3  Quantity and price anomalies
    Block 4  Exact duplicate rows
    Block 5  Non-product stock codes (postage, fees, adjustments ...)
    Block 6  Consistency of products and invoices
==============================================================================*/

USE RetailIntelligence;
GO

/*==============================================================================
  BLOCK 1 - Size, coverage and missing values
==============================================================================*/

-- 1.1 How many rows, and how many are missing each column?
--     Expect: many NULL CustomerID (guest orders) and some NULL Description.
SELECT
    COUNT(*)                                                 AS TotalRows,
    SUM(CASE WHEN InvoiceNo   IS NULL THEN 1 ELSE 0 END)     AS MissingInvoiceNo,
    SUM(CASE WHEN StockCode   IS NULL THEN 1 ELSE 0 END)     AS MissingStockCode,
    SUM(CASE WHEN Description IS NULL THEN 1 ELSE 0 END)     AS MissingDescription,
    SUM(CASE WHEN Quantity    IS NULL THEN 1 ELSE 0 END)     AS MissingQuantity,
    SUM(CASE WHEN InvoiceDate IS NULL THEN 1 ELSE 0 END)     AS MissingInvoiceDate,
    SUM(CASE WHEN UnitPrice   IS NULL THEN 1 ELSE 0 END)     AS MissingUnitPrice,
    SUM(CASE WHEN CustomerID  IS NULL THEN 1 ELSE 0 END)     AS MissingCustomerID,
    SUM(CASE WHEN Country     IS NULL THEN 1 ELSE 0 END)     AS MissingCountry
FROM stg.SalesRaw;

-- 1.2 Time coverage and the number of distinct products / customers.
SELECT
    MIN(InvoiceDate)             AS FirstTransaction,
    MAX(InvoiceDate)             AS LastTransaction,
    COUNT(DISTINCT StockCode)    AS UniqueProducts,
    COUNT(DISTINCT CustomerID)   AS UniqueCustomers      -- NULLs are not counted
FROM stg.SalesRaw;

-- 1.3 Where do the transactions come from?
SELECT Country, COUNT(*) AS TransactionLines
FROM stg.SalesRaw
GROUP BY Country
ORDER BY TransactionLines DESC;


/*==============================================================================
  BLOCK 2 - Cancellations
  Invoice numbers starting with 'C' are cancellations / returns.
==============================================================================*/

-- 2.1 How many cancellation lines are there?
SELECT COUNT(*) AS CancellationRows
FROM stg.SalesRaw
WHERE InvoiceNo LIKE 'C%';

-- 2.2 A few examples (they should have negative quantities).
SELECT TOP 20
    InvoiceNo, StockCode, Quantity, UnitPrice, CustomerID, Country
FROM stg.SalesRaw
WHERE InvoiceNo LIKE 'C%';


/*==============================================================================
  BLOCK 3 - Quantity and price anomalies
==============================================================================*/

-- 3.1 Range of quantity and price.
SELECT
    MIN(Quantity)  AS MinQuantity,  MAX(Quantity)  AS MaxQuantity,
    MIN(UnitPrice) AS MinUnitPrice, MAX(UnitPrice) AS MaxUnitPrice
FROM stg.SalesRaw;

-- 3.2 Cross-check: invoice type x quantity sign x price sign.
--     This single table replaces many separate checks. Look for combinations
--     that are NOT "normal sale" (positive qty, positive price) or
--     "cancellation" (C invoice, negative qty, positive price).
SELECT
    CASE WHEN InvoiceNo LIKE 'C%' THEN 'Cancellation invoice' ELSE 'Normal invoice' END AS InvoiceType,
    CASE WHEN Quantity  < 0 THEN 'Negative qty'   WHEN Quantity  = 0 THEN 'Zero qty'   ELSE 'Positive qty'   END AS QuantityType,
    CASE WHEN UnitPrice < 0 THEN 'Negative price' WHEN UnitPrice = 0 THEN 'Zero price' ELSE 'Positive price' END AS PriceType,
    COUNT(*)                    AS RowsCount,
    SUM(Quantity)               AS TotalQuantity
FROM stg.SalesRaw
GROUP BY
    CASE WHEN InvoiceNo LIKE 'C%' THEN 'Cancellation invoice' ELSE 'Normal invoice' END,
    CASE WHEN Quantity  < 0 THEN 'Negative qty'   WHEN Quantity  = 0 THEN 'Zero qty'   ELSE 'Positive qty'   END,
    CASE WHEN UnitPrice < 0 THEN 'Negative price' WHEN UnitPrice = 0 THEN 'Zero price' ELSE 'Positive price' END
ORDER BY InvoiceType, QuantityType, PriceType;

-- 3.3 Negative quantity on a NON-cancellation invoice: usually stock write-offs
--     (damaged / lost / "found" items) rather than customer sales.
SELECT TOP 50
    InvoiceNo, StockCode, Description, Quantity, InvoiceDate, UnitPrice, CustomerID
FROM stg.SalesRaw
WHERE Quantity < 0
  AND InvoiceNo NOT LIKE 'C%'
ORDER BY InvoiceDate;

-- 3.4 Negative prices (accounting corrections such as "Adjust bad debt").
SELECT RawID, InvoiceNo, StockCode, Description, Quantity, UnitPrice, InvoiceDate
FROM stg.SalesRaw
WHERE UnitPrice < 0
ORDER BY UnitPrice;

-- 3.5 Zero-price rows: which products are involved? (free samples, stock
--     adjustments, data-entry leftovers ...)
SELECT TOP 50
    StockCode, Description,
    COUNT(*)      AS ZeroPriceRows,
    SUM(Quantity) AS TotalQuantity
FROM stg.SalesRaw
WHERE UnitPrice = 0
GROUP BY StockCode, Description
ORDER BY ZeroPriceRows DESC;

-- 3.6 Missing Description: what kind of rows are they?
SELECT
    CASE WHEN UnitPrice = 0 THEN 'Zero price' WHEN UnitPrice > 0 THEN 'Positive price' ELSE 'Negative price' END AS PriceType,
    CASE WHEN Quantity  < 0 THEN 'Negative qty' WHEN Quantity  > 0 THEN 'Positive qty' ELSE 'Zero qty' END       AS QuantityType,
    COUNT(*) AS RowsCount
FROM stg.SalesRaw
WHERE Description IS NULL
GROUP BY
    CASE WHEN UnitPrice = 0 THEN 'Zero price' WHEN UnitPrice > 0 THEN 'Positive price' ELSE 'Negative price' END,
    CASE WHEN Quantity  < 0 THEN 'Negative qty' WHEN Quantity  > 0 THEN 'Positive qty' ELSE 'Zero qty' END
ORDER BY RowsCount DESC;


/*==============================================================================
  BLOCK 4 - Exact duplicate rows
  Two rows are "exact duplicates" when ALL business columns are identical.
  (DupCount is used instead of "RowCount" because ROWCOUNT is a reserved word.)
==============================================================================*/

-- 4.1 How big is the duplicate problem?
WITH DuplicateGroups AS
(
    SELECT
        InvoiceNo, StockCode, Description, Quantity,
        InvoiceDate, UnitPrice, CustomerID, Country,
        COUNT(*) AS DupCount
    FROM stg.SalesRaw
    GROUP BY
        InvoiceNo, StockCode, Description, Quantity,
        InvoiceDate, UnitPrice, CustomerID, Country
    HAVING COUNT(*) > 1
)
SELECT
    COUNT(*)            AS DuplicateGroups,         -- how many different duplicated lines
    SUM(DupCount)       AS RowsInDuplicateGroups,   -- all rows involved
    SUM(DupCount - 1)   AS ExtraRows                -- rows that would be removed
FROM DuplicateGroups;

-- 4.2 Are duplicates concentrated in particular months? (e.g. a double import)
WITH DuplicateGroups AS
(
    SELECT
        YEAR(InvoiceDate) AS SalesYear, MONTH(InvoiceDate) AS SalesMonth,
        InvoiceNo, StockCode, Description, Quantity,
        InvoiceDate, UnitPrice, CustomerID, Country,
        COUNT(*) AS DupCount
    FROM stg.SalesRaw
    GROUP BY
        YEAR(InvoiceDate), MONTH(InvoiceDate),
        InvoiceNo, StockCode, Description, Quantity,
        InvoiceDate, UnitPrice, CustomerID, Country
    HAVING COUNT(*) > 1
)
SELECT
    SalesYear, SalesMonth,
    COUNT(*)          AS DuplicateGroups,
    SUM(DupCount - 1) AS ExtraRows
FROM DuplicateGroups
GROUP BY SalesYear, SalesMonth
ORDER BY SalesYear, SalesMonth;

-- 4.3 Same line repeated with different timestamps? (would point to a
--     re-submitted order instead of a pure duplicate)
SELECT
    InvoiceNo, StockCode, Quantity, UnitPrice, CustomerID,
    COUNT(*)                     AS DupCount,
    MIN(InvoiceDate)             AS FirstInvoiceDate,
    MAX(InvoiceDate)             AS LastInvoiceDate
FROM stg.SalesRaw
GROUP BY InvoiceNo, StockCode, Description, Quantity, UnitPrice, CustomerID, Country
HAVING COUNT(*) > 1
   AND COUNT(DISTINCT InvoiceDate) > 1
ORDER BY InvoiceNo, StockCode;


/*==============================================================================
  BLOCK 5 - Non-product stock codes
  Some "products" are really services, fees or accounting entries. They must be
  separated from genuine product sales or they distort revenue and demand.
==============================================================================*/

-- 5.1 Hunt for non-product codes by looking at their descriptions.
SELECT StockCode, Description, COUNT(*) AS RowsCount
FROM stg.SalesRaw
WHERE LOWER(Description) LIKE '%postage%'
   OR LOWER(Description) LIKE '%manual%'
   OR LOWER(Description) LIKE '%adjust%'
   OR LOWER(Description) LIKE '%amazon%'
   OR LOWER(Description) LIKE '%bank charge%'
   OR LOWER(Description) LIKE '%fee%'
GROUP BY StockCode, Description
ORDER BY StockCode, RowsCount DESC;

-- 5.2 Profile the suspicious codes found above.
SELECT
    StockCode, Description,
    COUNT(*)                   AS RowsCount,
    SUM(Quantity)              AS TotalQuantity,
    MIN(UnitPrice)             AS MinPrice,
    MAX(UnitPrice)             AS MaxPrice,
    COUNT(DISTINCT InvoiceNo)  AS UniqueInvoices,
    COUNT(DISTINCT CustomerID) AS UniqueCustomers
FROM stg.SalesRaw
WHERE StockCode LIKE 'gift_%'
   OR StockCode LIKE 'DCGS%'
   OR StockCode IN ('AMAZONFEE', 'BANK CHARGES', 'CRUK', 'C2', 'D', 'S',
                    'ADJUST', 'ADJUST2', 'M', 'POST', 'DOT', 'B')
GROUP BY StockCode, Description
ORDER BY StockCode, RowsCount DESC;

-- 5.3 Missing CustomerID: do these rows hide non-sales (adjustments, write-offs)?
SELECT
    CASE
        WHEN InvoiceNo LIKE 'C%' AND Quantity < 0 AND UnitPrice > 0 THEN 'Cancellation / Return'
        WHEN Description = 'Adjust bad debt' AND UnitPrice < 0       THEN 'Accounting Adjustment'
        WHEN Quantity < 0 AND UnitPrice = 0                          THEN 'Inventory Adjustment'
        WHEN UnitPrice = 0 AND Quantity > 0                          THEN 'Zero-Price Special Transaction'
        ELSE 'Potential Normal Sale'
    END                  AS TransactionType,
    COUNT(*)             AS RowsCount,
    SUM(Quantity)        AS TotalQuantity,
    SUM(Quantity * UnitPrice) AS TotalRevenue
FROM stg.SalesRaw
WHERE CustomerID IS NULL
GROUP BY
    CASE
        WHEN InvoiceNo LIKE 'C%' AND Quantity < 0 AND UnitPrice > 0 THEN 'Cancellation / Return'
        WHEN Description = 'Adjust bad debt' AND UnitPrice < 0       THEN 'Accounting Adjustment'
        WHEN Quantity < 0 AND UnitPrice = 0                          THEN 'Inventory Adjustment'
        WHEN UnitPrice = 0 AND Quantity > 0                          THEN 'Zero-Price Special Transaction'
        ELSE 'Potential Normal Sale'
    END
ORDER BY RowsCount DESC;


/*==============================================================================
  BLOCK 6 - Consistency of products and invoices
==============================================================================*/

-- 6.1 Does one StockCode carry several different descriptions?
--     (Explains why dim.DimProduct keeps one description per code.)
SELECT TOP 50
    StockCode,
    COUNT(DISTINCT Description) AS DistinctDescriptions,
    COUNT(*)                    AS RowsCount
FROM stg.SalesRaw
WHERE Description IS NOT NULL
GROUP BY StockCode
HAVING COUNT(DISTINCT Description) > 1
ORDER BY DistinctDescriptions DESC, RowsCount DESC;

-- 6.2 Does the price of a normal product change a lot over time?
SELECT TOP 100
    StockCode,
    COUNT(DISTINCT UnitPrice) AS DistinctPrices,
    MIN(UnitPrice)            AS MinPrice,
    MAX(UnitPrice)            AS MaxPrice,
    COUNT(*)                  AS RowsCount
FROM stg.SalesRaw
WHERE UnitPrice > 0 AND Quantity > 0
GROUP BY StockCode
HAVING COUNT(DISTINCT UnitPrice) > 1
ORDER BY DistinctPrices DESC, RowsCount DESC;

-- 6.3 Does one invoice ever belong to more than one customer? (should be 0 rows)
SELECT InvoiceNo, COUNT(DISTINCT CustomerID) AS DistinctCustomers
FROM stg.SalesRaw
WHERE CustomerID IS NOT NULL
GROUP BY InvoiceNo
HAVING COUNT(DISTINCT CustomerID) > 1;

-- 6.4 Does one invoice span several calendar days? (should be 0 rows)
SELECT InvoiceNo,
       COUNT(DISTINCT CAST(InvoiceDate AS DATE)) AS DistinctDays
FROM stg.SalesRaw
GROUP BY InvoiceNo
HAVING COUNT(DISTINCT CAST(InvoiceDate AS DATE)) > 1;
GO
