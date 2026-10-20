import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.fallback_report import generate_report
from tools.report_body import with_report_links

ROOT = Path(__file__).resolve().parents[1]


class ReportTests(unittest.TestCase):
    def test_open_report_does_not_claim_a_merge(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "PR_BODY.md").write_text("A < B & C", encoding="utf-8")
            generate_report(path, {
                "PR_TITLE": "Fix <checker>",
                "PR_NUMBER": "23",
                "PR_URL": "https://github.com/owner/fork/pull/23",
                "PR_DATE": "2026-10-20",
                "CHANGE_SHA": "abc",
            })
            doc = (path / "report.html").read_text(encoding="utf-8")
            self.assertIn("Not merged", doc)
            self.assertNotIn("merged as", doc)
            self.assertIn("A &lt; B &amp; C", doc)
            meta = json.loads((path / "report-meta.json").read_text())
            self.assertEqual((meta["state"], meta["merge_sha"], meta["head_sha"]), ("OPEN", "", "abc"))

    def test_merged_report_keeps_actual_merge_details(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "PR_BODY.md").write_text("Description", encoding="utf-8")
            generate_report(path, {
                "PR_TITLE": "Fix",
                "PR_NUMBER": "23",
                "PR_URL": "https://github.com/owner/upstream/pull/23",
                "PR_REPO": "owner/upstream",
                "MERGE_SHA": "abcdef",
                "MERGE_DATE": "2026-10-20",
            })
            doc = (path / "report.html").read_text()
            self.assertIn("merged as", doc)
            self.assertIn("https://github.com/owner/upstream/commit/abcdef", doc)
            self.assertIn("2026-10-20", doc)

    def test_report_link_refresh_preserves_the_description(self):
        original = "## Summary\n\nKeep this.\n\nGenerated footer.\n"
        body = with_report_links(original, "https://pages/old.html", "https://source/old.html")
        body += "\n## CI fix\n\nKeep this too.\n"
        updated = with_report_links(body, "https://pages/new.html", "https://source/new.html")
        self.assertIn(original, updated)
        self.assertIn("Keep this too.", updated)
        self.assertNotIn("old.html", updated)
        self.assertEqual(updated.count("<!-- loop-html-report -->"), 1)

    def test_incomplete_report_link_section_is_rejected(self):
        with self.assertRaises(ValueError):
            with_report_links("Description\n<!-- loop-html-report -->", "page", "source")

    def test_index_includes_open_upstream_and_historical_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            reports = Path(directory) / "reports"
            (reports / "upstream").mkdir(parents=True)
            (reports / "pr-1.json").write_text(json.dumps({"number": 1, "title": "Old"}))
            (reports / "upstream/pr-23.json").write_text(json.dumps({
                "number": 23, "title": "New", "state": "OPEN",
                "page": "https://pages/reports/upstream/pr-23.html",
            }))
            subprocess.run(["python3", str(ROOT / "tools/make_index.py"), directory], check=True)
            doc = (Path(directory) / "index.html").read_text()
            self.assertIn('href="https://pages/reports/upstream/pr-23.html"', doc)
            self.assertIn('href="reports/pr-1.html"', doc)
            self.assertIn("OPEN", doc)
            self.assertIn("MERGED", doc)


