# GitHub Release Monitor — Omarchy plugin design

Date: 2026-09-10
Plugin id: `io.github.irhop.github-monitor`
Status: approved, pending implementation plan

## Purpose

Track releases of third-party GitHub repositories and surface them in the
Omarchy bar. Replaces `github_monitor.py`, a 1402-line terminal UI that has to
be launched by hand.

The distinguishing feature is **overdue detection**: a repository that has gone
longer than its own established release cadence without shipping. No other tool
in the Omarchy ecosystem, nor `gh`, nor a feed reader, reports this.

## Constraints

**No credentials.** The machine has no usable GitHub credential — `gh` is
logged out, there is no keyring entry, no `.netrc`, no credential helper. The
plugin must work with none, and must never prompt for one.

**No API rate limit budget.** Unauthenticated REST is 60 requests/hour. The old
script spends 57 per refresh across 19 repositories, so it was already failing.

## Data source

`https://github.com/OWNER/REPO/releases.atom` — the web endpoint, not the API.

Verified behavior:

- returns the 10 most recent releases: tag, timestamp, release notes
- honors `If-None-Match`; an unchanged feed returns `304`
- no token, no API rate limit
- 5 sequential fetches in 3.3s; 19 in parallel in roughly 2s

Ten entries is enough to compute release cadence, which is what overdue
detection needs.

### What the feed cannot provide

| Field | Source | Behavior without a token |
| --- | --- | --- |
| commits since latest tag | `compare` API | omitted |
| exact prerelease flag | `releases` API | inferred from the tag (`-rc`, `-beta`, `-alpha`, `-pre`) |

If a token is present in the environment (`GITHUB_TOKEN`, `GH_TOKEN`) or
obtainable from `gh auth token`, the daemon adds both. It is never required,
and the plugin never stores one.

## Architecture

Follows the shape of `io.github.irhop.mouse-odometer`: a Python process writes
JSON, QML reads it.

```
bin/omarchy-github-monitor      fetch feeds, compute, write state.json
systemd/*.timer + *.service     poll on a schedule
$XDG_STATE_HOME/.../state.json  the contract between the two halves
Panel.qml                       bar widget + popup detail
manifest.json                   identity, entry points, settings schema
```

The daemon and the widget share nothing but the state file. Either can be
replaced without touching the other.

### Bar widget

A `bar-widget` whose entry point is a `Panel` (the pattern used by
`omarchy.tailscale` and `omarchy.weather`), not a fullscreen `overlay`.
`PopupCard` supplies anchoring, sizing, and theme colors.

Three display states:

```
quiet:    󰊤 19          all tracked repos, nothing new
new:      󰊤 3 ●         releases within the notification window
overdue:  󰊤 19 ⚠2       repos past their own cadence
```

The popup lists repositories sorted by recency, each with tag, age, cadence,
and an overdue marker; selecting one shows its release notes.

### Daemon

Subcommands:

- `fetch` — one pass, write the state file, exit. What the timer runs.
- `run` — `fetch` in a loop, for debugging without systemd.
- `bootstrap` — install and enable the user timer. Never runs implicitly;
  enabling the plugin alone installs nothing, matching mouse-odometer.
- `list` / `add` / `remove` / `search` — manage the tracked repositories.

Fetching reuses the existing `ThreadPoolExecutor` pattern. Stored ETags make
repeat polls cheap.

### Timer, not a sleep loop

`OnUnitActiveSec=15min` with `Persistent=true`, so a poll missed across suspend
runs on resume. A `Type=simple` process sleeping in a loop silently skips them.

## State file

Atomic write: temp file in the same directory, then `os.replace`.

```json
{
  "generated_at": "2026-09-10T14:00:00Z",
  "poll_interval_seconds": 900,
  "authenticated": false,
  "repos": [
    {
      "repo": "immich-app/immich",
      "tag": "v3.2.0",
      "published_at": "2026-09-09T14:33:42Z",
      "url": "https://github.com/immich-app/immich/releases/tag/v3.2.0",
      "notes": "plain text, HTML stripped",
      "prerelease": false,
      "avg_days_between_releases": 12.4,
      "release_count": 10,
      "days_since_release": 1.0,
      "overdue": false,
      "commits_since_tag": null,
      "error": null
    }
  ]
}
```

`error` holds a per-repository failure without discarding the rest. A repo that
fails keeps its previous entry and records the error, so one dead feed cannot
empty the bar.

## Overdue rule

A repository is overdue when:

```
days_since_release > overdue_factor * avg_days_between_releases
```

Requires at least 3 releases in the feed; fewer means no established cadence
and `overdue` stays false. Default `overdue_factor` is 1.5.

## Tracked repositories

