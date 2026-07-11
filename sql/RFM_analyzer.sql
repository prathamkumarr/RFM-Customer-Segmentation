-- ============================================================
-- RFM Customer Segmentation — Full SQL Analysis
-- Run this against the 'transactions' table loaded by
-- python/load_data_postgres.py. Everything below — RFM
-- computation, scoring, segmentation, and the 12 business
-- questions — runs entirely in SQL from that single table.
-- ============================================================


-- ------------------------------------------------------------
-- SETUP: Build the RFM-scored view
-- ------------------------------------------------------------
-- Computes Recency/Frequency/Monetary per customer directly from
-- transactions, scores each on a 1-5 scale via NTILE(5), and maps
-- the score combination to a named segment. Defined as a VIEW (not
-- a stored table) so it always reflects the current transactions data.

CREATE OR REPLACE VIEW RFM_SCORED AS
WITH
	CUSTOMER_METRICS AS (
		SELECT
			CUSTOMER_ID,
			MAX(INVOICE_DATE) AS LAST_PURCHASE_DATE,
			COUNT(DISTINCT INVOICE) AS FREQUENCY,
			SUM(REVENUE) AS MONETARY
		FROM
			TRANSACTIONS
		GROUP BY
			CUSTOMER_ID
	),
	SNAPSHOT AS (
		SELECT
			MAX(INVOICE_DATE) + INTERVAL '1 day' AS SNAPSHOT_DATE
		FROM
			TRANSACTIONS
	),
	RFM_BASE AS (
		SELECT
			CM.CUSTOMER_ID,
			(
				S.SNAPSHOT_DATE::DATE - CM.LAST_PURCHASE_DATE::DATE
			) AS RECENCY,
			CM.FREQUENCY,
			CM.MONETARY
		FROM
			CUSTOMER_METRICS CM
			CROSS JOIN SNAPSHOT S
	),
	RFM_SCORES AS (
		SELECT
			CUSTOMER_ID,
			RECENCY,
			FREQUENCY,
			MONETARY,
			-- Recency: LOWER days = BETTER, so DESC order gives days=1 the top score
			NTILE(5) OVER (
				ORDER BY
					RECENCY DESC
			) AS R_SCORE,
			-- Frequency & Monetary: HIGHER = BETTER, so ASC order gives the max value the top score
			NTILE(5) OVER (
				ORDER BY
					FREQUENCY ASC
			) AS F_SCORE,
			NTILE(5) OVER (
				ORDER BY
					MONETARY ASC
			) AS M_SCORE
		FROM
			RFM_BASE
	)
SELECT
	CUSTOMER_ID,
	RECENCY,
	FREQUENCY,
	MONETARY,
	R_SCORE,
	F_SCORE,
	M_SCORE,
	(R_SCORE + F_SCORE + M_SCORE) AS RFM_TOTAL_SCORE,
	(R_SCORE::TEXT || F_SCORE::TEXT || M_SCORE::TEXT) AS RFM_CELL,
	CASE
		WHEN R_SCORE >= 4
		AND F_SCORE >= 4 THEN 'Champions'
		WHEN R_SCORE >= 3
		AND F_SCORE >= 4 THEN 'Loyal Customers'
		WHEN R_SCORE >= 4
		AND F_SCORE BETWEEN 2 AND 3  THEN 'Potential Loyalists'
		WHEN R_SCORE >= 4
		AND F_SCORE = 1 THEN 'New Customers'
		WHEN R_SCORE = 3
		AND F_SCORE <= 3 THEN 'Promising'
		WHEN R_SCORE = 2
		AND F_SCORE BETWEEN 2 AND 3  THEN 'Needs Attention'
		WHEN R_SCORE = 2
		AND F_SCORE <= 1 THEN 'About To Sleep'
		WHEN R_SCORE <= 2
		AND F_SCORE >= 4
		AND M_SCORE >= 4 THEN 'Cant Lose Them'
		WHEN R_SCORE <= 2
		AND F_SCORE >= 3 THEN 'At Risk'
		WHEN R_SCORE <= 2
		AND F_SCORE <= 2
		AND M_SCORE >= 3 THEN 'Hibernating'
		ELSE 'Lost'
	END AS SEGMENT
FROM
	RFM_SCORES;


