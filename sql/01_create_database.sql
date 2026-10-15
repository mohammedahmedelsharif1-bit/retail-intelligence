/*==============================================================================
  01 - CREATE DATABASE AND SCHEMAS
  ------------------------------------------------------------------------------
  Creates the RetailIntelligence database and the three schemas used to
  separate the layers of the warehouse:

      stg   -> Staging  : raw data exactly as it arrives from the CSV file
      dim   -> Dimensions: descriptive tables (who / what / when / where)
      fact  -> Facts    : the sales transactions (the numbers we analyse)

  Safe to re-run: every statement checks whether the object already exists.
==============================================================================*/

IF DB_ID(N'RetailIntelligence') IS NULL
    CREATE DATABASE RetailIntelligence;
GO

USE RetailIntelligence;
GO

IF SCHEMA_ID(N'stg')  IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'dim')  IS NULL EXEC (N'CREATE SCHEMA dim');
IF SCHEMA_ID(N'fact') IS NULL EXEC (N'CREATE SCHEMA fact');
GO
