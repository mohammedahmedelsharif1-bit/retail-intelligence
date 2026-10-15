/*==============================================================================
  08 - BUSINESS ANALYTICS QUERIES
  ------------------------------------------------------------------------------
  Ready-to-run questions a business user would ask. They only read from the
  cleaned views, so the numbers exclude returns, fees, postage and other
  non-product rows. Handy as a source for Power BI / Excel dashboards.
==============================================================================*/

USE RetailIntelligence;
GO

-- Q1. Headline KPIs
SELECT * FROM dbo.vw_SalesKPIs;

-- Q2. How do the different transaction types compare?
SELECT
    TransactionType,
    COUNT(*)      AS RowsCount,
    SUM(Quantity) AS TotalQuantity,
    SUM(Revenue)  AS TotalRevenue
FROM dbo.vw_CleanTransactions
GROUP BY TransactionType
ORDER BY RowsCount DESC;

-- Q3. Which countries generate the most revenue?
SELECT
    Country,
    SUM(Revenue)               AS TotalRevenue,
    COUNT(DISTINCT InvoiceNo)  AS TotalOrders,
    COUNT(DISTINCT CustomerID) AS TotalCustomers,
    SUM(Quantity)              AS TotalQuantity
FROM dbo.vw_NormalSales
GROUP BY Country
ORDER BY TotalRevenue DESC;

-- Q4. Monthly sales trend
SELECT *
FROM dbo.vw_MonthlySales
ORDER BY SalesYear, SalesMonth;

-- Q5. Top 10 products by revenue
SELECT TOP 10
    StockCode,
    MAX(Description)           AS Description,
    SUM(Quantity)              AS TotalQuantity,
    SUM(Revenue)               AS TotalRevenue,
    COUNT(DISTINCT InvoiceNo)  AS TotalOrders
FROM dbo.vw_NormalSales
GROUP BY StockCode
ORDER BY TotalRevenue DESC;

-- Q6. Top 10 customers by revenue (known customers only)
SELECT TOP 10
    CustomerID,
    SUM(Revenue)               AS TotalRevenue,
    COUNT(DISTINCT InvoiceNo)  AS TotalOrders,
    SUM(Quantity)              AS TotalQuantity,
    COUNT(DISTINCT StockCode)  AS UniqueProducts
FROM dbo.vw_NormalSales
WHERE CustomerID IS NOT NULL
GROUP BY CustomerID
ORDER BY TotalRevenue DESC;

-- Q7. Returns and cancellations per month
SELECT *
FROM dbo.vw_MonthlyReturns
ORDER BY SalesYear, SalesMonth;
GO