-- -------------------------------------------------------------
-- VALIDATION: Confirm the segmentation is sound before using it
-- -------------------------------------------------------------
--
-- Every customer should get exactly one segment, with zero NULLs,
-- and all 11 segments in the taxonomy should be populated.
SELECT
	COUNT(*) AS TOTAL_CUSTOMERS,
	COUNT(SEGMENT) AS CUSTOMERS_WITH_SEGMENT,
	COUNT(DISTINCT SEGMENT) AS DISTINCT_SEGMENTS
FROM
	RFM_SCORED;
--
-- Result: 5,853 = 5,853, 11 distinct segments. Validation check passed —
-- all 5,853 customers received exactly one segment label (0 NULLs), and
-- all 11 segments in the taxonomy are populated (no empty or unreachable
-- buckets). The R/F score-based CASE logic is confirmed mutually
-- exclusive and collectively exhaustive for this dataset.


-- ============================================================
-- METHODOLOGY & SCOPE — read before the business queries below
-- ============================================================
--
-- Data source: 'transactions' table (776,830 cleaned rows, 5,853
-- customers), loaded from Phase 1's online_retail_clean.csv.
--
-- RFM computation: Recency, Frequency, and Monetary are computed
-- directly from `transactions` inside the rfm_scored view — not
-- pre-calculated in Python — so the view always reflects the
-- current state of the transactions table.
--
-- Scoring: each metric is split into 5 quintiles via NTILE(5).
-- Frequency and Monetary are scored ascending (higher value =
-- score 5); Recency is scored descending (fewer days since last
-- purchase = score 5) — the scoring direction is intentionally
-- flipped for Recency since "lower is better" there.
--
-- Segmentation: the 11-segment taxonomy (Champions, Loyal
-- Customers, Potential Loyalists, New Customers, Promising,
-- Needs Attention, About To Sleep, At Risk, Cant Lose Them,
-- Hibernating, Lost) is assigned via a CASE statement on the R
-- and F scores, with M as a tiebreaker for the two segments
-- where value matters most (Cant Lose Them vs. At Risk, and
-- Hibernating vs. Lost). Validated MECE against all 5,853
-- customers — see the validation check above.
--
-- The 12 queries below are grouped into four sections:
--   Section 1 (Q1-Q3)   Segment Overview
--   Section 2 (Q4-Q6)   Actionable Customer Lists
--   Section 3 (Q7-Q8)   Revenue-at-Risk & Growth Sizing
--   Section 4 (Q9-Q12)  Cross-Cuts for Tableau/Excel & Exports
-- ============================================================


-- ===========================
-- SECTION 1: SEGMENT OVERVIEW
-- ===========================

-- Q1: How many customers fall into each segment, and what share of the
-- customer base does each represent?
SELECT
	SEGMENT,
	COUNT(*) AS CUSTOMER_COUNT,
	ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS PCT_OF_CUSTOMERS
FROM
	RFM_SCORED
GROUP BY
	SEGMENT
ORDER BY
	CUSTOMER_COUNT DESC;
--
-- KEY INSIGHTS:
-- Champions is the largest segment (1,462 customers, 25.0%), followed by Lost (761, 13.0%). 
-- The relatively large Champions share reflects how NTILE(5) scoring works
-- — it requires only the top 40% on both Recency and Frequency, 
-- so a meaningful customer overlap is expected rather than anomalous. 
-- The 761 Lost customers represent a real churn cohort, 
-- though their business impact depends on how little revenue they hold — addressed next in Q2.


-- =====================================================================
-- Q2: How much revenue does each segment contribute, and what % of total
-- revenue is that? (the core "who actually matters" question)
SELECT
	SEGMENT,
	COUNT(*) AS CUSTOMER_COUNT,
	ROUND(SUM(MONETARY), 2) AS TOTAL_REVENUE,
	ROUND(
		100.0 * SUM(MONETARY) / SUM(SUM(MONETARY)) OVER (),
		2
	) AS PCT_OF_REVENUE
FROM
	RFM_SCORED
GROUP BY
	SEGMENT
ORDER BY
	TOTAL_REVENUE DESC;
