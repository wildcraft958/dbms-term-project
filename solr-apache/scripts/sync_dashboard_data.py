#!/usr/bin/env python3
"""Regenerate the inline benchmark data in benchmark.html from data/*.json.

The benchmark dashboard renders from inline `const CONFIGS = [...]` (siege) and
`const CPP_RESULTS = {...}` (custom C++ client) so it keeps working when opened
directly (file://). This script makes those data-driven: data/configs.json and
data/cpp_data.json are the single sources of truth, and running this script
rewrites only the spans between the matching DATA markers. It does not touch the
dashboard's layout, styling, chart configuration, or copy.
"""

import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "webapp", "data"))
CONFIGS_JSON = os.path.join(DATA_DIR, "configs.json")
CPP_JSON = os.path.join(DATA_DIR, "cpp_data.json")
HTML_FILE = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "webapp", "benchmark.html"))


def build_block(start, end, declaration, payload):
    """Render `<start> const <declaration> = <json>; <end>` with nested indentation."""
    lines = json.dumps(payload, indent=2).splitlines()
    # Indent every line after the first so the literal nests under the const.
    joined = "\n".join([lines[0]] + ["      " + line for line in lines[1:]])
    return f"{start}\n      const {declaration} = {joined};\n      {end}"


def replace_block(html, start, end, declaration, payload):
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.DOTALL)
    if not pattern.search(html):
        print(f"Error: {start}/{end} markers not found in {HTML_FILE}", file=sys.stderr)
        sys.exit(1)
    return pattern.sub(lambda _: build_block(start, end, declaration, payload), html)


def main():
    with open(CONFIGS_JSON) as f:
        configs = json.load(f)["configs"]
    with open(CPP_JSON) as f:
        cpp = json.load(f)

    with open(HTML_FILE) as f:
        html = f.read()

    html = replace_block(
        html, "/* CONFIGS_DATA_START */", "/* CONFIGS_DATA_END */", "CONFIGS", configs
    )
    html = replace_block(
        html, "/* CPP_DATA_START */", "/* CPP_DATA_END */", "CPP_RESULTS", cpp
    )

    with open(HTML_FILE, "w") as f:
        f.write(html)

    print(
        f"Updated benchmark.html: CONFIGS ({len(configs)} siege configurations from "
        f"{os.path.basename(CONFIGS_JSON)}) and CPP_RESULTS ({len(cpp['data'])} points from "
        f"{os.path.basename(CPP_JSON)})"
    )


if __name__ == "__main__":
    main()
