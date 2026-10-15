/*==============================================================================
  05 - BUILD THE STAR SCHEMA  (stg.SalesRaw -> dim.* -> fact.FactSales)
  ------------------------------------------------------------------------------
  Order matters: dimensions first, fact last (the fact table needs the keys).

      stg.SalesRaw --> DimCountry, DimProduct, DimCustomer, DimDate
                   --> FactSales  (looks up each key; missing match -> key 0)

  Safe to re-run: dimension inserts skip rows that already exist and the fact
  table is emptied before it is reloaded.
==============================================================================*/

USE RetailIntelligence;
GO

/*------------------------------------------------------------------------------
  1) DIMENSIONS
------------------------------------------------------------------------------*/

-- Countries (trimmed; the 'Unknown' member with key 0 already exists)
INSERT INTO dim.DimCountry (CountryName)
SELECT DISTINCT LTRIM(RTRIM(s.Country))
FROM stg.SalesRaw s
WHERE NULLIF(LTRIM(RTRIM(s.Country)), '') IS NOT NULL
  AND LTRIM(RTRIM(s.Country)) <> 'Unknown'
  AND NOT EXISTS (SELECT 1 FROM dim.DimCountry c
                  WHERE c.CountryName = LTRIM(RTRIM(s.Country)));
GO

-- Products (one row per StockCode; MAX() picks one description when a code
-- has several - see data-quality block 6.1)
INSERT INTO dim.DimProduct (StockCode, Description)
SELECT s.StockCode, MAX(s.Description)
FROM stg.SalesRaw s
WHERE s.StockCode IS NOT NULL
  AND LTRIM(RTRIM(s.StockCode)) <> ''
  AND NOT EXISTS (SELECT 1 FROM dim.DimProduct p WHERE p.StockCode = s.StockCode)
GROUP BY s.StockCode;
GO

-- Customers (rows without a CustomerID are covered by the 'Unknown' member)
INSERT INTO dim.DimCustomer (CustomerID)
SELECT DISTINCT s.CustomerID
FROM stg.SalesRaw s
WHERE s.CustomerID IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dim.DimCustomer c WHERE c.CustomerID = s.CustomerID);
GO

-- Dates: one row per day that has transactions.
--   DateKey   : yyyymmdd as an integer
--   IsWeekend : Saturday/Sunday, computed from the distance to a known Saturday
--               (1900-01-06) so it does not depend on the server's language/DATEFIRST.
INSERT INTO dim.DimDate
    (DateKey, FullDate, YearNumber, QuarterNumber, MonthNumber, MonthName,
     DayNumber, DayOfWeek, DayName, IsWeekend)
SELECT
    YEAR(x.D) * 10000 + MONTH(x.D) * 100 + DAY(x.D),
    x.D,
    YEAR(x.D),
    DATEPART(QUARTER, x.D),
    MONTH(x.D),
    DATENAME(MONTH, x.D),
    DAY(x.D),
    DATEPART(WEEKDAY, x.D),
    DATENAME(WEEKDAY, x.D),
    CASE WHEN DATEDIFF(DAY, '19000106', x.D) % 7 IN (0, 1) THEN 1 ELSE 0 END
FROM
(
    SELECT DISTINCT CAST(InvoiceDate AS DATE) AS D
    FROM stg.SalesRaw
    WHERE InvoiceDate IS NOT NULL
) x
WHERE NOT EXISTS (SELECT 1 FROM dim.DimDate d WHERE d.FullDate = x.D);
GO

/*------------------------------------------------------------------------------
  2) FACT TABLE
     Every key is looked up with a LEFT JOIN; if nothing matches, ISNULL(...,0)
     points the row to the 'Unknown' member so no transaction is lost.
     Rows are kept even when they are cancellations (IsCancellation = 1).
------------------------------------------------------------------------------*/

TRUNCATE TABLE fact.FactSales;
GO

INSERT INTO fact.FactSales
    (InvoiceNo, ProductKey, CustomerKey, DateKey, CountryKey,
     Quantity, UnitPrice, IsCancellation)
SELECT
    s.InvoiceNo,
    ISNULL(p.ProductKey,  0),
    ISNULL(c.CustomerKey, 0),
    ISNULL(d.DateKey,     0),
    ISNULL(co.CountryKey, 0),
    s.Quantity,
    s.UnitPrice,
    CASE WHEN s.InvoiceNo LIKE 'C%' THEN 1 ELSE 0 END
FROM stg.SalesRaw s
LEFT JOIN dim.DimProduct  p  ON s.StockCode               = p.StockCode
LEFT JOIN dim.DimCustomer c  ON s.CustomerID              = c.CustomerID
LEFT JOIN dim.DimDate     d  ON CAST(s.InvoiceDate AS DATE) = d.FullDate
LEFT JOIN dim.DimCountry  co ON LTRIM(RTRIM(s.Country))   = co.CountryName
WHERE s.InvoiceNo IS NOT NULL
  AND s.Quantity  IS NOT NULL
  AND s.UnitPrice IS NOT NULL;
GO

/*------------------------------------------------------------------------------
  3) LOAD CHECKS
------------------------------------------------------------------------------*/

SELECT
    (SELECT COUNT(*) FROM fact.FactSales)  AS FactRows,
    (SELECT COUNT(*) FROM dim.DimCustomer) AS Customers,   -- includes Unknown (key 0)
    (SELECT COUNT(*) FROM dim.DimProduct)  AS Products,    -- includes Unknown
    (SELECT COUNT(*) FROM dim.DimCountry)  AS Countries,   -- includes Unknown
    (SELECT COUNT(*) FROM dim.DimDate)     AS Dates;       -- includes Unknown

-- How many fact rows fell back to an "Unknown" member?
SELECT
    SUM(CASE WHEN CustomerKey = 0 THEN 1 ELSE 0 END) AS UnknownCustomerRows,   -- expected: many (guest orders)
    SUM(CASE WHEN ProductKey  = 0 THEN 1 ELSE 0 END) AS UnknownProductRows,    -- expected: 0
    SUM(CASE WHEN CountryKey  = 0 THEN 1 ELSE 0 END) AS UnknownCountryRows,    -- expected: 0
    SUM(CASE WHEN DateKey     = 0 THEN 1 ELSE 0 END) AS UnknownDateRows        -- expected: 0
FROM fact.FactSales;
GO
