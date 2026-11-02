#!/usr/bin/env python3
"""Write a junit report for a suite whose cases are steps of a script.

    junit_cases.py JUNIT SUITE CASES

CASES is a file of tab-separated lines the script appended as it went:

    case<TAB>NAME<TAB>pass|fail|skip<TAB>SECONDS<TAB>MESSAGE[<TAB>LOG[<TAB>TESTS_JUNIT...]]

A failing case's body is the tail of LOG when one is given. TESTS_JUNIT names
the per-test junit(s) the step wrote: when they record at least one failure of
an identified test (both classname and name, the cases aidev keys an id on),
the step case is written skipped, pointing at them, so each failure is reported
once, under the test's own id, where a quarantine entry or a re-run can name
it. A step whose per-test junit is missing or records no such failure (a crash,
a broken setup, a pytest collection error) still fails as itself.
"""
import os
import re
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

LOG_TAIL_LINES = 80
CONTROL = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|[\x00-\x08\x0b\x0c\x0e-\x1f]")


def log_tail(path: str) -> str:
    if not path or not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = CONTROL.sub("", handle.read()).splitlines()
    return "\n".join(lines[-LOG_TAIL_LINES:])


def _recorded_failures(path: str) -> int:
    if not path or not os.path.isfile(path):
        return 0
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return 0
    return sum(
        1
        for case in root.iter("testcase")
        if case.get("classname") and case.get("name") and (case.find("failure") is not None or case.find("error") is not None)
    )


def main(junit: str, suite: str, cases_file: str) -> None:
    cases = []
    with open(cases_file, encoding="utf-8") as handle:
        for line in handle.read().splitlines():
            fields = line.split("\t")
            if fields[0] != "case" or len(fields) < 4:
                continue
            fields += [""] * (6 - len(fields))
            _, name, status, seconds, message, log = fields[:6]
            tests_junits = [path for path in fields[6:] if path]
            if status == "fail":
                failed = sum(_recorded_failures(path) for path in tests_junits)
                if failed:
                    status = "skip"
                    where = ", ".join(os.path.relpath(path, os.path.dirname(junit) or ".") for path in tests_junits)
                    message = f"{message}: {failed} failing test(s) reported per test in {where}"
            cases.append((name, status, float(seconds or 0), message, log))
    body = []
    for name, status, seconds, message, log in cases:
        head = f"<testcase classname={quoteattr(suite)} name={quoteattr(name)} time=\"{seconds}\">"
        if status == "fail":
            body.append(f"{head}<failure message={quoteattr(message)}>{escape(log_tail(log))}</failure></testcase>")
        elif status == "skip":
            body.append(f"{head}<skipped message={quoteattr(message)}/></testcase>")
        else:
            body.append(f"{head}</testcase>")
    failures = sum(1 for case in cases if case[1] == "fail")
    skipped = sum(1 for case in cases if case[1] == "skip")
    total = sum(case[2] for case in cases)
    os.makedirs(os.path.dirname(junit) or ".", exist_ok=True)
    with open(junit, "w", encoding="utf-8") as handle:
        handle.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        handle.write(
            f"<testsuite name={quoteattr(suite)} tests=\"{len(cases)}\" failures=\"{failures}\" "
            f"errors=\"0\" skipped=\"{skipped}\" time=\"{total}\">\n"
        )
        handle.write("\n".join(body) + "\n</testsuite>\n")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} JUNIT SUITE CASES")
    main(*sys.argv[1:])