--
-- KEY INSIGHTS:
-- Champions = 25% of customers but 68.97% of revenue (£11.78M) — extreme concentration
-- Top 3 value segments (Champions + Loyal + Cant Lose Them = 38% of customers) - 84.4% of revenue
-- Lost segment is large by count (761, 13%) but contributes just 1.08% of revenue — low business risk despite size
-- Combined "at-risk" revenue (At Risk + Cant Lose Them + Hibernating) ≈ £1.39M, 8.15% of total — this is the number Q7 isolates directly
-- New Customers contribute only 0.39% of revenue — expected, since it's first-purchase-only by definition
-- Revenue total across all 11 rows reconciles exactly to £17,081,859.77 (Phase 1 total) — confirms no leakage in the segmentation


-- ===================================================================
-- Q3: What's the average R/F/M profile of each segment? Sanity-checks
-- that the segment labels actually describe the behavior they claim to.
SELECT
	SEGMENT,
	ROUND(AVG(RECENCY), 1) AS AVG_RECENCY_DAYS,
	ROUND(AVG(FREQUENCY), 1) AS AVG_FREQUENCY,
	ROUND(AVG(MONETARY), 2) AS AVG_MONETARY
FROM
	RFM_SCORED
GROUP BY
	SEGMENT
ORDER BY
	AVG_MONETARY DESC;
--
-- KEY INSIGHTS:
-- Ranking by avg_monetary confirms the segment labels behave as intended:
--   Champions: lowest recency (20.4 days), highest frequency (15.6), highest monetary (£8,058) — textbook profile
--   Lost: highest recency (560.1 days), near-lowest frequency (1.1), lowest monetary (£242.57) — opposite extreme, as expected
-- Cant Lose Them (£3,943 avg) vs Loyal Customers (£3,281 avg): Cant Lose Them customers were
--   individually MORE valuable on average despite being inactive (344.7 days) — confirms these are
--   worth the win-back effort, not just noise in the "at risk" bucket
-- Hibernating (£1,339.52 avg) sits ABOVE Potential Loyalists, At Risk, Needs Attention, and Promising
--   despite low R and F scores — this is the m_score >= 3 tiebreaker in the CASE logic working as
--   designed: it's deliberately separating higher-value dormant customers (Hibernating) from
--   low-value dormant customers (Lost), rather than lumping all inactive low-frequency buyers together
-- New Customers (freq = 1.0 exactly) vs About To Sleep (freq = 1.0, recency 318.9 vs 29.9):
--   near-identical purchase behavior, differing only by how much time has passed — About To Sleep
--   is what an unconverted New Customer becomes if there's no second purchase
-- Note: this ranking (by AVERAGE monetary per customer) differs from Q2's ranking (by TOTAL revenue
--   contribution) — Loyal Customers has a lower average (£3,281) than Cant Lose Them (£3,943) but a
--   higher total revenue share (9.91% vs 5.49%) simply because there are more of them (516 vs 238)


-- ====================================
-- SECTION 2: ACTIONABLE CUSTOMER LISTS
-- ====================================
--
-- Q4: Who are the top 20 highest-value Champions? (VIP / loyalty-program list)
SELECT
	CUSTOMER_ID,
	RECENCY,
	FREQUENCY,
	MONETARY
FROM
	RFM_SCORED
WHERE
	SEGMENT = 'Champions'
ORDER BY
	MONETARY DESC
LIMIT
	20;