The list lives in a plain text file, `~/.config/omarchy-github-monitor/repos.txt`,
one `owner/repo` per line, `#` comments and blank lines ignored. This is the
format `github_monitor.py` already reads from `~/.github_repos.txt`.

It is deliberately not a `manifest.json` setting. A nineteen-entry list is
miserable to edit in a settings text field, and two places holding the list
would compete for authority.

Three ways to change it, all writing that one file:

```bash
omarchy-github-monitor list
omarchy-github-monitor add foo/bar
omarchy-github-monitor add https://github.com/foo/bar   # URL accepted
omarchy-github-monitor remove foo/bar
```

`add` fetches the repository's atom feed before writing. A `404` means the
repository does not exist or has published no releases, and it is refused with
that reason rather than becoming a permanently empty row. On success it
triggers a refresh so the widget updates at once.

### Search

`omarchy-github-monitor search <query>` queries
`https://api.github.com/search/repositories`, prints numbered results with star
counts and descriptions, and `add <n>` takes one.

This is the only place the plugin touches the REST API. It is affordable
because search has its own budget — **10 requests per minute** unauthenticated,
independent of the 60/hour core limit that ruled the API out for polling.

The rule that keeps it within that budget: **search runs on Enter, never on
keystroke.** In the panel this means a field and a button, not a live filter.

GitHub's search qualifiers pass through untouched, so `topic:selfhosted
stars:>1000` and `user:immich-app` work with no extra code.

Results feed the same `add` path, so a repository without releases cannot be
added through search either.

## Settings schema

Exposed through `manifest.json` so they are editable in the bar's settings UI.
Scalars only; the repository list is the file above.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `pollMinutes` | integer | 15 | timer interval |
| `newWindowHours` | integer | 24 | how long a release counts as new |
| `overdueFactor` | number | 1.5 | cadence multiplier before the warning |
| `includePrereleases` | boolean | false | count `-rc` / `-beta` tags as releases |
| `notify` | boolean | true | desktop notification on a newly seen tag |
| `showOverdue` | boolean | true | the `⚠` badge |

## Notifications

A tag not present in the previous state fires `omarchy-notification-send`. The
old script's hand-rolled `send_notification` is dropped.

Only fires for tags newer than `generated_at` of the previous run, so the first
run after installation does not emit 19 notifications.

## Security

Release notes are third-party text rendered inside the user's bar. The daemon
strips HTML to plain text before it reaches the state file; QML renders it as
plain text, never `RichText`. Feed XML is parsed with the standard library.

## Code disposition

From `github_monitor.py` (1402 lines):

**Kept, adapted to the feed:** `get_latest_release`, `get_last_releases`,
`avg_days_between_releases`, `parse_iso8601`, `human_age`,
`release_within_hours`, `fetch_repo_summary`, `load_repos`. `load_state` and
`save_state` are kept but repurposed: they read and write `state.json`, which
now serves as both the widget's input and the daemon's memory of which tags it
has already seen.

**Kept, token-gated:** `gh_get`, `get_commit_count`, `commits_since_latest`,
`avg_commits_between_releases`.

**Deleted (~700 lines):** `Colors`, `Box`, `print_banner`, `section_header`,
`_visible_len`, `box_table`, `ascii_table`, `render_menu`, `interactive_menu`,
`show_repo_details`, `stats_dashboard`, `input_with_timeout`,
`prompt_refresh_interval`, `get_status_icon`, `format_repo_line`,
`clear_screen`, `open_repo_site`, `RefreshSession`, `send_notification`.

The `requests` dependency goes with them: `urllib.request` and
`xml.etree.ElementTree` are standard library, and nothing else needed it.

## Testing

One `test_github_monitor.py`, asserts only, no network, no framework. Fixture
feeds captured from real repositories.

Covers the logic that can silently produce a wrong badge:

- `avg_days_between_releases` over a known series
- the overdue predicate, including the fewer-than-3-releases case
- `parse_iso8601` on the feed's timestamp format
- prerelease inference from tag names
- a malformed feed leaves the previous entry intact

## Phases

1. Daemon: feed fetching, computation, state file, tests. Verifiable with
   `cat state.json` before any QML exists.
2. Manifest and bar widget: count, badges, theme colors.
3. Popup panel: repository list, release notes, add and search views.
4. Timer, `bootstrap`, notifications.
5. Token-gated enrichment (commits since tag, exact prerelease).

`list` / `add` / `remove` / `search` ship in phase 1 as CLI subcommands and are
usable before any QML exists; phase 3 puts a front end on the same code.

Phase 1 stands alone. Each later phase is usable without the ones after it.

## Out of scope

- Issues, pull requests, stars, CI status. `gh-dash` covers those.
- Repositories outside github.com.
- Syncing tracked repositories between machines.
