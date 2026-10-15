/*==============================================================================
  07 - MACHINE-LEARNING FEATURE VIEWS
  ------------------------------------------------------------------------------
  These views feed the three Python notebooks. All of them read from
  dbo.vw_NormalSales (genuine product sales only), so every model is trained on
  the same cleaned data.

      vw_CustomerFeatures             -> notebook 01  Customer segmentation (RFM)
      vw_PurchasePredictionFeatures   -> notebook 02  Purchase prediction (inputs)
      vw_PurchasePredictionTarget     -> notebook 02  Purchase prediction (label)
      vw_ProductDailyDemand           -> notebook 03  Demand forecasting
==============================================================================*/

USE RetailIntelligence;
GO

/*------------------------------------------------------------------------------
  vw_CustomerFeatures  -  one row per customer (RFM + extras)

    Recency        days between the customer's last purchase and the last date in the data
    Frequency      number of distinct orders
    Monetary       total revenue
    TotalQuantity  total units bought
    UniqueProducts number of different products bought
    AOV            average order value = Monetary / Frequency

  Customers without a CustomerID cannot be profiled and are excluded.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW dbo.vw_CustomerFeatures
AS
WITH ReferenceDate AS
(
    SELECT CAST(MAX(InvoiceDate) AS DATE) AS RefDate
    FROM dbo.vw_NormalSales
),
CustomerMetrics AS
(
    SELECT
        CustomerID,
        DATEDIFF(DAY, CAST(MAX(InvoiceDate) AS DATE),
                 (SELECT RefDate FROM ReferenceDate))  AS Recency,
        COUNT(DISTINCT InvoiceNo)                      AS Frequency,
        SUM(Revenue)                                   AS Monetary,
        SUM(Quantity)                                  AS TotalQuantity,
        COUNT(DISTINCT StockCode)                      AS UniqueProducts
    FROM dbo.vw_NormalSales
    WHERE CustomerID IS NOT NULL
    GROUP BY CustomerID
)
SELECT
    CustomerID,
    Recency,
    Frequency,
    Monetary,
    TotalQuantity,
    UniqueProducts,
    CAST(Monetary / NULLIF(Frequency, 0) AS DECIMAL(19,4)) AS AOV
FROM CustomerMetrics;
GO

/*------------------------------------------------------------------------------
  Purchase prediction: "Will this customer buy in the next 30 days?"

  To avoid DATA LEAKAGE the time axis is split at a cut-off date:

      history (features)                  future (label)
      ... -----------------------|------------------------------|
                            2011-11-09     2011-11-10 ... 2011-12-09

  vw_PurchasePredictionFeatures only sees purchases up to 2011-11-09.
  vw_PurchasePredictionTarget   looks at the following 30 days.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW dbo.vw_PurchasePredictionFeatures
AS
WITH ReferenceDate AS
(
    SELECT CAST('2011-11-09' AS DATE) AS RefDate        -- cut-off date
),
CustomerMetrics AS
(
    SELECT
        CustomerID,
        DATEDIFF(DAY, CAST(MAX(InvoiceDate) AS DATE),
                 (SELECT RefDate FROM ReferenceDate))  AS Recency,
        COUNT(DISTINCT InvoiceNo)                      AS Frequency,
        SUM(Revenue)                                   AS Monetary,
        SUM(Quantity)                                  AS TotalQuantity,
        COUNT(DISTINCT StockCode)                      AS UniqueProducts
    FROM dbo.vw_NormalSales
    WHERE CustomerID IS NOT NULL
      AND InvoiceDate < '2011-11-10'                    -- history only
    GROUP BY CustomerID
)
SELECT
    CustomerID,
    Recency,
    Frequency,
    Monetary,
    TotalQuantity,
    UniqueProducts,
    CAST(Monetary / NULLIF(Frequency, 0) AS DECIMAL(19,4)) AS AOV
FROM CustomerMetrics;
GO

-- Label = 1 for every customer who bought during the 30 days after the cut-off.
-- Customers missing from this view did not buy (the notebook fills them with 0).
CREATE OR ALTER VIEW dbo.vw_PurchasePredictionTarget
AS
SELECT
    CustomerID,
    1 AS PurchaseNext30Days
FROM dbo.vw_NormalSales
WHERE CustomerID IS NOT NULL
  AND InvoiceDate >= '2011-11-10'
  AND InvoiceDate <  '2011-12-10'
GROUP BY CustomerID;
GO

/*------------------------------------------------------------------------------
  vw_ProductDailyDemand  -  units, revenue and orders per product per day

  Days on which a product did not sell have NO row here. The forecasting notebook
  re-creates the missing days with zero demand.
------------------------------------------------------------------------------*/
CREATE OR ALTER VIEW dbo.vw_ProductDailyDemand
AS
SELECT
    CAST(InvoiceDate AS DATE)     AS SalesDate,
    StockCode,
    SUM(Quantity)                 AS DailyQuantity,
    SUM(Revenue)                  AS DailyRevenue,
    COUNT(DISTINCT InvoiceNo)     AS DailyOrders
FROM dbo.vw_NormalSales
GROUP BY CAST(InvoiceDate AS DATE), StockCode;
GO

-- Quick look
SELECT TOP 20 * FROM dbo.vw_CustomerFeatures    ORDER BY Monetary DESC;
SELECT TOP 20 * FROM dbo.vw_ProductDailyDemand  ORDER BY SalesDate, StockCode;
GO