--
-- KEY INSIGHTS:
-- #1 customer (18102): £580,987.04, recency=1 day — this is the single highest-spending customer
--   in the ENTIRE dataset (matches the £580,987.04 max from the Phase 1 Monetary sanity check),
--   and they're also the most recently active. True #1 VIP.
-- Customer 14911: frequency=375 — the highest order count in the entire dataset (matches Phase 1's
--   max Frequency of 375). Different kind of Champion: less about basket size, more about sheer
--   repeat-purchase volume — likely a wholesale/reseller account given the earlier dataset context.
-- Top 20 combined revenue ≈ £3,656,909 — that's ~21.4% of TOTAL company revenue (£17.08M) coming
--   from just 20 customers (0.34% of the 5,853 customer base)
-- Within Champions specifically: these 20 (out of 1,462 Champions) account for ~31% of the
--   segment's £11.78M total — concentration exists even inside the "already concentrated" segment
-- Recency across this list ranges only 1-39 days — confirms these aren't just historically
--   high-spenders who happen to score well, they're genuinely active right now
-- Frequency varies widely (24 to 375) — value is being driven by two distinct patterns:
--   high-frequency/moderate-basket buyers (14911: 375 orders) vs. low-frequency/huge-basket
--   buyers (12415: only 24 orders, still ranks #9) — worth segmenting further if there's time
--   for a stretch goal (e.g. flagging likely wholesale accounts by frequency+basket size)


-- ================================================================
-- Q5: Which "Cant Lose Them" customers (previously high-value, now
-- inactive) should be prioritized first for win-back campaigns?
SELECT
	CUSTOMER_ID,
	RECENCY,
	FREQUENCY,
	MONETARY
FROM
	RFM_SCORED
WHERE
	SEGMENT = 'Cant Lose Them'
ORDER BY
	MONETARY DESC
LIMIT
	20;
--
-- KEY INSIGHTS:
-- Top 20 combined monetary value ≈ £395,708 — that's 42.2% of the ENTIRE Cant Lose Them
--   segment's revenue (£938,452 from Q2) sitting in just 20 of 238 customers (8.4% of the
--   segment) — even more concentrated than the Champions top-20 (which held ~31% of its segment)
-- Customer 17850 is the standout anomaly: frequency=155 — nearly 10x the Cant Lose Them
--   segment average (8.9 from Q3) and comparable to Champions' average frequency of 15.6.
--   This isn't a typical lapsed customer — the purchase history reads like a former Champion
--   who went completely dark 373 days ago. Highest-priority single win-back target on the list.
-- Customer 16754 is highest by pure value (£65,500.07) but more "typical" of this segment —
--   moderate frequency (29), recency (373 days) in line with the group
-- Longest-dormant customers on this list — 14063 (687 days) and 14160 (611 days) — have
--   noticeably lower monetary (£9,471 and £8,421) than the top of the list, suggesting win-back
--   ROI drops off as dormancy length increases, even within a segment already defined as "at risk"
-- Recency spread across this list (197-687 days) is wide — this isn't one homogeneous group;
--   customers 197-291 days out are far more recoverable than those past 600+ days
-- Practical takeaway for the README: prioritize the win-back list by a combination of value
--   AND recency together, not monetary alone — 17850 (high freq, moderate recency) and 16754
--   (highest value, moderate recency) are stronger bets than the 600+ day dormant customers
--   even though all three technically qualify for the same segment


-- =====================================================================
-- Q6: Which "Promising" / "Potential Loyalist" customers are closest to
-- becoming Loyal/Champion — good upsell targets?
SELECT
	CUSTOMER_ID,
	RECENCY,
	FREQUENCY,
	MONETARY,
	R_SCORE,
	F_SCORE,
	M_SCORE
FROM
	RFM_SCORED
WHERE
	SEGMENT IN ('Promising', 'Potential Loyalists')
ORDER BY
	MONETARY DESC
LIMIT
	20;
