#!/usr/bin/env python3
"""Self-check for the logic that can silently produce a wrong badge.

No network, no framework, no fixtures on disk. Run it directly:

    ./test_github_monitor.py
"""

import html as html_module
import importlib.machinery
import importlib.util
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
import pathlib

# The daemon has no .py extension, so it needs an explicit source loader.
SOURCE = Path(__file__).parent / "bin" / "omarchy-github-monitor"
spec = importlib.util.spec_from_loader(
    "ghmon", importlib.machinery.SourceFileLoader("ghmon", str(SOURCE))
)
ghmon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ghmon)


def feed(entries):
    """Build a releases.atom document the way GitHub emits one."""
    items = "\n".join(
        f"""  <entry>
    <id>tag:github.com,2008:Repository/1234/{tag}</id>
    <title>{tag}</title>
    <updated>{when}</updated>
    <link rel="alternate" type="text/html" href="https://github.com/o/r/releases/tag/{tag}"/>
    <content type="html">{html_module.escape(notes)}</content>
  </entry>"""
        for tag, when, notes in entries
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Release notes from r</title>
{items}
</feed>"""


def days_ago(n, base):
    return (base - timedelta(days=n)).strftime("%Y-%m-%dT%H:%M:%SZ")


NOW = datetime(2026, 9, 10, 12, 0, 0, tzinfo=timezone.utc)


# ---- parse_iso8601

assert ghmon.parse_iso8601("2026-09-09T14:33:42Z") == datetime(
    2026, 9, 9, 14, 33, 42, tzinfo=timezone.utc
)
assert ghmon.parse_iso8601("") is None
assert ghmon.parse_iso8601("not a date") is None


# ---- avg_days_between_releases

evenly_spaced = [{"published_at": days_ago(n, NOW)} for n in (0, 10, 20, 30)]
assert ghmon.avg_days_between_releases(evenly_spaced) == 10.0

uneven = [{"published_at": days_ago(n, NOW)} for n in (0, 2, 20)]
assert ghmon.avg_days_between_releases(uneven) == 10.0  # (2 + 18) / 2

assert ghmon.avg_days_between_releases([{"published_at": days_ago(0, NOW)}]) is None
assert ghmon.avg_days_between_releases([]) is None
# Undated entries are skipped rather than poisoning the mean.
assert ghmon.avg_days_between_releases(
    [{"published_at": days_ago(0, NOW)}, {"published_at": ""}]
) is None


# ---- is_overdue

# 30 days since a release, on a 10-day cadence, factor 1.5 -> overdue at 15.
assert ghmon.is_overdue(30, 10, 5, 1.5) is True
assert ghmon.is_overdue(12, 10, 5, 1.5) is False
assert ghmon.is_overdue(15.0, 10, 5, 1.5) is False  # boundary is exclusive
assert ghmon.is_overdue(15.1, 10, 5, 1.5) is True

# Two releases are a coincidence, not a cadence: never overdue.
assert ghmon.is_overdue(9999, 10, 2, 1.5) is False
assert ghmon.is_overdue(9999, 10, ghmon.MIN_RELEASES_FOR_CADENCE, 1.5) is True

# Missing inputs must not raise, and must not invent a warning.
assert ghmon.is_overdue(None, 10, 5, 1.5) is False
assert ghmon.is_overdue(30, None, 5, 1.5) is False
assert ghmon.is_overdue(30, 0, 5, 1.5) is False


# ---- prerelease inference from the tag

for tag in ("v1.2.0-rc.1", "v2-beta", "3.0.0-alpha", "v1-pre", "v9-canary"):
    assert ghmon.is_prerelease(tag) is True, tag
for tag in ("v1.2.0", "3.0.0", "2026.09.1", "v1.0.0-1", ""):
    assert ghmon.is_prerelease(tag) is False, tag


# ---- normalize_repo

for value in (
    "foo/bar",
    "https://github.com/foo/bar",
    "https://github.com/foo/bar/releases/tag/v1",
    "github.com/foo/bar",
    "https://github.com/foo/bar.git",
):
    assert ghmon.normalize_repo(value) == "foo/bar", value

# A non-GitHub host must be refused outright, not reduced to owner/repo and
# tracked as if it lived on GitHub.
for value in (
    "",
    "notarepo",
    "https://gitlab.com/foo/bar",
    "https://gitlab.com/foo/bar/baz/qux",
    "https://codeberg.org/foo/bar",
    "https://github.com.evil.test/foo/bar",
    "https://github.com/foo",
    "foo bar",
):
    assert ghmon.normalize_repo(value) is None, value


# ---- parse_feed

parsed = ghmon.parse_feed(
    feed(
        [
            ("v3.2.0", days_ago(1, NOW), "Fixed &amp; shipped<br/>Second line"),
            ("v3.2.0-rc.1", days_ago(5, NOW), "<p>Testing</p>"),
        ]
    )
)
assert len(parsed) == 2
assert parsed[0]["tag"] == "v3.2.0"
assert parsed[0]["url"].endswith("/releases/tag/v3.2.0")
assert parsed[0]["prerelease"] is False
assert parsed[1]["prerelease"] is True
# HTML never reaches QML: entities decoded, tags gone, breaks become newlines.
assert parsed[0]["notes"] == "Fixed & shipped\nSecond line", parsed[0]["notes"]
assert "<" not in parsed[1]["notes"]

# A feed carrying a doctype is refused, not parsed.
try:
    ghmon.parse_feed('<!DOCTYPE feed [<!ENTITY a "boom">]><feed/>')
    raise AssertionError("doctype should be refused")
except Exception as exc:
    assert "doctype" in str(exc).lower(), exc


# ---- summarize

opts = {"include_prereleases": False, "overdue_factor": 1.5}

releases = ghmon.parse_feed(
    feed([("v1.3.0", days_ago(n, NOW), "notes") for n in (40, 50, 60, 70)])
)
entry = ghmon.summarize("o/r", releases, None, opts, NOW)
assert entry["tag"] == "v1.3.0"
assert entry["release_count"] == 4
assert entry["avg_days_between_releases"] == 10.0
assert entry["days_since_release"] == 40.0
assert entry["overdue"] is True
assert entry["error"] is None

# Prereleases are excluded by default, so the newest stable is what shows.
mixed = ghmon.parse_feed(
    feed([("v2.0.0-rc.1", days_ago(1, NOW), ""), ("v1.9.0", days_ago(9, NOW), "")])
)
assert ghmon.summarize("o/r", mixed, None, opts, NOW)["tag"] == "v1.9.0"
assert ghmon.summarize(
    "o/r", mixed, None, {**opts, "include_prereleases": True}, NOW
)["tag"] == "v2.0.0-rc.1"

# A feed of nothing but prereleases still reports something rather than a
# blank row: the filter falls back when it would empty the list.
only_pre = ghmon.parse_feed(feed([("v2.0.0-rc.1", days_ago(1, NOW), "")]))
assert ghmon.summarize("o/r", only_pre, None, opts, NOW)["tag"] == "v2.0.0-rc.1"

# An empty feed is an error on that row, not an exception.
assert ghmon.summarize("o/r", [], None, opts, NOW)["error"] == "no releases in feed"

# Commits-since-tag is carried over from the previous entry when this run had
# no token to refresh it with.
carried = ghmon.summarize("o/r", releases, {"commits_since_tag": 42}, opts, NOW)
assert carried["commits_since_tag"] == 42


# ---- strip_html

assert ghmon.strip_html("<script>alert(1)</script>safe") == "safe"
assert ghmon.strip_html("<li>one</li><li>two</li>") == "• one\n• two"
assert ghmon.strip_html("") == ""
assert ghmon.strip_html(None) == ""


print("all checks passed")


# ---- rolling pointer tags and feed ordering
#
# Real feeds exposed all three of these: n8n re-points `v1` and `stable`, which
# arrive with fresh timestamps and, left in, crush its cadence to hours; the
# entries are not ordered by date; and nextcloud writes `rc` with no separator.

n8n_shaped = ghmon.parse_feed(
    feed(
        [
            ("v1", days_ago(0.3, NOW), ""),
            ("stable", days_ago(0.2, NOW), ""),
            ("n8n@2.39.2", days_ago(0.4, NOW), ""),
            ("n8n@2.39.1", days_ago(7, NOW), ""),
            ("n8n@2.39.0", days_ago(14, NOW), ""),
        ]
    )
)
tags = [r["tag"] for r in n8n_shaped]
assert "v1" not in tags and "stable" not in tags, tags
assert tags[0] == "n8n@2.39.2", tags  # newest real release, despite feed order
assert ghmon.avg_days_between_releases(n8n_shaped) == 6.8, n8n_shaped

# A project whose tags are all bare numbers keeps them: they are its releases.
bare = ghmon.parse_feed(feed([("160", days_ago(1, NOW), ""), ("159", days_ago(30, NOW), "")]))
assert [r["tag"] for r in bare] == ["160", "159"]

# Prerelease markers with no separator.
for tag in ("v35.0.0rc4", "v2.0.0beta1", "1.0.0alpha"):
    assert ghmon.is_prerelease(tag) is True, tag
for tag in ("v1.2.3", "160", "n8n@2.39.2", "2026.09.1"):
    assert ghmon.is_prerelease(tag) is False, tag

print("real-feed regressions covered")


# A bullet must not be stranded on its own line when the markup wraps.
assert ghmon.strip_html("<li>\n  one</li><li>\ntwo</li>") == "• one\n• two"
assert ghmon.strip_html("<ul><li>alpha</li>\n<li>beta</li></ul>") == "• alpha\n• beta"

print("notes formatting covered")


# Hard-wrapped notes: a break before a continuation line is joined, a break
# before a new sentence is kept.
assert ghmon.strip_html("<p>setting the new</p><p>group attribute.</p>") == "setting the new group attribute."
assert ghmon.strip_html("<p>First line.</p><p>Second line.</p>") == "First line.\n\nSecond line."

print("hard-wrap joining covered")


# ---- muting and unseen state

muted_releases = ghmon.parse_feed(
    feed([("v1.3.0", days_ago(n, NOW), "") for n in (40, 50, 60, 70)])
)
assert ghmon.summarize("o/r", muted_releases, None, opts, NOW)["overdue"] is True
muted_entry = ghmon.summarize("o/r", muted_releases, None, opts, NOW, muted=True)
assert muted_entry["overdue"] is False
assert muted_entry["overdue_muted"] is True

# repos.txt flag round-trip: a flag on one line must survive rewriting another.
import tempfile
with tempfile.TemporaryDirectory() as tmp:
    ghmon.REPO_FILE = pathlib.Path(tmp) / "repos.txt"
    ghmon.CONFIG_DIR = pathlib.Path(tmp)
    ghmon.save_repo_entries([("a/one", {"!overdue"}), ("b/two", set())])
    assert ghmon.load_repos() == ["a/one", "b/two"]
    assert ghmon.muted_repos() == {"a/one"}

    # Adding a repository must not strip another line's flag.
    ghmon.save_repo_entries(ghmon.load_repo_entries() + [("c/three", set())])
    assert ghmon.muted_repos() == {"a/one"}, ghmon.REPO_FILE.read_text()

    ghmon.set_overdue_muted("b/two", True)
    assert ghmon.muted_repos() == {"a/one", "b/two"}
    ghmon.set_overdue_muted("a/one", False)
    assert ghmon.muted_repos() == {"b/two"}

    # A comment on a flagged line is still a comment.
    ghmon.REPO_FILE.write_text("a/one !overdue  # bursty\n# b/two\n")
    assert ghmon.load_repos() == ["a/one"]
    assert ghmon.muted_repos() == {"a/one"}

print("mute and flags covered")


# ---- container matching
#
# The generic-name trap: heimdall runs vaultwarden/server, and matching on the
# last path segment reported nextcloud/server — a service not running at all —
# as out of date.

vaultwarden = {"host": "heimdall", "name": "vaultwarden",
               "image": "vaultwarden/server:latest", "version": "1.37.0", "source": None}
jellyfin = {"host": "asgard", "name": "jellyfin_asgard",
            "image": "jellyfin/jellyfin:latest", "version": "10.11.11", "source": None}

by_repo, unmatched = ghmon.match_containers(
    ["nextcloud/server", "jellyfin/jellyfin"], [vaultwarden, jellyfin], {}
)
assert by_repo["nextcloud/server"] == [], by_repo
assert by_repo["jellyfin/jellyfin"] == [jellyfin]
assert unmatched == [vaultwarden]

# A pin rescues what the automatic passes cannot see.
by_repo, unmatched = ghmon.match_containers(
    ["dani-garcia/vaultwarden"], [vaultwarden], {"vaultwarden/server": "dani-garcia/vaultwarden"}
)
assert by_repo["dani-garcia/vaultwarden"] == [vaultwarden]
assert unmatched == []

# The OCI source label outranks the image path.
labelled = {"host": "asgard", "name": "oikos", "image": "ghcr.io/other/name:latest",
            "version": "2.6.0", "source": "https://github.com/ulsklyc/yuvomi"}
by_repo, _ = ghmon.match_containers(["ulsklyc/yuvomi"], [labelled], {})
assert by_repo["ulsklyc/yuvomi"] == [labelled]

# A registry host is not an owner.
assert ghmon.image_repo_candidates(
    {"image": "ghcr.io/blakeblackshear/frigate:stable", "source": None}
) == ["blakeblackshear/frigate"]

# ---- version extraction and comparison
assert ghmon.running_version("gitea/gitea:1.27.2", "") == "1.27.2"
assert ghmon.running_version("jellyfin/jellyfin:latest", "10.11.11") == "10.11.11"
assert ghmon.running_version("ghcr.io/x/frigate:stable", "") is None
assert ghmon.running_version("x/y:latest", "<no value>") is None

assert ghmon.compare_versions("v10.11.11", "10.11.11") == "current"
assert ghmon.compare_versions("v12.0", "10.11.11") == "behind"
assert ghmon.compare_versions("v1.0.0", "1.2.0") == "ahead"
assert ghmon.compare_versions("n8n@2.39.2", "2.39.2") == "current"
# An unknown running version must never be reported as up to date.
assert ghmon.compare_versions("v12.0", None) == "unknown"
assert ghmon.compare_versions(None, "1.0") == "unknown"
assert ghmon.compare_versions("stable-2026", "weekly-9") == "differs"

print("container matching covered")
