"""Minimal HTML report built from PR_BODY.md when the reporter agent produced no page."""
import html
import json
import os
import sys

iter_dir = sys.argv[1]
env = os.environ
body = ""
title = env.get("PR_TITLE", "")
for name in ("PR_BODY.md",):
    p = os.path.join(iter_dir, name)
    if os.path.exists(p):
        with open(p, encoding="utf-8") as fh:
            body = fh.read()
doc = f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>{html.escape(title)}</title>
<style>body{{font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:50rem;margin:2rem auto;padding:0 1rem;line-height:1.5}}pre{{white-space:pre-wrap}}</style>
</head><body><h1>{html.escape(title)}</h1>
<p>Pull request <a href="{html.escape(env.get('PR_URL',''))}">#{html.escape(env.get('PR_NUMBER',''))}</a>, merged as
<a href="https://github.com/{html.escape(env.get('FORK',''))}/commit/{html.escape(env.get('MERGE_SHA',''))}"><code>{html.escape(env.get('MERGE_SHA','')[:12])}</code></a> on {html.escape(env.get('MERGE_DATE',''))}.</p>
<p><em>The reporter agent did not produce a page; this is the pull request description verbatim.</em></p>
<pre>{html.escape(body)}</pre></body></html>"""
with open(os.path.join(iter_dir, "report.html"), "w", encoding="utf-8") as fh:
    fh.write(doc)
meta = {
    "number": int(env.get("PR_NUMBER", "0") or 0),
    "title": title,
    "pr_url": env.get("PR_URL", ""),
    "page": env.get("REPORT_URL", ""),
    "merge_sha": env.get("MERGE_SHA", ""),
    "date": env.get("MERGE_DATE", ""),
    "iteration": int(env.get("ITER", "0") or 0),
    "summary": "Fallback report generated from the pull request description.",
}
with open(os.path.join(iter_dir, "report-meta.json"), "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=2)
