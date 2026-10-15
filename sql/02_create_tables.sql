/*==============================================================================
  02 - CREATE TABLES
  ------------------------------------------------------------------------------
  Builds every table of the warehouse:

    Staging layer   stg.SalesRaw_Text   all columns as text (safe landing zone)
                    stg.SalesRaw        typed copy of the raw data

    Star schema     dim.DimDate  dim.DimCountry  dim.DimProduct  dim.DimCustomer
                    fact.FactSales  (one row = one product line on one invoice)

  Design decisions
    * Grain of FactSales: one product line within one invoice. InvoiceNo
      repeats across rows, so it can NOT be the primary key.
    * Surrogate keys (ProductKey, CustomerKey, ...) are warehouse-owned integers,
      independent from source codes such as StockCode or CustomerID.
    * "Unknown" members (key = 0) let us keep transactions that have no
      CustomerID / unknown product / unknown country instead of dropping them.
    * Revenue is a computed column (Quantity * UnitPrice) so it is never stale.

  Safe to re-run: tables are only created if they do not exist yet.
==============================================================================*/

USE RetailIntelligence;
GO

/*------------------------------------------------------------------------------
  A) STAGING LAYER
------------------------------------------------------------------------------*/

-- Landing zone: every column is text, so BULK INSERT can never fail on a
-- data-type problem. Types are fixed in the next step (03_load_staging.sql).
IF OBJECT_ID(N'stg.SalesRaw_Text', N'U') IS NULL
CREATE TABLE stg.SalesRaw_Text
(
    InvoiceNo    NVARCHAR(50),
    StockCode    NVARCHAR(50),
    Description  NVARCHAR(500),
    Quantity     NVARCHAR(50),
    InvoiceDate  NVARCHAR(50),
    UnitPrice    NVARCHAR(50),
    CustomerID   NVARCHAR(50),
    Country      NVARCHAR(100)
);
GO

-- Typed staging table. Every column is NULL-able on purpose: the raw data
-- contains missing values and we want to inspect them, not lose them.
IF OBJECT_ID(N'stg.SalesRaw', N'U') IS NULL
CREATE TABLE stg.SalesRaw
(
    RawID        INT IDENTITY(1,1) PRIMARY KEY,   -- technical row id

    InvoiceNo    NVARCHAR(20)   NULL,             -- starts with 'C' = cancellation
    StockCode    NVARCHAR(50)   NULL,
    Description  NVARCHAR(255)  NULL,
    Quantity     INT            NULL,
    InvoiceDate  DATETIME2(0)   NULL,
    UnitPrice    DECIMAL(19,4)  NULL,
    CustomerID   INT            NULL,
    Country      NVARCHAR(100)  NULL
);
GO

