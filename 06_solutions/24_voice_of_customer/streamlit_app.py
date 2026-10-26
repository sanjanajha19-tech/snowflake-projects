"""Voice of Customer dashboard - Streamlit in Snowflake app (asset 24).

Create in Snowsight: Projects > Streamlit > + Streamlit App,
location ACCEL_DB.VOC, warehouse ACCEL_WH, then paste this file.
Packages: streamlit, pandas, altair (pre-installed in Streamlit in Snowflake).
The app only reads pre-computed tables - it never calls AI functions itself.
"""
import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Voice of Customer", layout="wide")
session = get_active_session()

DB = "ACCEL_DB.VOC"
SENTIMENT_COLORS = alt.Scale(
    domain=["positive", "neutral", "mixed", "negative", "unknown"],
    range=["#2e7d32", "#9e9e9e", "#f9a825", "#c62828", "#cfd8dc"],
)


@st.cache_data(ttl=300)
def load(query):
    return session.sql(query).to_pandas()


enriched = load(
    f"""
    SELECT TICKET_ID, CREATED_AT, DATE_TRUNC('week', CREATED_AT)::DATE AS WEEK_START,
           COALESCE(PRODUCT_CATEGORY, 'Unknown') AS PRODUCT_CATEGORY, CHANNEL, PRIORITY, STATUS,
           SUBJECT, TOPIC, OVERALL_SENTIMENT, SENTIMENT_SCORE, ROOT_CAUSE, PRODUCT_MENTIONED
    FROM {DB}.TICKET_ENRICHED
    """
)

st.title("Voice of Customer")
if enriched.empty:
    st.warning("No enriched tickets yet. Run 02_enrich_tickets.sql (CALL VOC.ENRICH_TICKETS(200);).")
    st.stop()

total_tickets = int(load("SELECT COUNT(*) AS N FROM ACCEL_DB.DEMO.SUPPORT_TICKETS").N[0])
st.caption(
    f"{len(enriched):,} of {total_tickets:,} support tickets enriched with Cortex AI "
    "(sentiment, topic, root cause). Weekly themes are AI summaries."
)

# ---------------- filters ----------------
with st.sidebar:
    st.header("Filters")
    categories = sorted(enriched["PRODUCT_CATEGORY"].unique().tolist())
    sel_cat = st.multiselect("Product category", categories, default=categories)
    channels = sorted(enriched["CHANNEL"].dropna().unique().tolist())
    sel_ch = st.multiselect("Channel", channels, default=channels)
    min_d = pd.to_datetime(enriched["CREATED_AT"]).min().date()
    max_d = pd.to_datetime(enriched["CREATED_AT"]).max().date()
    date_range = st.date_input("Created between", (min_d, max_d), min_value=min_d, max_value=max_d)

df = enriched[enriched["PRODUCT_CATEGORY"].isin(sel_cat) & enriched["CHANNEL"].isin(sel_ch)].copy()
if isinstance(date_range, (list, tuple)) and len(date_range) == 2:
    created = pd.to_datetime(df["CREATED_AT"]).dt.date
    df = df[(created >= date_range[0]) & (created <= date_range[1])]

if df.empty:
    st.info("No tickets for the selected filters.")
    st.stop()

# ---------------- KPIs ----------------
k1, k2, k3, k4 = st.columns(4)
k1.metric("Tickets", f"{len(df):,}")
k2.metric("Negative share", f"{(df['OVERALL_SENTIMENT'] == 'negative').mean():.0%}")
k3.metric("Avg sentiment (-1..1)", f"{df['SENTIMENT_SCORE'].mean():.2f}")
k4.metric("Top topic", df["TOPIC"].mode().iat[0] if not df["TOPIC"].dropna().empty else "n/a")

# ---------------- sentiment trend ----------------
st.subheader("Sentiment trend")
trend = (
    df.groupby(["WEEK_START", "OVERALL_SENTIMENT"]).size().reset_index(name="TICKETS")
)
trend["WEEK_START"] = pd.to_datetime(trend["WEEK_START"])
bars = (
    alt.Chart(trend)
    .mark_bar()
    .encode(
        x=alt.X("WEEK_START:T", title="Week"),
        y=alt.Y("TICKETS:Q", title="Tickets"),
        color=alt.Color("OVERALL_SENTIMENT:N", scale=SENTIMENT_COLORS, title="Sentiment"),
        tooltip=["WEEK_START:T", "OVERALL_SENTIMENT:N", "TICKETS:Q"],
    )
    .properties(height=280)
)
score = df.groupby("WEEK_START")["SENTIMENT_SCORE"].mean().reset_index()
score["WEEK_START"] = pd.to_datetime(score["WEEK_START"])
line = (
    alt.Chart(score)
    .mark_line(color="#1565c0", point=True)
    .encode(
        x="WEEK_START:T",
        y=alt.Y("SENTIMENT_SCORE:Q", title="Avg sentiment score", scale=alt.Scale(domain=[-1, 1])),
        tooltip=["WEEK_START:T", alt.Tooltip("SENTIMENT_SCORE:Q", format=".2f")],
    )
)
st.altair_chart(alt.layer(bars, line).resolve_scale(y="independent"), use_container_width=True)

