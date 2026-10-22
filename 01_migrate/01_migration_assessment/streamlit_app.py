# Migration Assessment dashboard - Streamlit in Snowflake
# Create in Snowsight: Projects > Streamlit > + Streamlit App
#   Location: ACCEL_DB.MIGRATION_ASSESSMENT, Warehouse: ACCEL_WH; paste this file.
# Needs: 01_inventory_model.sql, 02_sample_inventory.sql (or 03), 04_scoring.sql.
# Optional: 05_ai_code_insights.sql for AI summaries in the drill-down.

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Migration Assessment", layout="wide")
session = get_active_session()

SCHEMA = "ACCEL_DB.MIGRATION_ASSESSMENT"
BANDS = ["Low", "Medium", "High", "Very High"]
BAND_COLORS = ["#9ec5f4", "#5598e7", "#256abf", "#104281"]  # one-hue sequential ramp (ordinal)
SINGLE = "#2a78d6"


@st.cache_data(ttl=300)
def run_query(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


def safe_query(sql: str) -> pd.DataFrame:
    try:
        return run_query(sql)
    except Exception:
        return pd.DataFrame()


st.title("Legacy DWH Migration Assessment")
st.caption("Rule-based complexity scoring, effort estimate and dependency-driven wave plan")

results = safe_query(f"SELECT * FROM {SCHEMA}.ASSESSMENT_RESULT")
if results.empty:
    st.warning("ASSESSMENT_RESULT not found or empty. Run 01, 02 (or 03) and 04 scripts first.")
    st.stop()

results["SIZE_GB"] = results["SIZE_GB"].fillna(0).astype(float)
results["EFFORT_HOURS"] = results["EFFORT_HOURS"].astype(float)
results["COMPLEXITY_SCORE"] = results["COMPLEXITY_SCORE"].astype(float)

# ---------------------------------------------------------------- filters
f1, f2, f3 = st.columns(3)
platforms = sorted(results["SOURCE_PLATFORM"].dropna().unique())
domains = sorted(results["BUSINESS_DOMAIN"].dropna().unique())
types = sorted(results["OBJECT_TYPE"].dropna().unique())
sel_platform = f1.multiselect("Source platform", platforms, default=platforms)
sel_domain = f2.multiselect("Business domain", domains, default=domains)
sel_type = f3.multiselect("Object type", types, default=types)

df = results[
    results["SOURCE_PLATFORM"].isin(sel_platform)
    & results["BUSINESS_DOMAIN"].isin(sel_domain)
    & results["OBJECT_TYPE"].isin(sel_type)
].copy()
if df.empty:
    st.info("No objects match the current filters.")
    st.stop()

# ---------------------------------------------------------------- KPIs
total_hours = df["EFFORT_HOURS"].sum()
high_share = df["COMPLEXITY"].isin(["High", "Very High"]).mean() * 100
k1, k2, k3, k4, k5, k6 = st.columns(6)
k1.metric("Objects in scope", f"{len(df):,}")
k2.metric("Effort (hours)", f"{total_hours:,.0f}", help="Sum of EFFORT_HOURS")
k3.metric("Effort (person-days)", f"{total_hours / 8:,.0f}")
k4.metric("High / Very High", f"{high_share:.0f}%")
k5.metric("Data volume", f"{df['SIZE_GB'].sum() / 1024:,.1f} TB")
k6.metric("Retire candidates", int((df["MIGRATION_WAVE"] == 0).sum()))

tab_overview, tab_waves, tab_objects = st.tabs(["Overview", "Wave plan", "Object drill-down"])

# ---------------------------------------------------------------- overview
with tab_overview:
    c1, c2 = st.columns(2)

    mix = df.groupby(["OBJECT_TYPE", "COMPLEXITY"], as_index=False).agg(
        OBJECTS=("FULL_NAME", "count"), EFFORT_HOURS=("EFFORT_HOURS", "sum")
    )
    color_scale = alt.Scale(domain=BANDS, range=BAND_COLORS)
    c1.subheader("Complexity mix by object type")
    c1.altair_chart(
        alt.Chart(mix)
        .mark_bar(cornerRadiusEnd=4, stroke="white", strokeWidth=1)
        .encode(
            y=alt.Y("OBJECT_TYPE:N", title=None, sort="-x"),
            x=alt.X("sum(OBJECTS):Q", title="Objects"),
            color=alt.Color("COMPLEXITY:N", scale=color_scale, sort=BANDS, title="Complexity"),
            order=alt.Order("COMPLEXITY:N"),
            tooltip=["OBJECT_TYPE", "COMPLEXITY", "OBJECTS", alt.Tooltip("EFFORT_HOURS", format=",.0f")],
        )
        .properties(height=320),
        use_container_width=True,
    )

    wave = df.groupby(["MIGRATION_WAVE", "WAVE_NAME", "COMPLEXITY"], as_index=False).agg(
        EFFORT_HOURS=("EFFORT_HOURS", "sum"), OBJECTS=("FULL_NAME", "count")
    )
    c2.subheader("Effort by wave")
    c2.altair_chart(
        alt.Chart(wave)
        .mark_bar(cornerRadiusEnd=4, stroke="white", strokeWidth=1)
        .encode(
            x=alt.X("WAVE_NAME:N", title=None, sort=alt.SortField("MIGRATION_WAVE"),
                    axis=alt.Axis(labelAngle=-20, labelLimit=220)),
            y=alt.Y("sum(EFFORT_HOURS):Q", title="Effort hours"),
            color=alt.Color("COMPLEXITY:N", scale=color_scale, sort=BANDS, title="Complexity"),
            tooltip=["WAVE_NAME", "COMPLEXITY", "OBJECTS", alt.Tooltip("EFFORT_HOURS", format=",.0f")],
        )
        .properties(height=320),
        use_container_width=True,
    )

    st.subheader("Top 10 most complex objects")
    top = df.sort_values("COMPLEXITY_SCORE", ascending=False).head(10)
    st.dataframe(
        top[["FULL_NAME", "OBJECT_TYPE", "COMPLEXITY_SCORE", "COMPLEXITY", "EFFORT_HOURS",
             "WAVE_NAME", "FLAGGED_PATTERNS", "RECOMMENDATION"]],
        use_container_width=True, hide_index=True,
    )

    st.subheader("Recommended approach")
    rec = df.groupby("RECOMMENDATION", as_index=False).agg(
        OBJECTS=("FULL_NAME", "count"), EFFORT_HOURS=("EFFORT_HOURS", "sum")
    ).sort_values("EFFORT_HOURS", ascending=False)
    st.dataframe(rec, use_container_width=True, hide_index=True)

# ---------------------------------------------------------------- wave plan
with tab_waves:
    plan = (
        df.assign(IS_HIGH=df["COMPLEXITY"].isin(["High", "Very High"]).astype(int),
                  IS_TABLE=(df["OBJECT_TYPE"] == "TABLE").astype(int))
        .groupby(["MIGRATION_WAVE", "WAVE_NAME"], as_index=False)
        .agg(OBJECTS=("FULL_NAME", "count"), TABLES=("IS_TABLE", "sum"),
             HIGH_OR_VERY_HIGH=("IS_HIGH", "sum"), DATA_GB=("SIZE_GB", "sum"),
             EFFORT_HOURS=("EFFORT_HOURS", "sum"))
        .sort_values("MIGRATION_WAVE")
    )
    plan["PERSON_DAYS"] = (plan["EFFORT_HOURS"] / 8).round(1)
    team = st.slider("Delivery team size (engineers)", 1, 20, 4)
    plan["CALENDAR_WEEKS"] = (plan["PERSON_DAYS"] / (team * 5)).round(1)
    st.dataframe(plan, use_container_width=True, hide_index=True)
    st.caption("Wave = longest upstream dependency chain; objects in a wave only depend on earlier waves. "
               "Wave 0 = unused objects to retire instead of migrate.")

    for _, w in plan.iterrows():
        members = df[df["MIGRATION_WAVE"] == w["MIGRATION_WAVE"]].sort_values("COMPLEXITY_SCORE", ascending=False)
        with st.expander(f"{w['WAVE_NAME']} - {int(w['OBJECTS'])} objects, {w['EFFORT_HOURS']:,.0f} h"):
            st.dataframe(
                members[["FULL_NAME", "OBJECT_TYPE", "COMPLEXITY", "EFFORT_HOURS",
                         "UPSTREAM_DEPS", "DOWNSTREAM_REFS", "RECOMMENDATION"]],
                use_container_width=True, hide_index=True,
            )

# ---------------------------------------------------------------- drill-down
with tab_objects:
    names = df.sort_values("COMPLEXITY_SCORE", ascending=False)["FULL_NAME"].tolist()
    choice = st.selectbox("Object", names)
    row = df[df["FULL_NAME"] == choice].iloc[0]
    safe_name = choice.replace("'", "''")

    d1, d2, d3, d4 = st.columns(4)
    d1.metric("Complexity", row["COMPLEXITY"], f"score {row['COMPLEXITY_SCORE']:.1f}", delta_color="off")
    d2.metric("Effort (hours)", f"{row['EFFORT_HOURS']:.1f}")
    d3.metric("Wave", row["WAVE_NAME"].split(" - ")[0])
    d4.metric("Size (GB)", f"{row['SIZE_GB']:,.1f}")
    st.write(f"**Recommendation:** {row['RECOMMENDATION']}")

    parts = pd.DataFrame({
        "COMPONENT": ["Object type", "Data types", "Proprietary syntax", "Code size", "Volume", "Dependencies"],
        "POINTS": [row["TYPE_BASE_POINTS"], row["DATATYPE_POINTS"], row["SYNTAX_POINTS"],
                   row["CODE_SIZE_POINTS"], row["VOLUME_POINTS"], row["DEPENDENCY_POINTS"]],
    })
    parts["POINTS"] = parts["POINTS"].astype(float)
    st.subheader("Score breakdown")
    st.altair_chart(
        alt.Chart(parts)
        .mark_bar(cornerRadiusEnd=4, color=SINGLE)
        .encode(y=alt.Y("COMPONENT:N", sort=None, title=None),
                x=alt.X("POINTS:Q", title="Points"),
                tooltip=["COMPONENT", alt.Tooltip("POINTS", format=".1f")])
        .properties(height=220),
        use_container_width=True,
    )

    hits = safe_query(
        f"SELECT RULE_ID, KEYWORD, CATEGORY, HITS, WEIGHTED_POINTS, SNOWFLAKE_APPROACH "
        f"FROM {SCHEMA}.V_SYNTAX_HITS WHERE FULL_NAME = '{safe_name}' ORDER BY WEIGHTED_POINTS DESC"
    )
    cols = safe_query(
        f"SELECT COLUMN_NAME, DATA_TYPE, SNOWFLAKE_TYPE, POINTS, NOTE "
        f"FROM {SCHEMA}.V_COLUMN_TYPE_MAP WHERE FULL_NAME = '{safe_name}' ORDER BY ORDINAL_POSITION"
    )
    if not hits.empty:
        st.subheader("Proprietary syntax found")
        st.dataframe(hits, use_container_width=True, hide_index=True)
    if not cols.empty:
        st.subheader("Column type mapping")
        st.dataframe(cols, use_container_width=True, hide_index=True)

    deps = safe_query(
        f"SELECT 'Depends on' AS DIRECTION, DEPENDS_ON_FULL_NAME AS OBJECT FROM {SCHEMA}.SRC_DEPENDENCIES "
        f"WHERE OBJECT_FULL_NAME = '{safe_name}' UNION ALL "
        f"SELECT 'Used by', OBJECT_FULL_NAME FROM {SCHEMA}.SRC_DEPENDENCIES WHERE DEPENDS_ON_FULL_NAME = '{safe_name}'"
    )
    if not deps.empty:
        st.subheader("Dependencies")
        st.dataframe(deps, use_container_width=True, hide_index=True)

    ai = safe_query(
        f"SELECT PURPOSE, SNOWFLAKE_APPROACH, AI_DIFFICULTY, "
        f"IFF(IS_ARRAY(CONVERSION_RISKS), ARRAY_TO_STRING(CONVERSION_RISKS::ARRAY, '\n- '), "
        f"CONVERSION_RISKS::STRING) AS RISKS, MODEL "
        f"FROM {SCHEMA}.AI_CODE_INSIGHTS WHERE FULL_NAME = '{safe_name}'"
    )
    if not ai.empty:
        a = ai.iloc[0]
        st.subheader(f"AI insight ({a['MODEL']})")
        st.write(f"**Purpose:** {a['PURPOSE']}")
        st.write(f"**AI difficulty:** {a['AI_DIFFICULTY']}  |  **Rule-based:** {row['COMPLEXITY']}")
        if a["RISKS"]:
            st.markdown("**Conversion risks:**\n- " + str(a["RISKS"]))
        st.write(f"**Snowflake approach:** {a['SNOWFLAKE_APPROACH']}")

    code = safe_query(f"SELECT CODE_TEXT FROM {SCHEMA}.SRC_CODE WHERE FULL_NAME = '{safe_name}'")
    if not code.empty:
        with st.expander("Source code"):
            st.code(code.iloc[0]["CODE_TEXT"], language="sql")

with st.expander("All objects (table view)"):
    st.dataframe(df, use_container_width=True, hide_index=True)
