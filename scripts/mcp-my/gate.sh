#!/usr/bin/env bash
set -euo pipefail
trap 'echo "MCP gate failed at line $LINENO (exit $?)" >&2' ERR

cd "$(git rev-parse --show-toplevel)"
: "${UPSTREAM_SHA:?Set UPSTREAM_SHA to the upstream release commit}"
test ! -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)"
test -z "$(git ls-files -u)"
git merge-base --is-ancestor "$UPSTREAM_SHA" HEAD
if ! git diff --quiet "$UPSTREAM_SHA" -- docs/; then
  echo "Forbidden docs/ changes relative to $UPSTREAM_SHA" >&2
  exit 1
fi

python3 - <<'PY'
import fnmatch
import json
import os
from pathlib import Path
import subprocess
import sys

# JSON is a YAML subset, so the manifest needs no Python YAML dependency.
manifest = json.loads(Path('scripts/mcp-my/surface.manifest.yml').read_text())
def paths(*args):
    return set(subprocess.check_output(['git', *args]).decode().split('\0')) - {''}

changed = paths('diff', '--no-renames', '--name-only', '-z', os.environ['UPSTREAM_SHA'])
changed |= paths('ls-files', '--others', '--exclude-standard', '-z')
errors = []
for name in sorted(changed):
    if any(fnmatch.fnmatchcase(name, pat) for pat in manifest['forbidden_paths']):
        errors.append(f'Forbidden rename path: {name}')
    elif not any(fnmatch.fnmatchcase(name, pat) for pat in manifest['allowed_paths']):
        errors.append(f'Unexpected rename file: {name}')
if errors:
    sys.exit('\n'.join(errors))
PY

export GOPATH="$(go env GOPATH)" GOMODCACHE="$(go env GOMODCACHE)" GOCACHE="$(go env GOCACHE)"
task_home=$(mktemp -d)
trap 'chmod -R u+w "$task_home"; rm -rf "$task_home"' EXIT
env HOME="$task_home" go test -tags nogui ./internal/claudebridge ./internal/claudetui ./internal/gateway -run 'TestMCPSurface|TestClaudeToolNamesComeBackAsDeclared|TestClaudeBridgeKeepsMagpieMCPNames|TestClaudeBridgeHandsOverAnUnloadedMagpieTool|TestSearchToolCollisionUsesMy|TestClaudeWaitToolUsesMy|TestNewToolsListedBeforeTheAnswer|TestShimTurnsInteractive' -count=1 >&2
