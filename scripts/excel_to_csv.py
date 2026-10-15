"""Convert the Online Retail II Excel workbook into ONE clean CSV file.

Why not "Save As CSV" in Excel?
    Excel writes dates exactly as they are *displayed*. A narrow column shows
    "########" and that text ends up in the CSV. pandas reads the real date value
    instead, so the timestamp is always preserved.

Usage
-----
    python scripts/excel_to_csv.py data/online_retail_II.xlsx data/online_retail_II.csv

The workbook has two sheets (2009-2010 and 2010-2011); they are stacked into a
single file with the columns:
    Invoice, StockCode, Description, Quantity, InvoiceDate, Price, Customer ID, Country
(the order that sql/03_load_staging.sql expects).
"""

import sys
from pathlib import Path

import pandas as pd


def main(xlsx_path: str, csv_path: str) -> None:
    # sheet_name=None -> read every sheet into a dict {sheet name: DataFrame}
    sheets = pd.read_excel(xlsx_path, sheet_name=None, engine="openpyxl")
    df = pd.concat(sheets.values(), ignore_index=True)

    # Keep the customer id as a whole number (12347, not 12347.0); missing stays empty.
    df["Customer ID"] = df["Customer ID"].astype("Int64")

    Path(csv_path).parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(csv_path, index=False, date_format="%Y-%m-%d %H:%M:%S", encoding="utf-8")

    print(f"Rows written : {len(df):,}")
    print(f"Columns      : {list(df.columns)}")
    print(f"Date range   : {df['InvoiceDate'].min()}  ->  {df['InvoiceDate'].max()}")
    print(f"Saved to     : {csv_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