class OpeningFlowTests(unittest.TestCase):
    def run_flow(self, *, fail_publication=False, existing=False, upstream=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "PR_BODY.md").write_text("## Summary\n\nChange description.", encoding="utf-8")
            env = dict(os.environ, LOOP_DIR=str(ROOT), ITER_DIR=directory,
                       FAIL_PUBLICATION=str(int(fail_publication)), EXISTING=str(int(existing)),
                       TARGET="owner/upstream" if upstream else "owner/fork",
                       HEAD="owner:loop/iter-23" if upstream else "loop/iter-23")
            result = subprocess.run(["bash", "-c", r'''
set -euo pipefail
source "$LOOP_DIR/lib.sh"
FORK=owner/fork BASE_BRANCH=master BRANCH=loop/iter-23
PAGES_URL=https://pages PR_TITLE=Change ITER=23
export FORK ITER
log() { :; }
repo_git() {
    case "$1" in
        rev-parse) printf 'abc\n' ;;
        merge-base) printf 'base\n' ;;
        status) : ;;
        *) return 1 ;;
    esac
}
run_agent() { return 1; }
ghp() {
    case "$1 $2" in
        "pr list")
            [[ "$EXISTING" == 0 ]] || printf '23\n'
            ;;
        "pr create")
            [[ " $* " == *" --draft "* ]]
            test -s "$ITER_DIR/report.html"
            grep -q 'Change description' "$ITER_DIR/report.html"
            printf 'create\n' >> "$ITER_DIR/trace"
            printf 'https://github.com/owner/fork/pull/23\n'
            ;;
        "pr view")
            printf '{"number":23,"url":"https://github.com/owner/fork/pull/23","createdAt":"2026-10-20","state":"OPEN","isDraft":true}\n'
            ;;
        "pr ready")
            printf 'ready\n' >> "$ITER_DIR/trace"
            ;;
        *) return 1 ;;
    esac
}
publish_report() {
    printf 'publish\n' >> "$ITER_DIR/trace"
    [[ "$REPORT_URL" == "https://pages/reports/pr-23.html" ||
       "$REPORT_URL" == "https://pages/reports/upstream/pr-23.html" ]]
    [[ "$FAIL_PUBLICATION" == 0 ]]
}
open_pr_with_report "$TARGET" "$HEAD" || exit 1
'''], env=env, capture_output=True, text=True)
            trace = (path / "trace").read_text().splitlines()
            meta = json.loads((path / "report-meta.json").read_text())
            return result, trace, meta

    def test_html_precedes_draft_and_publication_precedes_ready(self):
        result, trace, meta = self.run_flow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["create", "publish", "ready"])
        self.assertEqual((meta["number"], meta["state"]), (23, "OPEN"))
        self.assertEqual(meta["base_sha"], "base")

    def test_publication_failure_leaves_the_pr_as_draft(self):
        result, trace, _ = self.run_flow(fail_publication=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, ["create", "publish"])

    def test_resume_reuses_the_existing_draft(self):
        result, trace, _ = self.run_flow(existing=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["publish", "ready"])

    def test_upstream_report_has_its_own_numbered_path(self):
        result, trace, meta = self.run_flow(upstream=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["create", "publish", "ready"])
        self.assertEqual(meta["page"], "https://pages/reports/upstream/pr-23.html")


class PublicationTests(unittest.TestCase):
    def run_publication(self, stale):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            iteration = path / "iteration"
            iteration.mkdir()
            (iteration / "PR_BODY.md").write_text("Keep the PR description.")
            (iteration / "report.html").write_text("<html>Current report</html>")
            (iteration / "report-meta.json").write_text('{"number":23,"state":"OPEN"}')
            env = dict(os.environ, LOOP_DIR=str(ROOT), ITER_DIR=str(iteration),
                       PAGES_DIR=str(path / "pages"), STALE=str(int(stale)))
            result = subprocess.run(["bash", "-c", r'''
set -euo pipefail
source "$LOOP_DIR/lib.sh"
FORK=owner/fork PR_REPO=owner/fork PAGES_BRANCH=gh-pages
PAGES_URL=https://pages REPORT_URL=https://pages/reports/pr-23.html
log() { :; }
sleep() { :; }
git() {
    [[ " $* " != *" diff --cached --quiet "* ]]
}
gh() { printf 'building\n'; }
ghp() { printf '%s %s\n' "$1" "$2" >> "$ITER_DIR/trace"; }
curl() {
    if [[ "$STALE" == 1 ]]; then
        printf '<html>Old cached report</html>' > "$3"
    else
        cp "$ITER_DIR/report.html" "$3"
    fi
    printf '200'
}
publish_report 23 || exit 1
'''], env=env, capture_output=True, text=True)
            trace_file = iteration / "trace"
            trace = trace_file.read_text().splitlines() if trace_file.exists() else []
            body = (iteration / "PR_BODY.md").read_text()
            return result, trace, body

    def test_live_report_is_linked_in_the_description(self):
        result, trace, body = self.run_publication(stale=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["pr edit", "pr comment"])
        self.assertIn("https://pages/reports/pr-23.html", body)
        self.assertIn("Keep the PR description.", body)

    def test_http_200_for_stale_html_does_not_complete_publication(self):
        result, trace, body = self.run_publication(stale=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(trace, [])
        self.assertEqual(body, "Keep the PR description.")


if __name__ == "__main__":
    unittest.main()
