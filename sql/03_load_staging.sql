/*==============================================================================
  03 - LOAD STAGING
  ------------------------------------------------------------------------------
  Loads the Online Retail II data in two safe steps:

      CSV file  --BULK INSERT-->  stg.SalesRaw_Text  --typed INSERT-->  stg.SalesRaw
                                  (everything is text)                  (correct types)

  Why two steps?  Loading straight into typed columns fails the whole load on a
  single bad value. Landing as text first lets us convert with TRY_CAST, which
  turns an unconvertible value into NULL so we can count and inspect it.

  BEFORE RUNNING
    1. Create the CSV with  scripts/excel_to_csv.py  (do NOT "Save As CSV" from
       Excel - it saves dates as displayed on screen and can corrupt them).
    2. Put the CSV where the SQL Server service account can read it, for
       example  C:\Data\online_retail_II.csv  and update the path below.

  Safe to re-run: both staging tables are emptied first.
==============================================================================*/

USE RetailIntelligence;
GO

-- Start from a clean slate so a re-run never duplicates rows.
TRUNCATE TABLE stg.SalesRaw_Text;
TRUNCATE TABLE stg.SalesRaw;
GO

/*------------------------------------------------------------------------------
  Step 1 - CSV -> text staging table
------------------------------------------------------------------------------*/
BULK INSERT stg.SalesRaw_Text
FROM 'C:\Data\online_retail_II.csv'        -- <-- change to your file location
WITH
(
    FORMAT          = 'CSV',
    FIRSTROW        = 2,                   -- skip the header row
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '0x0a',
    CODEPAGE        = '65001',             -- UTF-8
    TABLOCK
);
GO

/*------------------------------------------------------------------------------
  Step 2 - text -> typed staging table
    NULLIF(x, '')  : empty string becomes NULL
    TRY_CAST       : bad value becomes NULL instead of an error
    CustomerID     : Excel stores it like 12347.0, so go DECIMAL -> INT
------------------------------------------------------------------------------*/
INSERT INTO stg.SalesRaw
    (InvoiceNo, StockCode, Description, Quantity, InvoiceDate, UnitPrice, CustomerID, Country)
SELECT
    NULLIF(InvoiceNo, ''),
    NULLIF(StockCode, ''),
    NULLIF(Description, ''),
    TRY_CAST(Quantity    AS INT),
    TRY_CAST(InvoiceDate AS DATETIME2(0)),
    TRY_CAST(UnitPrice   AS DECIMAL(19,4)),
    TRY_CAST(TRY_CAST(NULLIF(CustomerID, '') AS DECIMAL(18,2)) AS INT),
    NULLIF(Country, '')
FROM stg.SalesRaw_Text;
GO

/*------------------------------------------------------------------------------
  Load check
    1) Both tables must have the same number of rows (~1,067,371 expected).
    2) Date / Quantity / Price must have 0 NULLs; CustomerID is expected to have
       many NULLs (guest checkouts) - that is a property of the data.
------------------------------------------------------------------------------*/
SELECT
    (SELECT COUNT(*) FROM stg.SalesRaw_Text) AS TextRows,
    (SELECT COUNT(*) FROM stg.SalesRaw)      AS TypedRows;

SELECT
    SUM(CASE WHEN InvoiceDate IS NULL THEN 1 ELSE 0 END) AS NullDates,
    SUM(CASE WHEN Quantity    IS NULL THEN 1 ELSE 0 END) AS NullQuantity,
    SUM(CASE WHEN UnitPrice   IS NULL THEN 1 ELSE 0 END) AS NullPrice,
    SUM(CASE WHEN CustomerID  IS NULL THEN 1 ELSE 0 END) AS NullCustomer
FROM stg.SalesRaw;
GO
