/*==============================================================================
  06 - CLEANING LAYER AND ANALYTICS VIEWS
  ------------------------------------------------------------------------------
  The raw data mixes real product sales with returns, fees, postage, stock
  write-offs and accounting entries. This script builds the "single source of
  truth" for every analysis:

      stg.SalesRaw
          |  1) remove exact duplicate rows
          |  2) label every row with a TransactionType
          v
      dbo.vw_CleanTransactions   (all rows, labelled, de-duplicated)
          |  keep only TransactionType = 'Normal Product Sale'
          v
      dbo.vw_NormalSales         (the base for KPIs, segmentation, forecasting)
          v
      dbo.vw_SalesKPIs, dbo.vw_MonthlySales, dbo.vw_MonthlyReturns

  TransactionType rules (the first matching rule wins - ORDER MATTERS):

      Accounting Adjustment          StockCode 'B' ("Adjust bad debt")
      Adjustment                     StockCode ADJUST / ADJUST2
      Financial Charge               StockCode BANK CHARGES
      Fee                            StockCode AMAZONFEE
      Commission                     StockCode CRUK
      Shipping / Carriage            StockCode C2
      Postage                        StockCode POST / DOT
      Discount                       StockCode D
      Manual Transaction             StockCode M
      Sample                         StockCode S
      Gift Voucher                   StockCode like gift_*
      Cancellation / Return          'C' invoice, negative qty, positive price
      Inventory Adjustment           negative qty with zero price
      Zero-Price Special Transaction positive qty with zero price
      Normal Product Sale            everything else

  Views use CREATE OR ALTER, so the script can be re-run at any time.
==============================================================================*/

USE RetailIntelligence;
GO

/*------------------------------------------------------------------------------
  vw_CleanTransactions
  Step 1 - de-duplicate: rows identical in every business column are collapsed
           to one (ROW_NUMBER keeps the first RawID of each group).
  Step 2 - classify every remaining row and compute Revenue.
  NOTE: collapsing exact duplicates is a modelling decision. A customer could in
        theory buy the same line twice in the same second; see README "Limitations".
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW dbo.vw_CleanTransactions
AS
WITH DeduplicatedSales AS
(
    SELECT
        *,
        ROW_NUMBER() OVER
        (
            PARTITION BY InvoiceNo, StockCode, Description, Quantity,
                         InvoiceDate, UnitPrice, CustomerID, Country
            ORDER BY RawID
        ) AS rn
    FROM stg.SalesRaw
)
SELECT
    RawID,
    InvoiceNo,
    StockCode,
    Description,
    Quantity,
    InvoiceDate,
    UnitPrice,
    CustomerID,
    Country,

    CASE
        -- Accounting / financial entries
        WHEN StockCode = 'B' AND Description = 'Adjust bad debt' THEN 'Accounting Adjustment'
        WHEN StockCode IN ('ADJUST', 'ADJUST2')                  THEN 'Adjustment'
        WHEN StockCode = 'BANK CHARGES'                          THEN 'Financial Charge'
        WHEN StockCode = 'AMAZONFEE'                             THEN 'Fee'
        WHEN StockCode = 'CRUK'                                  THEN 'Commission'

        -- Services and charges
        WHEN StockCode = 'C2'                                    THEN 'Shipping / Carriage'
        WHEN StockCode IN ('POST', 'DOT')                        THEN 'Postage'
        WHEN StockCode = 'D'                                     THEN 'Discount'

        -- Operational entries
        WHEN StockCode = 'M'                                     THEN 'Manual Transaction'
        WHEN StockCode = 'S'                                     THEN 'Sample'
        WHEN StockCode LIKE 'gift_%'                             THEN 'Gift Voucher'

        -- Returns and stock movements
        WHEN InvoiceNo LIKE 'C%' AND Quantity < 0 AND UnitPrice > 0 THEN 'Cancellation / Return'
        WHEN Quantity < 0 AND UnitPrice = 0                      THEN 'Inventory Adjustment'
        WHEN UnitPrice = 0 AND Quantity > 0                      THEN 'Zero-Price Special Transaction'

        -- Genuine product sale
        ELSE 'Normal Product Sale'
    END AS TransactionType,

    CONVERT(DECIMAL(19,4), Quantity * UnitPrice) AS Revenue
FROM DeduplicatedSales
WHERE rn = 1;
GO

/*------------------------------------------------------------------------------
  vw_NormalSales
  Only genuine product sales. This is what business KPIs and ML features use.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW dbo.vw_NormalSales
AS
SELECT
    RawID, InvoiceNo, StockCode, Description, Quantity,
    InvoiceDate, UnitPrice, CustomerID, Country, Revenue
FROM dbo.vw_CleanTransactions
WHERE TransactionType = 'Normal Product Sale';
GO

/*------------------------------------------------------------------------------
  vw_SalesKPIs  -  one row of headline numbers
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW dbo.vw_SalesKPIs
AS
SELECT
    SUM(Revenue)                  AS TotalRevenue,
    COUNT(DISTINCT InvoiceNo)     AS TotalOrders,
    COUNT(DISTINCT CustomerID)    AS TotalCustomers,
    COUNT(DISTINCT StockCode)     AS TotalProducts,
    SUM(Quantity)                 AS TotalQuantity,
    CAST(SUM(Revenue) / NULLIF(COUNT(DISTINCT InvoiceNo), 0) AS DECIMAL(19,4)) AS AverageOrderValue
FROM dbo.vw_NormalSales;
GO

/*------------------------------------------------------------------------------
  vw_MonthlySales  -  gross revenue per month (normal sales only)
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW dbo.vw_MonthlySales
AS
SELECT
    YEAR(InvoiceDate)             AS SalesYear,
    MONTH(InvoiceDate)            AS SalesMonth,
    SUM(Revenue)                  AS GrossRevenue,
    COUNT(DISTINCT InvoiceNo)     AS TotalOrders,
    SUM(Quantity)                 AS TotalQuantity,
    COUNT(DISTINCT CustomerID)    AS TotalCustomers,
    COUNT(DISTINCT StockCode)     AS TotalProducts
FROM dbo.vw_NormalSales
GROUP BY YEAR(InvoiceDate), MONTH(InvoiceDate);
GO

/*------------------------------------------------------------------------------
  vw_MonthlyReturns  -  cancellations / returns per month
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW dbo.vw_MonthlyReturns
AS
SELECT
    YEAR(InvoiceDate)             AS SalesYear,
    MONTH(InvoiceDate)            AS SalesMonth,
    COUNT(DISTINCT InvoiceNo)     AS ReturnOrders,
    SUM(Quantity)                 AS ReturnedQuantity,
    SUM(Revenue)                  AS ReturnRevenue
FROM dbo.vw_CleanTransactions
WHERE TransactionType = 'Cancellation / Return'
GROUP BY YEAR(InvoiceDate), MONTH(InvoiceDate);
GO

/*------------------------------------------------------------------------------
  Validation: how many rows fall into each TransactionType?
  Expect "Normal Product Sale" to be by far the largest group.
------------------------------------------------------------------------------*/
SELECT
    TransactionType,
    COUNT(*)      AS RowsCount,
    SUM(Quantity) AS TotalQuantity,
    SUM(Revenue)  AS TotalRevenue
FROM dbo.vw_CleanTransactions
GROUP BY TransactionType
ORDER BY RowsCount DESC;
GO
