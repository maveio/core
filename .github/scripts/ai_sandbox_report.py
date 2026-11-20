#!/usr/bin/env python3
"""Render an AI sandbox report as Markdown for a pull-request comment.

The report was written by a model that read untrusted pull-request content, so
every string in it is treated as hostile: no mentions, links, images, HTML or
headings survive, and code is fenced so it cannot close its own block. This
script needs no credentials and never executes or fetches anything.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

MARKER = "<!-- mave-ai-sandbox-report -->"
MAX_COMMENT_CHARS = 60_000
SEVERITY_ICON = {"critical": "🟣", "high": "🔴", "medium": "🟠", "low": "🟡", "info": "🔵"}
SEVERITY_ORDER = {name: index for index, name in enumerate(SEVERITY_ICON)}
RESULT_ICON = {"pass": "✅", "fail": "❌", "skipped": "⏭️", "error": "⚠️"}

_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f​-‏‪-‮⁦-⁩]")
_MARKDOWN = re.compile(r"([\\*_#\[\]()!|~>])")
_CODE_SPAN = re.compile(r"`([^`\n]{1,200})`")


def _plain(text: Any, limit: int) -> str:
    text = _CONTROL.sub("", str(text or "")).replace("\r", "")
    if len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def _escape(text: str) -> str:
    """Make text inert: no HTML, mentions, links, images, autolinks or emphasis."""
    text = text.replace("&", "&amp;").replace("<", "&lt;")
    text = _MARKDOWN.sub(r"\\\1", text)
    text = text.replace("@", "&#64;").replace("://", ":&#47;&#47;")
    return re.sub(r"(?i)\bwww\.", "www&#46;", text)


def _code(text: Any, limit: int = 300) -> str:
    """Inline code; backticks are removed so the span cannot be closed early."""
    cleaned = _plain(text, limit).replace("`", "'").replace("\n", " ").replace("|", "¦").strip()
    return f"`{cleaned}`" if cleaned else ""


def inline(text: Any, limit: int = 300) -> str:
    """One line of untrusted prose; simple `code spans` are kept as code."""
    text = " ".join(_plain(text, limit).split())
    parts, position = [], 0
    for match in _CODE_SPAN.finditer(text):
        parts.append(_escape(text[position : match.start()]))
        parts.append(_code(match.group(1)))
        position = match.end()
    parts.append(_escape(text[position:]).replace("`", "'"))
    return "".join(parts)


def prose(text: Any, limit: int = 6000) -> str:
    """Untrusted multi-line prose as paragraphs."""
    paragraphs = [inline(block, limit) for block in re.split(r"\n\s*\n", _plain(text, limit))]
    return "\n\n".join(paragraph for paragraph in paragraphs if paragraph)


def fenced(text: Any, limit: int = 4000) -> str:
    """A code block whose fence is longer than any backtick run inside it."""
    body = _plain(text, limit).strip("\n")
    longest = max((len(run) for run in re.findall(r"`+", body)), default=0)
    fence = "`" * max(3, longest + 1)
    return f"{fence}text\n{body}\n{fence}"


def _location(finding: dict[str, Any]) -> str:
    path = _plain(finding.get("file"), 300).strip()
    if not path:
        return ""
    line = finding.get("line") or 0
    return _code(f"{path}:{line}" if isinstance(line, int) and line > 0 else path)


def _duration(seconds: Any) -> str:
    try:
        seconds = int(float(seconds))
    except (TypeError, ValueError):
        return ""
    return f"{seconds // 60}m {seconds % 60}s" if seconds >= 60 else f"{seconds}s"


def _headline(report: dict[str, Any], findings: list[dict[str, Any]]) -> str:
    meta = report.get("meta") or {}
    if not meta.get("completed", True):
        return "⚠️ AI sandbox test did not complete"
    if findings:
        worst = SEVERITY_ICON.get(findings[0].get("severity"), "🔵")
        noun = "finding" if len(findings) == 1 else "findings"
        return f"{worst} AI sandbox test: {len(findings)} {noun} to review"
    if report.get("verdict") == "inconclusive":
        return "⚠️ AI sandbox test was inconclusive"
    return "✅ AI sandbox test found no issues"


def render(report: dict[str, Any], run_url: str = "", evidence: bool = True) -> str:
    meta = report.get("meta") or {}
    pull_request = report.get("pull_request") or {}
    findings = sorted(
        (f for f in report.get("findings") or [] if isinstance(f, dict)),
        key=lambda f: SEVERITY_ORDER.get(f.get("severity"), 99),
    )
    lines = [MARKER, f"## {_headline(report, findings)}", ""]

    head = _code(str(pull_request.get("head_sha", ""))[:12])
    base = _code(str(pull_request.get("base_sha", ""))[:12])
    if meta.get("scripted"):
        lines += [
            f"> **Scripted dry run.** No model was called; the steps and this report come from a script. "
            f"It proves the sandbox plumbing for {head}, not the quality of the change.",
            "",
        ]
    else:
        lines += [
            f"A model tested {head} against {base} in a sandbox without network access, credentials or "
            "production data. This is advisory: the model read untrusted pull-request content, so verify a "
            "finding before acting on it and do not treat a clean report as a review.",
            "",
        ]

    summary = prose(report.get("summary"), 4000)
    if summary:
        lines += [summary, ""]

    if findings:
        lines += ["### Findings", "", "| Severity | Area | Finding | Where |", "| --- | --- | --- | --- |"]
        for finding in findings:
            severity = _plain(finding.get("severity"), 20)
            lines.append(
                f"| {SEVERITY_ICON.get(severity, '🔵')} {_escape(severity)} | {_escape(_plain(finding.get('category'), 20))} "
                f"| {inline(finding.get('title'))} | {_location(finding)} |"
            )
        lines.append("")
        for finding in findings:
            severity = _plain(finding.get("severity"), 20)
            lines += [
                "<details>",
                f"<summary>{SEVERITY_ICON.get(severity, '🔵')} <b>{inline(finding.get('title'))}</b></summary>",
                "",
                prose(finding.get("description")),
                "",
            ]
            if evidence and str(finding.get("evidence") or "").strip():
                lines += ["**Evidence**", "", fenced(finding.get("evidence")), ""]
            if str(finding.get("recommendation") or "").strip():
                lines += [f"**Suggested fix:** {prose(finding.get('recommendation'), 4000)}", ""]
            lines += [f"Confidence: {_escape(_plain(finding.get('confidence'), 20))}", "", "</details>", ""]

    checks = [c for c in report.get("checks") or [] if isinstance(c, dict)]
    if checks:
        lines += ["### What was checked", "", "| | Check | Outcome |", "| --- | --- | --- |"]
        for check in checks:
            command = _code(check.get("command"), 200)
            name = inline(check.get("name")) + (f"<br>{command}" if command else "")
            lines.append(
                f"| {RESULT_ICON.get(check.get('result'), '⚠️')} | {name} | {inline(check.get('details'), 500)} |"
            )
        lines.append("")

    limitations = [inline(item, 1000) for item in report.get("limitations") or [] if str(item).strip()]
    if limitations:
        lines += ["### Not covered", ""] + [f"- {item}" for item in limitations] + [""]

    usage = meta.get("usage") or {}
    footer = [
        f"model {_code(meta.get('model'), 80)}" if meta.get("model") else "",
        f"{meta.get('turns')} turns" if meta.get("turns") else "",
        f"{meta.get('commands')} commands" if meta.get("commands") else "",
        _duration(meta.get("duration_seconds")) if meta.get("duration_seconds") else "",
        f"{usage.get('input_tokens', 0) + usage.get('cache_read_input_tokens', 0) + usage.get('cache_creation_input_tokens', 0):,} "
        f"input and {usage.get('output_tokens', 0):,} output tokens"
        if usage.get("output_tokens")
        else "",
        f"[workflow run]({run_url})"
        if re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+/actions/runs/\d+", run_url or "")
        else "",
    ]
    lines.append("<sub>" + " · ".join(part for part in footer if part) + "</sub>")
    return "\n".join(lines) + "\n"


def render_comment(report: dict[str, Any], run_url: str = "") -> str:
    """Render within GitHub's comment size limit, dropping evidence first."""
    body = render(report, run_url)
    if len(body) <= MAX_COMMENT_CHARS:
        return body
    body = render(report, run_url, evidence=False)
    note = "\n\n_The report was shortened to fit a comment; the workflow run has the complete version._\n"
    return (
        body[: MAX_COMMENT_CHARS - len(note)].rstrip() + note
        if len(body) > MAX_COMMENT_CHARS - len(note)
        else body + note
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", help="report JSON written by ai_sandbox.py review")
    parser.add_argument("--run-url", default="", help="link to the workflow run")
    parser.add_argument("--output", help="write Markdown here instead of standard output")
    args = parser.parse_args(argv)

    try:
        with open(args.report, encoding="utf-8") as handle:
            report = json.load(handle)
    except (OSError, ValueError) as error:
        print(f"Cannot read the report: {error}", file=sys.stderr)
        return 1
    if not isinstance(report, dict):
        print("The report must be a JSON object.", file=sys.stderr)
        return 1

    body = render_comment(report, args.run_url)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(body)
    else:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
