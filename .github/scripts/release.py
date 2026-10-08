#!/usr/bin/env python3
"""Core source releases: select, test, then publish an immutable version."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
PACKAGE = re.compile(r'(\bversion: ")([0-9]+\.[0-9]+\.[0-9]+)(")')


def run(*args):
    return subprocess.check_output(args, text=True, cwd=ROOT).strip()


def package_version():
    matches = list(PACKAGE.finditer((ROOT / "mix.exs").read_text()))
    if len(matches) != 1:
        raise ValueError("Expected one package version in mix.exs")
    return "v" + matches[0][2]


def next_version(current, versions, bump):
    if not VERSION.fullmatch(current) or bump not in ("patch", "minor", "major"):
        raise ValueError("Invalid version or increment")
    existing = [tuple(map(int, match.groups())) for v in versions if (match := VERSION.fullmatch(v))]
    if not existing:
        return current
    major, minor, patch = max(existing + [tuple(map(int, VERSION.fullmatch(current).groups()))])
    if bump == "major":
        return f"v{major + 1}.0.0"
    if bump == "minor":
        return f"v{major}.{minor + 1}.0"
    return f"v{major}.{minor}.{patch + 1}"


def apply_version(version):
    if not VERSION.fullmatch(version):
        raise ValueError("Use vX.Y.Z")
    package_version()
    path = ROOT / "mix.exs"
    path.write_text(PACKAGE.sub(lambda m: m[1] + version[1:] + m[3], path.read_text(), count=1))


def releases(repo):
    pages = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"))
    return [item for page in pages for item in page]


def publish(version, source, repo):
    if run("git", "rev-parse", "HEAD") != source:
        raise ValueError("Checkout does not match the tested source")
    apply_version(version)
    run("git", "add", "mix.exs")
    expected_tree = run("git", "write-tree")
    tag_ref = f"refs/tags/{version}"
    existing = run("git", "ls-remote", "--tags", "origin", tag_ref)
    if existing:
        run("git", "fetch", "origin", tag_ref)
        tagged = run("git", "rev-parse", "FETCH_HEAD^{commit}")
        if run("git", "rev-parse", f"{tagged}^{{tree}}") != expected_tree:
            raise ValueError("Existing tag contains different source; never overwrite it")
        if tagged != source and run("git", "rev-parse", f"{tagged}^") != source:
            raise ValueError("Existing tag is not based on the tested commit")
    else:
        remote = run("git", "ls-remote", "origin", "refs/heads/main").split()
        if not remote or remote[0] != source:
            raise ValueError("main changed during checks; start a new release run")
        if run("git", "diff", "--cached", "--name-only"):
            run("git", "-c", "user.name=github-actions[bot]", "-c",
                "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "commit", "-m", f"Release {version}")
        run("git", "tag", version)
        # No force push: publish the tested tree and tag together, or neither.
        run("git", "push", "--atomic", "origin", "HEAD:refs/heads/main", tag_ref)
    existing_release = next((item for item in releases(repo) if item["tag_name"] == version), None)
    if existing_release:
        if existing_release["draft"] or existing_release["prerelease"]:
            raise ValueError("Existing release is not a final release")
        print(f"{version} is already published")
        return
    run("gh", "release", "create", version, "--repo", repo, "--verify-tag",
        "--title", f"Mave Core {version}", "--generate-notes", "--latest")
    print(f"Released {version}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "apply", "publish"])
    parser.add_argument("--bump", choices=["patch", "minor", "major"], default="patch")
    parser.add_argument("--version", default=os.environ.get("RELEASE_VERSION", ""))
    args = parser.parse_args()
    if args.action == "apply":
        apply_version(args.version)
        return
    repo = os.environ["GITHUB_REPOSITORY"]
    if args.action == "publish":
        publish(args.version, os.environ["GITHUB_SHA"], repo)
        return
    tags = run("gh", "api", "--paginate", f"repos/{repo}/git/matching-refs/tags/", "--jq", ".[].ref").splitlines()
    versions = [tag.removeprefix("refs/tags/") for tag in tags] + [item["tag_name"] for item in releases(repo)]
    version = next_version(package_version(), versions, args.bump)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"version={version}\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(f"## Mave Core {version}\n")
    print(version)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from None