--
-- KEY INSIGHTS:
-- Striking pattern: EVERY row in this top-20 list has m_score = 5 (top monetary quintile),
--   despite frequency being consistently low (1-4 orders, vs. Champions' avg of 15.6).
--   These are big one-time/few-time spenders, not developing repeat buyers.
-- Customer 16446 is the standout case: recency=1 day, monetary=£168,472.50 (the 2nd-highest
--   single-customer value seen across the whole analysis so far, after Champion 18102's
--   £580,987), yet only frequency=2 orders. Excluded from Champions purely because f_score=2
--   falls short of the >=4 threshold required — despite being nearly as valuable as a top Champion.
-- This exposes a real structural edge case in R/F-based segmentation: a customer who places
--   one or two enormous orders scores identically on "engagement" (frequency) to someone who
--   places two tiny orders, even though their business value is completely different.
--   Pure monetary-tier customers like this get bucketed with much lower-value "Promising"
--   customers rather than recognized as high-value in their own right.
-- Business implication: this list isn't really "upsell candidates approaching Loyal status" —
--   it's closer to "big-ticket / possible wholesale buyers who haven't repeat-ordered yet."
--   A repeat-purchase incentive (discount on 2nd/3rd order) fits this group better than a
--   standard loyalty-program upsell pitch.
-- Worth flagging as a documented limitation in the README: segment labels here describe
--   R/F/M *scoring patterns*, not business intent — some segments (like this one) contain
--   customers whose real profile diverges from what the label implies.


-- ==========================================
-- SECTION 3: REVENUE-AT-RISK & GROWTH SIZING
-- ==========================================
-- 
-- Q7: How much revenue sits in "at risk" segments (At Risk, Cant Lose
-- Them, Hibernating) — i.e. revenue that could be lost without intervention?
SELECT
	ROUND(SUM(MONETARY), 2) AS REVENUE_AT_RISK,
	ROUND(
		100.0 * SUM(MONETARY) / (
			SELECT
				SUM(MONETARY)
			FROM
				RFM_SCORED
		),
		2
	) AS PCT_OF_TOTAL_REVENUE,
	COUNT(*) AS CUSTOMERS_AT_RISK
FROM
	RFM_SCORED
WHERE
	SEGMENT IN ('At Risk', 'Cant Lose Them', 'Hibernating');
-- 
-- KEY INSIGHTS:
-- £1,392,275.06 at risk across 675 customers (11.5% of the 5,853 customer base) — but only
--   8.15% of total revenue. Cross-checks exactly against Q2: At Risk (£279,685.41) +
--   Cant Lose Them (£938,452.21) + Hibernating (£174,137.44) = £1,392,275.06. No leakage.
-- This is the single most important number for the README's "why this matters" framing —
--   it converts three abstract segment names into one concrete, defensible dollar figure a
--   business stakeholder can act on: "protect this ~£1.39M before it's fully lost"
-- Cant Lose Them alone is 67.4% of this total (£938,452 of £1,392,275) despite being the
--   smallest of the three segments by customer count (238 vs. 307 At Risk, 130 Hibernating) —
--   confirms the win-back priority list from Q5 is targeting the right group; effort should
--   concentrate there first, not spread evenly across all 675 at-risk customers
-- Contrast with Q1's "Lost" segment (761 customers, 13% of base) which sits OUTSIDE this
--   at-risk figure entirely — Lost customers are, by design, no longer considered recoverable
--   (m_score < 3), so this £1.39M represents genuinely salvageable revenue, not the full
--   churned customer base
-- Sizing check: £1.39M at risk vs. £11.78M in Champions (Q2) — at-risk revenue is roughly
--   11.8% the size of the healthy core, a proportion worth stating explicitly so the risk
--   figure doesn't get read as scarier than it actually is relative to the business's core value


-- ==============================================================
-- Q8: How many New Customers are there, and what's their average
-- first-purchase value? (sizes the onboarding/nurture campaign)
SELECT
	COUNT(*) AS NEW_CUSTOMER_COUNT,
	ROUND(AVG(MONETARY), 2) AS AVG_MONETARY,
	ROUND(SUM(MONETARY), 2) AS TOTAL_REVENUE
FROM
	RFM_SCORED
WHERE
	SEGMENT = 'New Customers';
--
-- KEY INSIGHTS:
-- 167 New Customers, £66,951.15 total revenue, £400.91 average first-purchase value.
-- Cross-checks cleanly: matches Q2's New Customers row (167 customers, £66,951.15, 0.39% of
--   total revenue) and Q3's avg_monetary (£400.91) exactly — no drift across three
--   independent queries touching this segment.
-- Smallest segment in the entire taxonomy by both customer count (167 vs. next-smallest
--   Hibernating at 130) and revenue share (0.39%, lowest of all 11 segments per Q2) —
--   expected, since "New Customer" by definition means exactly one purchase made recently
-- £400.91 avg first-purchase value vs. Champions' £8,058.32 avg (Q3) — a ~20x gap between
--   a brand-new customer's first order and an established Champion's typical spend. This gap
--   is the entire business case for a nurture/onboarding campaign: closing even a fraction
--   of it through a strong second-purchase incentive would materially grow this segment's value
-- Sizing implication: at only 167 customers, this is a small, easily-targeted list for a
--   welcome-series or second-purchase-discount campaign — low operational cost relative to
--   the other at-risk campaigns (675 customers) already identified in Q7


-- =================================================
-- SECTION 4: CROSS-CUTS FOR TABLEAU/EXCEL & EXPORTS
-- =================================================
-- 
-- Q9: How does segment composition differ across the top 5 countries
-- by customer count?
WITH
	TOP_COUNTRIES AS (
		SELECT
			COUNTRY
		FROM
			TRANSACTIONS
		GROUP BY
			COUNTRY
		ORDER BY
			COUNT(DISTINCT CUSTOMER_ID) DESC
		LIMIT
			5
	)
