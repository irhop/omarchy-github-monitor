#!/usr/bin/bash
# Sets up the poll timer and puts the widget on the bar.
#
# Running this is one of the two ways to consent to the timer being installed;
# the other is the button in the panel. Installing through `omarchy plugin add`
# runs neither and installs nothing: enabling the plugin gets you a widget that
# reads a file, and that is all.
#
# See what it would do first with:
#     bin/omarchy-github-monitor bootstrap --dry-run
set -euo pipefail

PLUGIN_ID="io.github.irhop.github-monitor"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Absolute paths, so that what this runs does not depend on PATH order.
SYSTEMCTL=/usr/bin/systemctl
OMARCHY_BIN=/usr/share/omarchy/bin

"$PLUGIN_DIR/bin/omarchy-github-monitor" bootstrap
"$SYSTEMCTL" --user --no-pager --lines=0 status omarchy-github-monitor.timer || true

echo "==> Bar widget"
"$OMARCHY_BIN/omarchy-shell" shell rescanPlugins >/dev/null 2>&1 || true
"$OMARCHY_BIN/omarchy" plugin enable "$PLUGIN_ID" --section right || true

echo
echo "Nothing is tracked yet. Add something to watch:"
echo "    $PLUGIN_DIR/bin/omarchy-github-monitor add owner/repo"
echo "    $PLUGIN_DIR/bin/omarchy-github-monitor search <words>"
echo "or click + in the panel."
