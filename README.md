# GitHub Release Monitor

An Omarchy bar widget that watches the projects you depend on and tells you
when one ships — or when one has gone quiet for longer than it usually does.

```
 19          nothing new
 3 ●         releases in the last day
 19 ⚠2       repositories past their own release cadence
```

Click for the list and the release notes. Middle click polls now.

## What clicks do

In the bar:

| | |
| --- | --- |
| left click | open the list |
| middle click | poll the feeds now |

In the list:

| | |
| --- | --- |
| left click | release notes for that repository |
| middle click | open the release on GitHub |
| right click | copy the release link |

In the notes view, four buttons: open the release, open the repository, copy
the tag, copy the release link.

There is deliberately no "copy the install command". A release feed says what
shipped, not how a project is installed — immich is a compose file, atuin a
shell script, syncthing a distro package. A guessed command would look
authoritative and be wrong. The tag and the links are what the feed actually
knows.

## No GitHub account required

Polling reads each repository's `releases.atom` feed, which is the web
endpoint rather than the REST API. That means no token, no login, and nothing
counted against the API's 60-requests-per-hour unauthenticated budget.
Nineteen repositories take about two seconds, and unchanged feeds answer
`304 Not Modified`.

If a token happens to be present — `GITHUB_TOKEN`, `GH_TOKEN`, or `gh auth
token` — two extra fields appear: commits since the latest tag, and exact
prerelease flags. Nothing prompts you for one, and none is ever stored.

## Overdue

The feature no feed reader gives you. Each repository's own average gap
between releases is computed from its last ten, and one that has gone longer
than 1.5× that gap gets the warning. A project with fewer than three releases
has no established rhythm, so it is never marked overdue.

Tune the multiplier in the widget's settings.

## Install

```bash
omarchy plugin add https://github.com/irhop/omarchy-github-monitor.git --enable
~/.config/omarchy/plugins/io.github.irhop.github-monitor/bin/omarchy-github-monitor bootstrap
```

Enabling the plugin installs nothing on its own — you get a widget that reads
a file. `bootstrap` is what installs the systemd user timer that writes that
file, and `bootstrap --dry-run` shows exactly what it would do first.

## Tracked repositories

One `owner/repo` per line in `~/.config/omarchy-github-monitor/repos.txt`.
Edit it directly, or:

```bash
omarchy-github-monitor list
omarchy-github-monitor add immich-app/immich
omarchy-github-monitor add https://github.com/immich-app/immich  # URLs work
omarchy-github-monitor remove immich-app/immich
omarchy-github-monitor search paperless                          # then add one
omarchy-github-monitor status                                    # limits, auth
```

`add` checks the feed before writing, so a typo fails immediately instead of
becoming a row that is empty for reasons nobody remembers.

`search` is the only part that touches the REST API. It has its own budget —
ten requests a minute, unauthenticated — so it runs when you press Enter, not
as you type. GitHub's qualifiers work: `topic:selfhosted stars:>1000`.

## How it fits together

```
systemd timer ─▶ bin/omarchy-github-monitor fetch
                        │
                        ▼
       ~/.local/state/omarchy-github-monitor/state.json
                        │
                        ▼
              BarWidget.qml ─▶ Panel.qml
```

The daemon and the widget share nothing but that file. The widget makes no
network requests; the daemon draws nothing.

Release notes are third-party text, so the daemon flattens the HTML to plain
text and the panel renders it as plain text, never rich text.

## Development

```bash
./test_github_monitor.py      # no network, no framework
omarchy plugin validate .
```

Saving any file under `~/.config/omarchy/plugins/` reloads the shell's plugin
code. Changes to `manifest.json` defaults need `omarchy restart shell`.

## License

MIT
