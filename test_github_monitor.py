#!/usr/bin/env python3
"""Self-check for the logic that can silently produce a wrong badge.

No network, no framework, no fixtures on disk. Run it directly:

    ./test_github_monitor.py
"""

import html as html_module
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import time
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


# ---- derived fields are recomputed, not carried
#
# A feed that answers 304 returns the stored entry untouched. Without a
# recompute its age freezes at whatever it said when the feed last changed,
# and a changed overdue factor never reaches it.

stored = {
    "repo": "o/r",
    "published_at": days_ago(40, NOW),
    "age": "23h ago",                    # stale: written 39 days earlier
    "days_since_release": 1.0,
    "avg_days_between_releases": 10.0,
    "release_count": 5,
    "overdue": False,
}

fresh = ghmon.apply_derived(dict(stored), {"overdue_factor": 1.5}, False, NOW)
assert fresh["age"] == "40d ago", fresh["age"]
assert fresh["days_since_release"] == 40.0
assert fresh["overdue"] is True

# A raised factor must reach a repository that has not released since.
relaxed = ghmon.apply_derived(dict(stored), {"overdue_factor": 6.0}, False, NOW)
assert relaxed["overdue"] is False, "overdue factor must apply to cached entries"

# Muting still wins over any factor.
muted_entry = ghmon.apply_derived(dict(stored), {"overdue_factor": 1.5}, True, NOW)
assert muted_entry["overdue"] is False
assert muted_entry["overdue_muted"] is True

print("derived recomputation covered")


# A project that ships several times a day is never overdue: nextcloud/server
# earned a warning one hour after releasing, which is not news about anything.
assert ghmon.is_overdue(0.05, 0.02, 10, 1.5) is False
assert ghmon.is_overdue(30, 0.5, 10, 1.5) is False       # twice a day, gone quiet a month
assert ghmon.is_overdue(30, ghmon.MIN_CADENCE_DAYS, 10, 1.5) is True

print("cadence floor covered")


# ---- local installs

for url, expected in [
    ("https://github.com/atuinsh/atuin", "atuinsh/atuin"),
    ("https://github.com/atuinsh/atuin/", "atuinsh/atuin"),
    ("https://github.com/atuinsh/atuin.git", "atuinsh/atuin"),
    ("git@github.com:atuinsh/atuin.git", "atuinsh/atuin"),
    ("https://gitlab.com/foo/bar", None),
    ("https://atuin.sh", None),
    ("", None),
    (None, None),
]:
    assert ghmon.repo_from_url(url) == expected, url

# A package declaring its upstream is matched on that claim, not on its name.
package = {"host": "local", "name": "atuin", "source_repo": "atuinsh/atuin",
           "via": "pacman", "version": "18.21.0"}
assert ghmon.image_repo_candidates(package) == ["atuinsh/atuin"]
by_repo, unmatched = ghmon.match_containers(["atuinsh/atuin"], [package], {})
assert by_repo["atuinsh/atuin"] == [package]
assert unmatched == []

# An entry with neither an image nor a declared upstream matches nothing
# rather than raising.
assert ghmon.image_repo_candidates({"name": "mystery"}) == []

# pacman's package release is not part of the upstream version: 18.21.0-1 is
# upstream 18.21.0 packaged once, and comparing the release would report every
# package as differing from its own tag.
assert ghmon.compare_versions("v18.21.0", "18.21.0") == "current"
assert ghmon.compare_versions("v18.22.0", "18.21.0") == "behind"

print("local install matching covered")


# ---- prereleases, globally and per repository

mixed_feed = ghmon.parse_feed(
    feed([("v35.0.0rc4", days_ago(1, NOW), ""), ("v32.0.15", days_ago(9, NOW), "")])
)

stable_only = {"include_prereleases": False, "overdue_factor": 1.5}
everything = {"include_prereleases": True, "overdue_factor": 1.5}

assert ghmon.summarize("o/r", mixed_feed, None, stable_only, NOW)["tag"] == "v32.0.15"
assert ghmon.summarize("o/r", mixed_feed, None, everything, NOW)["tag"] == "v35.0.0rc4"

