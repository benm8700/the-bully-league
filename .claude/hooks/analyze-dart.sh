#!/bin/bash
# After Claude edits a .dart file, run the analyzer on it and hand any
# issues back to Claude (exit 2 = stderr is shown to Claude).
f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty')
case "$f" in *.dart) ;; *) exit 0 ;; esac
[ -f "$f" ] || exit 0
out=$("$HOME/development/flutter/bin/flutter" analyze --no-pub "$f" 2>&1)
if echo "$out" | grep -qE '^\s*(error|warning|info) •'; then
  echo "flutter analyze found issues in $f:" >&2
  echo "$out" | grep -E '^\s*(error|warning|info) •' >&2
  exit 2
fi
exit 0
