"""Retail Intelligence - interactive demo of the three analytics modules.

The app does NOT connect to SQL Server. It reads the small files that the
notebooks export into the artifacts/ folder, so it runs anywhere.

Run locally from the project root:
    streamlit run app/streamlit_app.py
"""

import json
from pathlib import Path

import numpy as np
import pandas as pd
import streamlit as st

ARTIFACTS = Path(__file__).resolve().parent.parent / "artifacts"

SEGMENT_ORDER = [
    "Active High-Value",
    "Recent Mid-Value",
    "Inactive Low-Mid-Value",
    "Inactive Very-Low-Value",
]

SEGMENT_ACTIONS = {
    "Active High-Value": "Protect them: loyalty / VIP terms, early access, dedicated account management.",
    "Recent Mid-Value": "Grow them: cross-sell and bundle offers to raise order value and frequency.",
    "Inactive Low-Mid-Value": "Win them back: a targeted reactivation campaign with a personalised offer.",
    "Inactive Very-Low-Value": "Low-cost automated emails only; avoid heavy marketing spend.",
}

st.set_page_config(page_title="Retail Intelligence", page_icon="🛒", layout="wide")


# -----------------------------------------------------------------------------
# Loading
# -----------------------------------------------------------------------------
@st.cache_data
def load_csv(name: str) -> pd.DataFrame:
    return pd.read_csv(ARTIFACTS / name)


@st.cache_data
def load_model_card() -> dict:
    with open(ARTIFACTS / "purchase_model.json", encoding="utf-8") as f:
        return json.load(f)


def predict_probability(card: dict, values: dict) -> float:
    """Logistic regression recomputed from the exported numbers."""
    x = np.log1p(np.array([values[name] for name in card["features"]], dtype=float))
    z = (x - np.array(card["scaler_mean"])) / np.array(card["scaler_scale"])
    logit = float(z @ np.array(card["coefficients"]) + card["intercept"])
    return 1.0 / (1.0 + np.exp(-logit))


REQUIRED_FILES = [
    "customer_segments.csv", "segment_profile.csv",
    "purchase_model.json", "customer_purchase_scores.csv",
    "demand_forecasts.csv", "forecast_metrics.csv",
]
missing = [f for f in REQUIRED_FILES if not (ARTIFACTS / f).exists()]

st.title("🛒 Retail Intelligence")
st.caption(
    "Customer segmentation · purchase prediction · demand forecasting, built on the "
    "Online Retail II dataset (2009-2011). Data is anonymised; this is a portfolio demo."
)

if missing:
    st.error(
        "The artifacts folder is incomplete. Run the three notebooks first "
        "(each ends with an *Export for the web app* cell).\n\nMissing: " + ", ".join(missing)
    )
    st.stop()

tab_segments, tab_purchase, tab_demand = st.tabs(
    ["👥 Customer segments", "🎯 Purchase prediction", "📦 Demand forecast"]
)

# -----------------------------------------------------------------------------
# Tab 1 - Customer segments
# -----------------------------------------------------------------------------
with tab_segments:
    segments = load_csv("customer_segments.csv")
    profile = load_csv("segment_profile.csv").set_index("Segment").reindex(SEGMENT_ORDER)

    st.subheader("Who are our customers?")
    left, right = st.columns([1, 2])
    left.metric("Customers segmented", f"{len(segments):,}")
    counts = segments["Segment"].value_counts().reindex(SEGMENT_ORDER)
    right.bar_chart(counts, y_label="Customers")

    st.markdown("**Segment profile** (medians)")
    st.dataframe(profile.round(2), width="stretch")

    st.markdown("**Recommended actions** *(proposals, not tested campaigns)*")
    for name in SEGMENT_ORDER:
        st.markdown(f"- **{name}**: {SEGMENT_ACTIONS[name]}")

    st.divider()
    st.subheader("Look up a customer")
    customer_id = st.number_input(
        "CustomerID", min_value=0, value=int(segments["CustomerID"].iloc[0]), step=1
    )
    row = segments[segments["CustomerID"] == customer_id]
    if row.empty:
        st.warning("This CustomerID is not in the segmented data.")
    else:
        segment = row["Segment"].iloc[0]
        st.success(f"Segment: **{segment}**")
        st.write(SEGMENT_ACTIONS.get(segment, ""))
        st.dataframe(row.drop(columns=["Segment"]).set_index("CustomerID").round(2),
                     width="stretch")

