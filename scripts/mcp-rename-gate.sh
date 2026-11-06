#!/usr/bin/env bash
# Gate for the magpie-my MCP surface rename.
# Fails when the bridge still emits mcp__magpie, or the server key /
# allowedTools / serverInfo are not my. Warns, and does not fail, on a
# bare __magpie__ outside the path-like allowlist.
set -euo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root"

fail=0
say() { printf '%s\n' "$*" >&2; }

# Lines that may still contain the caller's Library prefix. The bridge
# does not emit that prefix; it strips one such layer off incoming names.
allow_line() {
	local line=$1
	case "$line" in
	*mcp-rename-keep*) return 0 ;;
	esac
	return 1
}

allow_path() {
	case "$1" in
	internal/claudebridge/surface.go) return 0 ;;
	scripts/apply-mcp-rename.sh | scripts/mcp-rename-gate.sh) return 0 ;;
	docs/subsystems/claude-subscription-bridge.md) return 0 ;;
	.github/workflows/sync-upstream.yml) return 0 ;;
	esac
	return 1
}

# A hit is allowed when its line, or a comment within the previous 8
# lines, carries mcp-rename-keep. That covers a caller-prefix fixture
# inside a raw string just under the marker.
hits=$(rg -n --no-heading 'mcp__magpie' . \
	-g '!vendor/**' -g '!.git/**' || true)
while IFS= read -r hit; do
	[ -n "$hit" ] || continue
	file=${hit%%:*}
	file=${file#./}
	rest=${hit#*:}
	num=${rest%%:*}
	if allow_path "$file"; then
		continue
	fi
	start=$((num - 8))
	[ "$start" -lt 1 ] && start=1
	window=$(sed -n "${start},${num}p" "$file")
	if allow_line "$window"; then
		continue
	fi
	say "gate: mcp__magpie remains: $hit"
	fail=1
done <<< "$hits"

sub() {
	local file=$1 pat=$2 what=$3
	if [ ! -f "$file" ] || ! rg -q --fixed-strings "$pat" "$file"; then
		say "gate: $what missing in $file"
		fail=1
	fi
}

sub internal/gateway/claude_subscription.go 'claudebridge.MCPServer:' 'mcpServers key my'
sub internal/gateway/claude_subscription.go 'claudebridge.MCPPrefix' 'bridge prefix mcp__my__'
sub internal/gateway/claude_subscription.go 'claudebridge.CallerLibraryPrefix' 'caller Library prefix strip'
sub internal/gateway/claude_subscription.go 'const waitTool = "my_wait"' 'wait tool my_wait'
sub internal/gateway/search.go 'name = "my_" + name' 'search collision prefix my_'
sub internal/claudebridge/mcp.go '"name": MCPServer' 'serverInfo.name my'
sub internal/claudetui/tui.go 'claudebridge.AllowedTools' 'allowedTools mcp__my'
sub internal/claudetui/command.go 'names "my"' 'mcp-config server key documented as my'

# Warn-only: __magpie__ in the bridge packages that is not the caller
# prefix and not a path we keep (accounts, work dirs, the callback route).
warn_allow='magpie-claude|/_magpie/|claude-accounts|mcp-rename-keep|CallerLibraryPrefix|mcp__magpie'
while IFS= read -r hit; do
	[ -n "$hit" ] || continue
	line=${hit#*:*:}
	if printf '%s' "$line" | rg -q "$warn_allow"; then
		continue
	fi
	say "warn: bare __magpie__ (not failing): $hit"
done < <(rg -n --no-heading '__magpie__' \
	internal/gateway/claude_subscription.go \
	internal/claudebridge internal/claudetui \
	-g '!*_test.go' || true)

if [ "$fail" -ne 0 ]; then
	say "gate: failed"
	exit 1
fi
say "gate: passed"
