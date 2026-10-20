"""Build index.html for the gh-pages report site from reports/*.json metadata."""
import glob
import html
import json
import os
import sys

pages = sys.argv[1]
metas = []
for path in glob.glob(os.path.join(pages, "reports", "**", "*.json"), recursive=True):
    try:
        with open(path, encoding="utf-8") as fh:
            metas.append(json.load(fh))
    except Exception:
        pass
metas.sort(key=lambda m: -int(m.get("number", 0) or 0))

rows = []
for m in metas:
    n = html.escape(str(m.get("number", "")))
    page = html.escape(str(m.get("page") or f"reports/pr-{n}.html"), quote=True)
    state = html.escape(str(m.get("state", "MERGED")))
    rows.append(
        "<tr>"
        f'<td><a href="{page}">#{n}</a></td>'
        f'<td>{html.escape(str(m.get("title", "")))}</td>'
        f'<td>{html.escape(str(m.get("date", ""))[:10])}</td>'
        f'<td>{state}</td>'
        f'<td>{html.escape(str(m.get("summary", "")))}</td>'
        f'<td><a href="{html.escape(str(m.get("pr_url", "")))}">PR</a></td>'
        "</tr>"
    )
if not rows:
    rows.append('<tr><td colspan="6">No reports yet.</td></tr>')

doc = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Z3 to Lean certificate loop: PR reports</title>
<style>
:root {{ color-scheme: light dark; --fg: #1b1f23; --bg: #ffffff; --muted: #57606a; --line: #d0d7de; --link: #0a5bd6; }}
@media (prefers-color-scheme: dark) {{ :root {{ --fg: #e6edf3; --bg: #0d1117; --muted: #9da7b3; --line: #30363d; --link: #74b0ff; }} }}
body {{ font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; color: var(--fg); background: var(--bg); margin: 0; padding: 2rem 1rem; }}
main {{ max-width: 60rem; margin: 0 auto; }}
h1 {{ font-size: 1.6rem; margin-bottom: .25rem; }}
p.lead {{ color: var(--muted); margin-top: 0; }}
table {{ border-collapse: collapse; width: 100%; margin-top: 1.5rem; }}
th, td {{ text-align: left; padding: .5rem .6rem; border-bottom: 1px solid var(--line); vertical-align: top; }}
th {{ font-weight: 600; color: var(--muted); font-size: .9rem; }}
a {{ color: var(--link); text-decoration: none; }} a:hover {{ text-decoration: underline; }}
</style></head><body><main>
<h1>Z3 &rarr; Lean certificate improvement loop</h1>
<p class="lead">High-level reports for open and merged pull requests from the automated implement / review / integrate loop.</p>
<table><thead><tr><th>PR</th><th>Title</th><th>Date</th><th>Status</th><th>Summary</th><th></th></tr></thead>
<tbody>{''.join(rows)}</tbody></table>
</main></body></html>
"""
with open(os.path.join(pages, "index.html"), "w", encoding="utf-8") as fh:
    fh.write(doc)
