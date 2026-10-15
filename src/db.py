"""Database helper shared by all notebooks.

Connection settings are read from environment variables, so no server name,
user name or password ever needs to be written into the notebooks:

    SQL_SERVER    SQL Server instance name   (default: localhost)
    SQL_DATABASE  database name              (default: RetailIntelligence)
    ODBC_DRIVER   installed ODBC driver      (default: ODBC Driver 17 for SQL Server)

Windows authentication (Trusted_Connection) is used.

Examples
--------
Default local instance:                no setup needed
Named instance (SQL Server Express):   set SQL_SERVER=localhost\\SQLEXPRESS
Machine name shown in SSMS:            set SQL_SERVER=MY-PC-NAME
"""

import os
from urllib.parse import quote_plus

import pandas as pd
from sqlalchemy import create_engine, text

SERVER = os.getenv("SQL_SERVER", "localhost")
DATABASE = os.getenv("SQL_DATABASE", "RetailIntelligence")
DRIVER = os.getenv("ODBC_DRIVER", "ODBC Driver 17 for SQL Server")


def get_engine():
    """Create a SQLAlchemy engine for the RetailIntelligence database."""
    conn_str = (
        f"DRIVER={{{DRIVER}}};"
        f"SERVER={SERVER};"
        f"DATABASE={DATABASE};"
        "Trusted_Connection=yes;"
        "TrustServerCertificate=yes;"
    )
    return create_engine(f"mssql+pyodbc:///?odbc_connect={quote_plus(conn_str)}")


def read_sql(query: str) -> pd.DataFrame:
    """Run a SELECT query and return the result as a DataFrame."""
    with get_engine().connect() as connection:
        return pd.read_sql(text(query), connection)