SELECT
	T.COUNTRY,
	R.SEGMENT,
	COUNT(DISTINCT R.CUSTOMER_ID) AS CUSTOMER_COUNT
FROM
	RFM_SCORED R
	JOIN TRANSACTIONS T ON R.CUSTOMER_ID = T.CUSTOMER_ID
WHERE
	T.COUNTRY IN (
		SELECT
			COUNTRY
		FROM
			TOP_COUNTRIES
	)
GROUP BY
	T.COUNTRY,
	R.SEGMENT
ORDER BY
	T.COUNTRY,
	CUSTOMER_COUNT DESC;
--
-- KEY INSIGHTS:
-- United Kingdom = 5,334 of the 5,602 customers across these 5 countries (95.2%) and 91.1%
--   of the ENTIRE 5,853 customer base — this single market effectively IS the dataset,
--   consistent with the UK revenue dominance already observed in Phase 1 EDA
-- Because UK is such a large share, its segment mix (Champions 25.1%, Lost 13.4%, Potential
--   Loyalists 11.9%...) is nearly identical to the overall Q1 percentages (25.0%, 13.0%,
--   12.2%...) — the other 4 countries barely move the aggregate numbers at all
-- Germany is the only non-UK market with ALL 11 segments populated (107 customers spread
--   across every segment, including 2 Cant Lose Them) — the next most "complete" market
--   after the UK in terms of customer lifecycle depth
-- Belgium (29 customers), France (94), and Spain (38) all show ZERO "Cant Lose Them"
--   customers except France/Spain having small counts — this segment (high-value + dormant)
--   appears to require a large enough customer base to statistically occur; only UK (223)
--   and Germany (2) have meaningful counts
-- Revenue-at-risk concentration check: UK holds 223 of 238 total Cant Lose Them customers
--   (93.7%), 291 of 307 At Risk (94.8%), and 107 of 130 Hibernating (82.3%) — meaning
--   essentially ALL of Q7's £1.39M at-risk revenue is a UK-market problem, not international
-- Practical takeaway: any win-back or retention campaign (from Q5) should be built assuming
--   a UK-centric customer base and operating hours/currency — international segments are too
--   small individually to warrant separate campaign strategies at this data volume


-- ========================================================
-- Q10: Which segments have the highest average order value
-- (Monetary / Frequency), independent of how often they buy?
SELECT
	SEGMENT,
	ROUND(AVG(MONETARY / NULLIF(FREQUENCY, 0)), 2) AS AVG_ORDER_VALUE
FROM
	RFM_SCORED
GROUP BY
	SEGMENT
ORDER BY
	AVG_ORDER_VALUE DESC;
-- 
-- KEY INSIGHTS:
-- Counterintuitive result: Champions rank only 4th (£412.78), while Hibernating tops the
--   list (£991.22) — the OPPOSITE of what Q2/Q3's total-value ranking would suggest
-- Root cause: this metric is AVG(monetary/frequency) computed PER CUSTOMER, then averaged
--   across the segment — not segment total monetary / segment total frequency. A single
--   customer with low frequency and one unusually large order produces a huge individual
--   ratio that pulls the segment average up, even if most customers in that segment are
--   ordinary. This is the same distortion effect flagged in Q6 (e.g. customer 16446:
--   monetary=£168,472, frequency=2 → ratio ≈ £84,236 for that one customer alone)
-- Champions' relatively LOW rank here is actually consistent behavior, not an anomaly:
--   avg_frequency=15.6 (Q3) means Champions spread spending across many smaller orders,
--   which mechanically produces a lower per-order ratio than a segment dominated by a few
--   big one-off purchases — high total value, but not high "value per transaction"
-- Practical distinction to state clearly in the README: this query answers "which segments
--   contain big single-purchase outliers" rather than "which segments have the highest
--   typical basket size" — a median-based version of this query would likely tell a very
--   different, more representative story
-- Lost customers correctly rank last (£220.34) — no contradiction there; both low frequency
--   AND low monetary, so no outlier-inflation effect to offset the low baseline


