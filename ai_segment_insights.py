"""
RFM Customer Segmentation — AI-Powered Segment Insights
Reads segment_summary.csv (Q12 export from sql/rfm_analysis.sql) and calls the
Gemini API once per segment to generate a plain-English behavior description
and a specific marketing action recommendation. Output feeds the Excel
KPI_Summary sheet and the README's AI-generated insights section.

Prerequisites:
    pip install google-genai pandas python-dotenv

Before running, add this to your .env file (same one used for Postgres):
    GEMINI_API_KEY=your_key_here

Get a free key at aistudio.google.com — click the key icon in the bottom-left
toolbar, or go directly to aistudio.google.com/apikey. No credit card needed.

IMPORTANT: .env must already be in .gitignore — never commit API keys.
"""

import os
import json
import time
import pandas as pd
from google import genai
from google.genai import types
from dotenv import load_dotenv

load_dotenv()

if not os.environ.get("GEMINI_API_KEY"):
    raise ValueError(
        "GEMINI_API_KEY not found. Add it to your .env file in this folder."
    )

client = genai.Client()  # reads GEMINI_API_KEY from environment automatically


OUTPUT_FILE = "segment_ai_insights.csv"


def generate_segment_insight(segment_row: dict) -> dict:
    prompt = f"""You are a CRM analyst. Given this customer segment's RFM profile, write:
1. A one-sentence description of this segment's behavior
2. A specific, actionable marketing recommendation (1-2 sentences)

Segment: {segment_row['segment_name']}
Customer count: {segment_row['customer_count']}
Avg Recency: {segment_row['avg_recency']} days
Avg Frequency: {segment_row['avg_frequency']} orders
Avg Monetary: £{segment_row['avg_monetary']:.2f}
Share of total revenue: {segment_row['revenue_share']:.1f}%

Respond ONLY in this JSON format, no preamble or markdown:
{{"description": "...", "recommendation": "..."}}"""

    response = client.models.generate_content(
        # flash-lite is a separate, typically higher-quota free-tier bucket than plain flash —
        # verify current limits at ai.google.dev/gemini-api/docs/rate-limits before running
        model="gemini-2.5-flash-lite",
        contents=prompt,
        config=types.GenerateContentConfig(
            response_mime_type="application/json",  # forces clean JSON, no markdown fences to strip
        ),
    )
    return json.loads(response.text)


def main():
    segment_summary = pd.read_csv("segment_summary.csv")
    segment_summary.columns = [c.strip().lower() for c in segment_summary.columns]

    # Resume support: load any segments already completed from a previous run,
    # so a quota error never wastes the calls you already spent.
    if os.path.exists(OUTPUT_FILE):
        done_df = pd.read_csv(OUTPUT_FILE)
        done_segments = set(done_df["segment_name"])
        insights = done_df.to_dict("records")
        print(f"Found existing {OUTPUT_FILE} — {len(done_segments)} segments already done, skipping those.")
    else:
        done_segments = set()
        insights = []

    remaining = segment_summary[~segment_summary["segment_name"].isin(done_segments)]
    print(f"Generating AI insights for {len(remaining)} remaining segment(s)...")

    for _, row in remaining.iterrows():
        print(f"  Processing: {row['segment_name']}")
        try:
            result = generate_segment_insight(row.to_dict())
        except Exception as e:
            print(f"  Failed on {row['segment_name']}: {e}")
            print(f"  Stopping here. Progress so far is saved — re-run the script later to pick up where you left off.")
            break

        insights.append({**row.to_dict(), **result})

        # Save after EVERY segment, not just at the end — this is what makes resuming possible.
        pd.DataFrame(insights).to_csv(OUTPUT_FILE, index=False)

        time.sleep(3)  # small gap between calls to avoid bursting the free-tier rate limit

    insights_df = pd.DataFrame(insights)
    print(f"\nSaved: {OUTPUT_FILE} ({len(insights_df)} of {len(segment_summary)} segments)")

    if len(insights_df) < len(segment_summary):
        print("Not all segments completed — re-run the script to continue from here.")

    print("\nPreview:")
    for _, row in insights_df.iterrows():
        print(f"\n{row['segment_name']}:")
        print(f"  {row['description']}")
        print(f"  -> {row['recommendation']}")


if __name__ == "__main__":
    main()