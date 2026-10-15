# artifacts/

Small files exported by the notebooks and read by the web app (`app/streamlit_app.py`).
They are created by the **"Export for the web app"** cell at the end of each notebook:

| File | Created by | Content |
|---|---|---|
| `customer_segments.csv` | notebook 01 | CustomerID, segment and RFM features |
| `segment_profile.csv` | notebook 01 | Median profile of each segment |
| `purchase_model.json` | notebook 02 | Final logistic regression as plain numbers + threshold + test metrics |
| `customer_purchase_scores.csv` | notebook 02 | Purchase probability for every customer at the cut-off date |
| `demand_forecasts.csv` | notebook 03 | Hold-out actual vs predicted vs baseline, per product and day |
| `forecast_metrics.csv` | notebook 03 | MAE / RMSE / WAPE per model |

Commit these files after running the notebooks: the deployed app needs them.
They contain only anonymised customer ids and aggregated numbers, never raw transactions.
