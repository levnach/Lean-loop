"""Insert or refresh the HTML report links without replacing the PR description."""
import re
import sys
from pathlib import Path

START = "<!-- loop-html-report -->"
END = "<!-- /loop-html-report -->"
SECTION = re.compile(re.escape(START) + ".*?" + re.escape(END), re.DOTALL)


def with_report_links(body, page_url, source_url):
    section = (
        f"{START}\n## HTML description\n\n"
        f"[Read the HTML report]({page_url}) | [View the HTML file]({source_url})\n{END}"
    )
    matches = list(SECTION.finditer(body))
    if len(matches) > 1 or body.count(START) != len(matches) or body.count(END) != len(matches):
        raise ValueError("invalid or duplicated HTML report section")
    if matches:
        return SECTION.sub(lambda _: section, body, count=1)
    return section + "\n\n" + body


if __name__ == "__main__":
    path = Path(sys.argv[1])
    path.write_text(with_report_links(path.read_text(encoding="utf-8"), *sys.argv[2:4]), encoding="utf-8")