# A per-repository flag overrides the global setting in both directions.
assert ghmon.prereleases_for(set(), stable_only) is False
assert ghmon.prereleases_for({"+pre"}, stable_only) is True
assert ghmon.prereleases_for({"-pre"}, everything) is False
assert ghmon.prereleases_for({"!overdue"}, everything) is True

# An explicit include_pre argument beats whatever the global setting says.
assert ghmon.summarize("o/r", mixed_feed, None, stable_only, NOW,
                       include_pre=True)["tag"] == "v35.0.0rc4"
assert ghmon.summarize("o/r", mixed_feed, None, everything, NOW,
                       include_pre=False)["tag"] == "v32.0.15"

# The choice is recorded, which is what lets a changed preference invalidate a
# cached entry: which release is "latest" depends on it and the feed is gone.
assert ghmon.summarize("o/r", mixed_feed, None, stable_only, NOW,
                       include_pre=True)["prereleases_included"] is True

with tempfile.TemporaryDirectory() as tmp:
    ghmon.REPO_FILE = pathlib.Path(tmp) / "repos.txt"
    ghmon.CONFIG_DIR = pathlib.Path(tmp)
    ghmon.save_repo_entries([("a/one", {"!overdue"}), ("b/two", set())])

    ghmon.set_prereleases("a/one", "on")
    assert ghmon.prereleases_for(dict(ghmon.load_repo_entries())["a/one"], stable_only) is True
    # Setting one flag must not clear another on the same line.
    assert "!overdue" in dict(ghmon.load_repo_entries())["a/one"]

    ghmon.set_prereleases("a/one", "off")
    assert ghmon.prereleases_for(dict(ghmon.load_repo_entries())["a/one"], everything) is False
    ghmon.set_prereleases("a/one", "default")
    flags = dict(ghmon.load_repo_entries())["a/one"]
    assert "+pre" not in flags and "-pre" not in flags
    assert "!overdue" in flags

print("prerelease control covered")


# --------------------------------------------------------- tools and writes

# A tool outside the allowed directories does not exist as far as the daemon is
# concerned, whatever PATH says.
assert ghmon.tool("systemctl") == "/usr/bin/systemctl"
assert ghmon.tool("omarchy-github-monitor-not-a-real-tool") is None
try:
    ghmon.run(["omarchy-github-monitor-not-a-real-tool"], timeout=1)
    raise AssertionError("a missing tool must not be run")
except FileNotFoundError:
    pass

# A deadline tears down the whole group rather than leaving the child behind.
start = time.monotonic()
try:
    ghmon.run(["sleep", "30"], timeout=1)
    raise AssertionError("sleep 30 must not finish inside a 1s deadline")
except subprocess.TimeoutExpired:
    pass
assert time.monotonic() - start < 10

# Every searched directory has to be one only root can write to, or the
# absolute paths taken from it would not mean anything.
for directory in ghmon.TOOL_DIRS:
    info = pathlib.Path(directory).resolve().stat()
    assert info.st_uid == 0, directory
    assert not info.st_mode & 0o022, directory
# Every component down to / has to belong to a trusted account, not just the
# binary and the directory holding it.
handle = ghmon.open_verified(pathlib.Path("/usr/bin/systemctl"),
                             ghmon.SYSTEM_OWNERS, directory=False)
os.close(handle)
with tempfile.TemporaryDirectory() as tmp:
    impostor = pathlib.Path(tmp) / "systemctl"
    impostor.write_text("#!/usr/bin/bash\ntrue\n")
    impostor.chmod(0o755)
    # Owned by this account, so root-only resolution has to refuse it even
    # though the file itself looks fine.
    try:
        ghmon.open_verified(impostor, ghmon.SYSTEM_OWNERS, directory=False)
        raise AssertionError("a user-owned ancestor must not be trusted")
    except PermissionError:
        pass
    # The same path is fine when this account is trusted, which is what the
    # plugin's own state files are checked against.
    os.close(ghmon.open_verified(impostor, ghmon.USER_OWNERS, directory=False))

    # A component that is a link is not followed on the strength of the name
    # it points at: the link has to belong to a trusted account too. This one
    # does, so it resolves; a root-only walk still refuses it.
    linked = pathlib.Path(tmp) / "link"
    linked.symlink_to(impostor)
    os.close(ghmon.open_verified(linked, ghmon.USER_OWNERS, directory=False))
    try:
        ghmon.open_verified(linked, ghmon.SYSTEM_OWNERS, directory=False)
        raise AssertionError("a user-owned link must not be trusted as root's")
    except PermissionError:
        pass

    # A relative path has no components to check, so it is refused outright.
    try:
        ghmon.open_verified(pathlib.Path("usr/bin/systemctl"), ghmon.SYSTEM_OWNERS)
        raise AssertionError("a relative path must be refused")
    except ValueError:
        pass