-- =============================================================
-- Q11: R-score vs F-score customer-count grid — feeds a heatmap
-- visualization in the Tableau dashboard.
SELECT
	R_SCORE,
	F_SCORE,
	COUNT(*) AS CUSTOMER_COUNT,
	ROUND(AVG(MONETARY), 2) AS AVG_MONETARY
FROM
	RFM_SCORED
GROUP BY
	R_SCORE,
	F_SCORE
ORDER BY
	R_SCORE DESC,
	F_SCORE DESC;
--
-- KEY INSIGHTS:
-- The two "pure corner" cells are the largest single groups in the entire 25-cell grid:
--   r=5,f=5 (575 customers, avg £14,477.20) — the true Champions core, highest avg by far
--   r=1,f=1 (535 customers, avg £328.33) — the true Lost core, lowest avg in the grid
-- Together these two corners alone account for 1,110 of 5,853 customers (19%) — confirms
--   the customer base is genuinely bimodal (strongly engaged or strongly disengaged), not
--   a smooth continuum, which validates using discrete segments rather than a single score
-- Non-monotonic anomaly worth flagging: within the r=5 row, avg_monetary does NOT decrease
--   smoothly as f_score drops — f=2 (£2,181.32) is actually HIGHER than f=3 (£1,041.84).
--   Same outlier-inflation pattern seen in Q6/Q10: a handful of recently-active, low-frequency,
--   large single-purchase customers are skewing that one cell's average upward
-- Similarly, r=2,f=5 (58 customers, £7,598.67) has a HIGHER average than r=4,f=5 (317
--   customers, £7,066.01) — meaning some dormant-but-historically-frequent customers carry
--   more value than recently-active frequent ones. Small cell size (58) makes this more
--   susceptible to outlier distortion than the larger, more stable cells
-- Surprising low point: r=5,f=1 (54 customers, £290.69) scores LOWER than r=1,f=1 (535
--   customers, £328.33) — customers who are both recent AND infrequent (likely first-time
--   buyers who just arrived) spend less on average than long-dormant minimal-frequency
--   customers. Reinforces the New Customers vs. Lost distinction from Q3/Q8: newness alone
--   doesn't predict value, only future behavior does
-- This exact table (r_score, f_score, customer_count, avg_monetary) is Tableau-ready as-is
--   for a heatmap: r_score/f_score as the two axes, customer_count as cell size/color intensity


-- ==================================================================
-- Q12: Full segment summary — export this one as segment_summary.csv.
-- This is the exact input for the Excel KPI_Summary sheet AND the
-- AI segment-insights feature (see ai_segment_insights.py).
SELECT
    segment AS segment_name,
    COUNT(*) AS customer_count,
    ROUND(AVG(recency), 1) AS avg_recency,
    ROUND(AVG(frequency), 1) AS avg_frequency,
    ROUND(AVG(monetary), 2) AS avg_monetary,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 2) AS revenue_share
FROM rfm_scored
GROUP BY segment
ORDER BY revenue_share DESC;
-- 
-- KEY INSIGHTS:
-- Final reconciliation checks — both pass exactly:
--   customer_count sums to 5,853 (1462+516+238+711+655+600+307+761+130+306+167) — matches
--     total customer base with zero drift across all prior queries
--   revenue_share sums to 99.99% (rounding only) — confirms every dollar is accounted for
--     across the 11 segments with no double-counting or leakage
-- This table is the single-source summary of the entire analysis — every number in it has
--   already been independently verified against Q1 (counts), Q2 (revenue), and Q3 (RFM
--   profile), so it can be trusted as the canonical reference for the README and dashboards
-- Ranked by revenue_share, the top 3 segments (Champions, Loyal Customers, Cant Lose Them)
--   account for 84.37% of revenue from just 38.7% of customers (1462+516+238=2216 of 5853)
--   — the cleanest single statement of the Pareto pattern that's run through this entire
--   analysis, from Phase 1's raw 77.2% top-20%-of-customers finding through to here
-- This is the exact table to export as segment_summary.csv — it's the direct input for:
--   1. The Excel KPI_Summary sheet (Phase 3)
--   2. The ai_segment_insights.py script from the project brief — these 6 columns
--      (segment_name, customer_count, avg_recency, avg_frequency, avg_monetary, revenue_share)
--      map exactly to what that script's prompt template expects per segment
