"""Render a prompt template: replace {{NAME}} with the environment variable NAME."""
import os
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
missing = []


def sub(match):
    key = match.group(1)
    value = os.environ.get(key)
    if value is None:
        missing.append(key)
        return match.group(0)
    return value


with open(src, encoding="utf-8") as fh:
    text = fh.read()
out = re.sub(r"\{\{([A-Z0-9_]+)\}\}", sub, text)
if missing:
    sys.exit("render_prompt: missing variables: " + ", ".join(sorted(set(missing))))
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(out)
