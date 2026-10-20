"""Render an HTML copy of a proposed, open, or merged PR description."""
import html
import json
import os
import sys
from pathlib import Path


def generate_report(iter_dir, env):
    iter_dir = Path(iter_dir)
    body = (iter_dir / "PR_BODY.md").read_text(encoding="utf-8")
    title = env["PR_TITLE"]
    number = int(env.get("PR_NUMBER", "0") or 0)
    merge_sha = env.get("MERGE_SHA", "")
    state = env.get("PR_STATE") or ("MERGED" if merge_sha else "OPEN" if number else "PREPARING")
    repository = env.get("PR_REPO") or env.get("FORK", "")
    date = env.get("MERGE_DATE", "") if state == "MERGED" else env.get("PR_DATE", "")
    if state == "MERGED" and not merge_sha:
        raise ValueError("a merged report requires a merge commit")
    if number:
        status = f'Pull request <a href="{html.escape(env["PR_URL"], quote=True)}">#{number}</a>'
    else:
        status = "Proposed pull request"
    if state == "MERGED":
        status += (
            f', merged as <a href="https://github.com/{html.escape(repository)}/commit/{html.escape(merge_sha)}">'
            f'<code>{html.escape(merge_sha[:12])}</code></a> on {html.escape(date)}.'
        )
    else:
        status += ". Not merged. CI results are not inferred from local verification."
    doc = f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>{html.escape(title)}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>:root{{color-scheme:light dark}}body{{font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:50rem;margin:2rem auto;padding:0 1rem;line-height:1.5}}pre{{white-space:pre-wrap;overflow-wrap:anywhere}}</style>
</head><body><h1>{html.escape(title)}</h1>
<p>{status}</p>
<p><em>This is an HTML copy of the pull request description. See the PR for the latest check status.</em></p>
<pre>{html.escape(body)}</pre></body></html>"""
    (iter_dir / "report.html").write_text(doc, encoding="utf-8")
    meta = {
        "number": number,
        "title": title,
        "pr_url": env.get("PR_URL", ""),
        "page": env.get("REPORT_URL", ""),
        "merge_sha": merge_sha,
        "date": date,
        "iteration": int(env.get("ITER", "0") or 0),
        "summary": "HTML description of the pull request.",
        "state": state,
        "head_sha": env.get("CHANGE_SHA", ""),
        "repository": repository,
    }
    (iter_dir / "report-meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")


if __name__ == "__main__":
    generate_report(sys.argv[1], os.environ)