/*------------------------------------------------------------------------------
  B) DIMENSION TABLES
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dim.DimDate', N'U') IS NULL
CREATE TABLE dim.DimDate
(
    DateKey        INT          NOT NULL PRIMARY KEY,   -- yyyymmdd, e.g. 20110115
    FullDate       DATE         NOT NULL UNIQUE,

    YearNumber     INT          NOT NULL,
    QuarterNumber  INT          NOT NULL,
    MonthNumber    INT          NOT NULL,
    MonthName      VARCHAR(20)  NOT NULL,
    DayNumber      INT          NOT NULL,
    DayOfWeek      INT          NOT NULL,
    DayName        VARCHAR(20)  NOT NULL,
    IsWeekend      BIT          NOT NULL
);
GO

IF OBJECT_ID(N'dim.DimCountry', N'U') IS NULL
CREATE TABLE dim.DimCountry
(
    CountryKey   INT IDENTITY(1,1) PRIMARY KEY,
    CountryName  VARCHAR(100) NOT NULL,

    CONSTRAINT UQ_DimCountry_CountryName UNIQUE (CountryName)
);
GO

IF OBJECT_ID(N'dim.DimProduct', N'U') IS NULL
CREATE TABLE dim.DimProduct
(
    ProductKey   INT IDENTITY(1,1) PRIMARY KEY,
    StockCode    VARCHAR(50)  NOT NULL,
    Description  VARCHAR(255) NULL,

    CONSTRAINT UQ_DimProduct_StockCode UNIQUE (StockCode)
);
GO

IF OBJECT_ID(N'dim.DimCustomer', N'U') IS NULL
CREATE TABLE dim.DimCustomer
(
    CustomerKey  INT IDENTITY(1,1) PRIMARY KEY,   -- warehouse key
    CustomerID   INT NOT NULL,                    -- id from the source data

    CONSTRAINT UQ_DimCustomer_CustomerID UNIQUE (CustomerID)
);
GO

/*------------------------------------------------------------------------------
  C) FACT TABLE
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'fact.FactSales', N'U') IS NULL
CREATE TABLE fact.FactSales
(
    SaleKey         INT IDENTITY(1,1) PRIMARY KEY,

    InvoiceNo       VARCHAR(20)    NOT NULL,

    ProductKey      INT            NOT NULL,
    CustomerKey     INT            NOT NULL,
    DateKey         INT            NOT NULL,
    CountryKey      INT            NOT NULL,

    Quantity        INT            NOT NULL,
    UnitPrice       DECIMAL(19,4)  NOT NULL,
    IsCancellation  BIT            NOT NULL,

    Revenue AS CONVERT(DECIMAL(19,4), Quantity * UnitPrice) PERSISTED
);
GO

/*------------------------------------------------------------------------------
  D) FOREIGN KEYS  (fact -> dimensions)
------------------------------------------------------------------------------*/

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_FactSales_Product')
    ALTER TABLE fact.FactSales
    ADD CONSTRAINT FK_FactSales_Product
        FOREIGN KEY (ProductKey)  REFERENCES dim.DimProduct (ProductKey);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_FactSales_Customer')
    ALTER TABLE fact.FactSales
    ADD CONSTRAINT FK_FactSales_Customer
        FOREIGN KEY (CustomerKey) REFERENCES dim.DimCustomer (CustomerKey);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_FactSales_Date')
    ALTER TABLE fact.FactSales
    ADD CONSTRAINT FK_FactSales_Date
        FOREIGN KEY (DateKey)     REFERENCES dim.DimDate (DateKey);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_FactSales_Country')
    ALTER TABLE fact.FactSales
    ADD CONSTRAINT FK_FactSales_Country
        FOREIGN KEY (CountryKey)  REFERENCES dim.DimCountry (CountryKey);
GO

/*------------------------------------------------------------------------------
  E) "UNKNOWN" MEMBERS  (key = 0)
  Transactions without a CustomerID, or whose product / country / date cannot
  be matched, point to these rows instead of being discarded.
------------------------------------------------------------------------------*/

IF NOT EXISTS (SELECT 1 FROM dim.DimCustomer WHERE CustomerKey = 0)
BEGIN
    SET IDENTITY_INSERT dim.DimCustomer ON;
    INSERT INTO dim.DimCustomer (CustomerKey, CustomerID) VALUES (0, -1);
    SET IDENTITY_INSERT dim.DimCustomer OFF;
END;
GO

IF NOT EXISTS (SELECT 1 FROM dim.DimProduct WHERE ProductKey = 0)
BEGIN
    SET IDENTITY_INSERT dim.DimProduct ON;
    INSERT INTO dim.DimProduct (ProductKey, StockCode, Description)
    VALUES (0, 'UNKNOWN', 'Unknown Product');
    SET IDENTITY_INSERT dim.DimProduct OFF;
END;
GO

IF NOT EXISTS (SELECT 1 FROM dim.DimCountry WHERE CountryKey = 0)
BEGIN
    SET IDENTITY_INSERT dim.DimCountry ON;
    INSERT INTO dim.DimCountry (CountryKey, CountryName) VALUES (0, 'Unknown');
    SET IDENTITY_INSERT dim.DimCountry OFF;
END;
GO

IF NOT EXISTS (SELECT 1 FROM dim.DimDate WHERE DateKey = 0)
    INSERT INTO dim.DimDate
        (DateKey, FullDate, YearNumber, QuarterNumber, MonthNumber, MonthName,
         DayNumber, DayOfWeek, DayName, IsWeekend)
    VALUES
        (0, '1900-01-01', 1900, 1, 1, 'Unknown', 1, 1, 'Unknown', 0);
GO