# -----------------------------------------------------------------------------
# Tab 2 - Purchase prediction
# -----------------------------------------------------------------------------
with tab_purchase:
    card = load_model_card()
    scores = load_csv("customer_purchase_scores.csv")
    metrics = card["test_metrics"]
    threshold = card["threshold"]

    st.subheader("Will this customer buy in the next 30 days?")
    st.caption(
        f"{card['model']} · features computed up to {card['cutoff_date']} · "
        f"decision threshold {threshold:.2f}"
    )
    m1, m2, m3, m4 = st.columns(4)
    m1.metric("Precision", f"{metrics['precision']:.2f}")
    m2.metric("Recall", f"{metrics['recall']:.2f}")
    m3.metric("F1", f"{metrics['f1']:.2f}")
    m4.metric("ROC-AUC", f"{metrics['roc_auc']:.2f}")
    st.caption("Metrics on the held-out test set from the notebook.")

    st.markdown("#### What-if calculator")
    c1, c2, c3 = st.columns(3)
    recency = c1.number_input("Recency (days since last purchase)", 0, 800, 30)
    frequency = c2.number_input("Frequency (number of orders)", 1, 500, 5)
    monetary = c3.number_input("Total spend", 1.0, 1_000_000.0, 1500.0, step=100.0)
    c4, c5 = st.columns(2)
    quantity = c4.number_input("Total units bought", 1, 500_000, 800)
    unique_products = c5.number_input("Different products bought", 1, 5000, 40)

    probability = predict_probability(card, {
        "Recency": recency,
        "Frequency": frequency,
        "Monetary": monetary,
        "TotalQuantity": quantity,
        "UniqueProducts": unique_products,
        "AOV": monetary / max(frequency, 1),
    })
    st.progress(min(max(probability, 0.0), 1.0), text=f"Probability of buying: {probability:.1%}")
    if probability >= threshold:
        st.success("Flagged as **likely to buy**: a good candidate for a reminder or offer.")
    else:
        st.info("Not flagged at the current threshold.")

    st.divider()
    st.markdown("#### Customers to contact first")
    top_n = st.slider("How many customers?", 5, 100, 20, step=5)
    top = scores.sort_values("PurchaseProbability", ascending=False).head(top_n)
    st.dataframe(top.round(3), width="stretch", hide_index=True)
    st.download_button("Download this list (CSV)", top.to_csv(index=False), "customers_to_contact.csv")
    st.caption(
        "Scores are computed for all customers as of the cut-off date. Customers that were "
        "also used to train the model are scored in-sample, so treat this as a demo."
    )

# -----------------------------------------------------------------------------
# Tab 3 - Demand forecast
# -----------------------------------------------------------------------------
with tab_demand:
    forecasts = load_csv("demand_forecasts.csv")
    forecasts["SalesDate"] = pd.to_datetime(forecasts["SalesDate"])
    forecast_metrics = load_csv("forecast_metrics.csv").set_index("Model")

    st.subheader("Daily demand for the best-selling products")
    st.caption(
        "Hold-out period: the last 30 days of the data. The forecast is one day ahead "
        "(it uses the previous days' real sales). This explores past forecasts; it is not a live forecast."
    )

    st.markdown("**Model comparison on the hold-out period**")
    st.dataframe(forecast_metrics, width="stretch")

    forecasts["Label"] = forecasts["StockCode"].astype(str) + " - " + forecasts["Description"].fillna("").astype(str)
    order = forecasts.groupby("Label")["ActualQuantity"].sum().sort_values(ascending=False).index
    choice = st.selectbox("Product (sorted by units sold in the period)", order)

    one = forecasts[forecasts["Label"] == choice].sort_values("SalesDate").set_index("SalesDate")
    st.line_chart(
        one[["ActualQuantity", "PredictedQuantity", "BaselineQuantity"]]
        .rename(columns={"ActualQuantity": "Actual", "PredictedQuantity": "XGBoost", "BaselineQuantity": "Same day last week"}),
        y_label="Units per day",
    )

    mae_model = (one["ActualQuantity"] - one["PredictedQuantity"]).abs().mean()
    mae_base = (one["ActualQuantity"] - one["BaselineQuantity"]).abs().mean()
    k1, k2, k3 = st.columns(3)
    k1.metric("Units sold in period", f"{one['ActualQuantity'].sum():,.0f}")
    k2.metric("XGBoost MAE (units/day)", f"{mae_model:,.1f}")
    k3.metric("Baseline MAE (units/day)", f"{mae_base:,.1f}", delta=f"{mae_model - mae_base:,.1f}", delta_color="inverse")
    st.caption("Demand is spiky (bulk wholesale orders), so single days can be far off; see the project README.")