# /tmp is world-writable, and sticky, which is the one case where that is not
# a way to replace someone else's file.
assert ghmon.owner_ok(os.stat("/tmp"), ghmon.USER_OWNERS)
assert ghmon.owner_ok(os.stat("/usr/bin"), ghmon.SYSTEM_OWNERS)
# root is trusted always; the overflow uid stands in for it only where this
# process cannot see root as root at all.
assert 0 in ghmon.SYSTEM_OWNERS
assert (ghmon.OVERFLOW_UID in ghmon.SYSTEM_OWNERS) == ghmon.root_is_unmapped()
assert os.getuid() in ghmon.USER_OWNERS
assert not ghmon.owner_ok(os.stat("/usr/bin"), frozenset({os.getuid() + 1}))

# The ceiling is enforced while the child is still writing, not after it
# exits: `cat /dev/zero` never exits, so the deadline must not be what stops
# it here.
start = time.monotonic()
try:
    ghmon.run(["cat", "/dev/zero"], timeout=120)
    raise AssertionError("an endless stream must be refused at the ceiling")
except subprocess.SubprocessError as refused:
    assert not isinstance(refused, subprocess.TimeoutExpired), "stopped by the deadline, not the ceiling"
assert time.monotonic() - start < 60
assert ghmon.run(["head", "-c", "16", "/dev/zero"], timeout=20).returncode == 0

# A deadline reaches the child's descendants, not just the child. bash leaves
# two sleeps in its own group; both have to be gone.
marker = "31415926"
try:
    ghmon.run(["bash", "-c", f"sleep {marker} & sleep {marker}"], timeout=1)
    raise AssertionError("that must not finish inside a 1s deadline")
except subprocess.TimeoutExpired:
    pass
leftover = subprocess.run(["/usr/bin/pgrep", "-f", f"sleep {marker}"],
                          capture_output=True, text=True)
assert leftover.stdout.strip() == "", "a timeout left descendants behind"

# A token comes from the environment and nowhere else: nothing is executed to
# find one, because the only tool that could provide it lives somewhere the
# user's own account can write to.
guard = ghmon.run
ghmon.run = lambda *a, **k: (_ for _ in ()).throw(AssertionError("find_token ran a command"))
try:
    for variable in ("GITHUB_TOKEN", "GH_TOKEN"):
        os.environ.pop(variable, None)
    assert ghmon.find_token() == (None, None)
    os.environ["GH_TOKEN"] = "not-a-real-token"
    assert ghmon.find_token() == ("not-a-real-token", "GH_TOKEN")
finally:
    os.environ.pop("GH_TOKEN", None)
    ghmon.run = guard

print("tool resolution and process teardown covered")

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    # A symlink sitting at the target is replaced, not followed: the file it
    # points at must be untouched.
    elsewhere = root / "elsewhere"
    elsewhere.write_text("untouched")
    target = root / "state.json"
    target.symlink_to(elsewhere)
    ghmon.write_atomic(target, "written")
    assert not target.is_symlink()
    assert target.read_text() == "written"
    assert elsewhere.read_text() == "untouched"
    # No temporary file is left behind, under any name.
    assert sorted(p.name for p in root.iterdir()) == ["elsewhere", "state.json"]
    assert oct(target.stat().st_mode & 0o777) == "0o600"

    # Missing parents are created as the path is walked, and nothing above the
    # target is resolved by name afterwards.
    nested = root / "one" / "two" / "state.json"
    ghmon.write_atomic(nested, "nested")
    assert nested.read_text() == "nested"
    assert oct((root / "one").stat().st_mode & 0o777) == "0o700"

print("atomic writes covered")