# ---------------- topics ----------------
c1, c2 = st.columns(2)
with c1:
    st.subheader("Topics")
    topics = df.groupby(["TOPIC", "OVERALL_SENTIMENT"]).size().reset_index(name="TICKETS")
    st.altair_chart(
        alt.Chart(topics)
        .mark_bar()
        .encode(
            y=alt.Y("TOPIC:N", sort="-x", title=None),
            x=alt.X("TICKETS:Q", title="Tickets"),
            color=alt.Color("OVERALL_SENTIMENT:N", scale=SENTIMENT_COLORS, title="Sentiment"),
            tooltip=["TOPIC", "OVERALL_SENTIMENT", "TICKETS"],
        )
        .properties(height=280),
        use_container_width=True,
    )
with c2:
    st.subheader("Aspect sentiment")
    aspects = load(
        f"""
        SELECT ASPECT, ASPECT_SENTIMENT, PRODUCT_CATEGORY, TICKET_ID
        FROM {DB}.TICKET_ASPECT_SENTIMENT
        """
    )
    aspects = aspects[aspects["TICKET_ID"].isin(df["TICKET_ID"])]
    if aspects.empty:
        st.info("No aspect-level sentiment for this selection.")
    else:
        agg = aspects.groupby(["ASPECT", "ASPECT_SENTIMENT"]).size().reset_index(name="MENTIONS")
        st.altair_chart(
            alt.Chart(agg)
            .mark_bar()
            .encode(
                y=alt.Y("ASPECT:N", title=None),
                x=alt.X("MENTIONS:Q", stack="normalize", title="Share of mentions"),
                color=alt.Color("ASPECT_SENTIMENT:N", scale=SENTIMENT_COLORS, title="Sentiment"),
                tooltip=["ASPECT", "ASPECT_SENTIMENT", "MENTIONS"],
            )
            .properties(height=280),
            use_container_width=True,
        )

# ---------------- top issues ----------------
st.subheader("Top issues (AI summary, rolling window)")
issues = load(f"SELECT * FROM {DB}.TOPIC_ISSUES ORDER BY TICKETS DESC")
if issues.empty:
    st.info("Run 03_weekly_themes.sql to build AI issue summaries.")
else:
    st.caption(f"Window: {issues.WINDOW_START.iat[0]} to {issues.WINDOW_END.iat[0]}")
    for _, row in issues.iterrows():
        with st.expander(f"{row.TOPIC} · {int(row.TICKETS)} tickets · {row.NEGATIVE_SHARE:.0%} negative"):
            st.markdown(row.TOP_ISSUES or "_no summary_")

root = (
    df[df["ROOT_CAUSE"].notna() & (df["ROOT_CAUSE"].str.lower() != "none")]
    .groupby(["TOPIC", "ROOT_CAUSE"]).size().reset_index(name="TICKETS")
    .sort_values("TICKETS", ascending=False).head(15)
)
with st.expander("Most frequent extracted root causes"):
    st.dataframe(root, use_container_width=True, hide_index=True)

# ---------------- weekly themes ----------------
st.subheader("Weekly themes by product category")
themes = load(f"SELECT * FROM {DB}.WEEKLY_THEMES ORDER BY WEEK_START DESC, TICKETS DESC")
themes = themes[themes["PRODUCT_CATEGORY"].isin(sel_cat)]
if themes.empty:
    st.info("No weekly themes for the selected categories yet.")
else:
    weeks = themes["WEEK_START"].drop_duplicates().tolist()
    wk = st.selectbox("Week starting", weeks)
    for _, row in themes[themes["WEEK_START"] == wk].iterrows():
        st.markdown(
            f"**{row.PRODUCT_CATEGORY}** · {int(row.TICKETS)} tickets · "
            f"{int(row.NEGATIVE_TICKETS)} negative · top topic *{row.TOP_TOPIC}*"
        )
        st.write(row.THEME_SUMMARY)

# ---------------- escalation risk ----------------
st.subheader("Open tickets at risk of escalation")
risk = load(
    f"""
    SELECT TICKET_ID, CUSTOMER_NAME, SEGMENT, PRIORITY, TOPIC, OVERALL_SENTIMENT, AGE_HOURS,
           PRIOR_TICKETS_90D, RISK_SCORE_CAPPED AS RISK_SCORE, RISK_BAND, SUBJECT, ROOT_CAUSE,
           COALESCE(PRODUCT_CATEGORY, 'Unknown') AS PRODUCT_CATEGORY
    FROM {DB}.ESCALATION_RISK ORDER BY RISK_SCORE DESC
    """
)
risk = risk[risk["PRODUCT_CATEGORY"].isin(sel_cat) | (risk["PRODUCT_CATEGORY"] == "Unknown")]
band = st.radio("Risk band", ["High", "Medium", "Low", "All"], horizontal=True)
if band != "All":
    risk = risk[risk["RISK_BAND"] == band]
st.dataframe(risk, use_container_width=True, hide_index=True)
