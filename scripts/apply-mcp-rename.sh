#!/usr/bin/env bash
# Reapply the magpie-my MCP surface rename onto a yetone/magpie tree.
# Idempotent: a tree that already uses the my surface is left as it is.
# Exits 1 when a required bridge site is neither the old form nor the new
# one (upstream moved it); the sync workflow then asks the OpenCode agent.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

python3 - <<'PY'
import pathlib, re, sys

root = pathlib.Path(".")
missing = []

def read(path):
    return pathlib.Path(path).read_text()

def write(path, text):
    pathlib.Path(path).write_text(text)

def sub(text, old, new, label, marker=None):
    """Replace old with new once. Already-applied when marker (default new) is present.
    marker must be text gofmt will not reflow away."""
    if old in text:
        return text.replace(old, new, 1)
    mark = new if marker is None else marker
    if mark in text:
        return text
    missing.append(label)
    return text

SURFACE = r'''package claudebridge

// Names the run's Claude Code is given for this bridge's MCP server.
// Claude Code calls a server's tools mcp__<server>__<tool>, and that
// string is what a subscription request sends on. The server key is my,
// so those calls are mcp__my__…, not mcp__magpie__….

// MCPServer is the key in the run's --mcp-config mcpServers object, and
// the name initialize reports as serverInfo.name.
const MCPServer = "my"

// MCPPrefix is the tool-name prefix the run's Claude Code uses.
const MCPPrefix = "mcp__" + MCPServer + "__"

// AllowedTools is the --allowedTools entry for this server. Claude Code
// matches the server by the prefix without the trailing underscores.
const AllowedTools = "mcp__" + MCPServer

// CallerLibraryPrefix is one prefix a caller has already applied to a
// Library tool (that caller's own server key for the Library). The bridge
// strips one such layer before MCPPrefix is added, so the run is not
// offered the caller's prefix again. The bridge's own server key stays my.
const CallerLibraryPrefix = "mcp__magpie__"
'''
write("internal/claudebridge/surface.go", SURFACE)

# --- claude_subscription.go: structural edits before the literal sweep ---
p = "internal/gateway/claude_subscription.go"
text = read(p)
old_imp = '\t"github.com/yetone/magpie/internal/claudecode"\n'
new_imp = old_imp + '\t"github.com/yetone/magpie/internal/claudebridge"\n'
if "internal/claudebridge\"" not in text:
    if old_imp not in text:
        missing.append("claude_subscription import anchor")
    else:
        text = text.replace(old_imp, new_imp, 1)

text = sub(text, 'const waitTool = "magpie_wait"', 'const waitTool = "my_wait"', "waitTool")

text = sub(
    text,
    '\t\t"magpie": map[string]any{"command": exe, "args": []string{claudetui.MCPCommand, callbackPath, toolsPath, filepath.Join(tmp, "listed")}},',
    '\t\tclaudebridge.MCPServer: map[string]any{"command": exe, "args": []string{claudetui.MCPCommand, callbackPath, toolsPath, filepath.Join(tmp, "listed")}},',
    "mcpServers key",
)

text = sub(
    text,
    'rest, ok := strings.CutPrefix(name, "mcp__magpie__")',
    "rest, ok := cutBridgePrefix(name)",
    "toolStart prefix",
    marker="cutBridgePrefix(name)",
)
text = sub(
    text,
    'name, _ = toolStart(0, "mcp__magpie__"+name)',
    'name, _ = toolStart(0, claudebridge.MCPPrefix + name)',
    "onCall prefix",
    marker="toolStart(0, claudebridge.MCPPrefix",
)
text = sub(
    text,
    'strings.HasPrefix(c.Name, "mcp__magpie__")',
    "strings.HasPrefix(c.Name, claudebridge.MCPPrefix)",
    "transcript prefix",
)

old_bridge = '''func bridgeName(name string) string {
	return "mcp__magpie__" + bridgeToolName(name)
}'''
new_bridge = '''func bridgeName(name string) string {
	return claudebridge.MCPPrefix + bridgeToolName(name)
}

// cutBridgePrefix strips the prefix on a tool call from the run's Claude
// Code. The run calls the bridge's tools with MCPPrefix. A call that
// instead carries the caller's Library prefix (a deferred tool named in
// the client's text) has that one layer stripped; toolStart hands the
// full name back when it is not one of the tools the client loaded.
func cutBridgePrefix(name string) (string, bool) {
	if rest, ok := strings.CutPrefix(name, claudebridge.MCPPrefix); ok {
		return rest, true
	}
	return strings.CutPrefix(name, claudebridge.CallerLibraryPrefix)
}'''
if old_bridge in text:
    text = text.replace(old_bridge, new_bridge, 1)
elif "func cutBridgePrefix(" not in text or "claudebridge.MCPPrefix + bridgeToolName(name)" not in text:
    missing.append("bridgeName")

old_tool = '''// bridgeToolName is the name the MCP helper offers a tool of the caller's
// under. Claude Code takes an MCP tool's name as [A-Za-z0-9_-] only, with
// mcp__magpie__ before it in at most 64: it made "spawn.agent" its
// spawn_agent, which the client never offered (#2649). A name it would
// change, or one ending as a changed name ends, is told apart by a hash of
// it, the same in every run, so a resumed session and a conversation's
// history name the tool as before; declaredName maps it back.
//
// A tool of magpie's own MCP server, which the client (Claude Code with
// magpie's Library) already names mcp__magpie__<server>__<tool>, is
// offered under the rest of its name: with the helper's mcp__magpie__
// before it again, the run's model was shown
// mcp__magpie__mcp__magpie__magpie-browser__browser_click, while a
// deferred tool the client named in its text kept the single prefix
// (packinggoods on Discord, 11-01). The model now sees the client's own
// name. A client offering both "mcp__magpie__x" and a bare "x" would
// have the two offered alike, which this doesn't tell apart.
func bridgeToolName(name string) string {
	if rest, ok := strings.CutPrefix(name, "mcp__magpie__"); ok && bridgeToolNameOK.MatchString(rest) && !bridgeToolNameHashed.MatchString(rest) {'''
new_tool = '''// bridgeToolName is the name the MCP helper offers a tool of the caller's
// under. Claude Code takes an MCP tool's name as [A-Za-z0-9_-] only, with
// the bridge prefix before it in at most 64: it made "spawn.agent" its
// spawn_agent, which the client never offered (#2649). A name it would
// change, or one ending as a changed name ends, is told apart by a hash of
// it, the same in every run, so a resumed session and a conversation's
// history name the tool as before; declaredName maps it back. Names stay
// within 51 characters, so the bridge prefix plus the name stays within 64.
//
// A tool the caller already named with one Library prefix
// (CallerLibraryPrefix, then <server>__<tool>) is offered under the rest
// of its name. The bridge adds its own prefix, so the run is shown one
// prefix and not the caller's prefix again. A deferred tool the client
// named in its text keeps the caller's prefix; cutBridgePrefix still
// recognizes that layer (packinggoods on Discord, 11-01). A client
// offering both a prefixed name and the same name bare would have the two
// offered alike, which this doesn't tell apart.
func bridgeToolName(name string) string {
	if rest, ok := strings.CutPrefix(name, claudebridge.CallerLibraryPrefix); ok && bridgeToolNameOK.MatchString(rest) && !bridgeToolNameHashed.MatchString(rest) {'''
text = sub(text, old_tool, new_tool, "bridgeToolName")
write(p, text)

# --- search collision name ---
p = "internal/gateway/search.go"
text = read(p)
text = sub(
    text,
    '''// searchTool is the tool a model that can't search is given, under a name
// the client's own tools leave free.
func searchTool(tools []Tool) Tool {
	name := "web_search"
	for slices.ContainsFunc(tools, func(t Tool) bool { return t.Name == name }) {
		name = "magpie_" + name
	}''',
    '''// searchTool is the tool a model that can't search is given, under a name
// the client's own tools leave free. A taken web_search becomes
// my_web_search, and my_ again if that is taken too. The Claude bridge
// offers this name on its MCP server.
func searchTool(tools []Tool) Tool {
	name := "web_search"
	for slices.ContainsFunc(tools, func(t Tool) bool { return t.Name == name }) {
		name = "my_" + name
	}''',
    "searchTool",
)
write(p, text)

# --- helper serverInfo ---
p = "internal/claudebridge/mcp.go"
text = read(p)
text = sub(
    text,
    '"serverInfo":      map[string]any{"name": "magpie", "version": "1"},',
    '"serverInfo":      map[string]any{"name": MCPServer, "version": "1"},',
    "serverInfo",
)
write(p, text)

# --- interactive allowedTools and the server-key comment ---
p = "internal/claudetui/tui.go"
text = read(p)
imp = '\t"github.com/yetone/magpie/internal/appdir"\n'
if "internal/claudebridge\"" not in text:
    if imp not in text:
        missing.append("claudetui import anchor")
    else:
        text = text.replace(imp, imp + '\t"github.com/yetone/magpie/internal/claudebridge"\n', 1)
text = sub(text, 'allowed := []string{"mcp__magpie"}', "allowed := []string{claudebridge.AllowedTools}", "allowedTools")
write(p, text)

p = "internal/claudetui/command.go"
text = read(p)
text = sub(
    text,
    '// server a run\'s --mcp-config names "magpie" (claudebridge.RunMCP). Its',
    '// server a run\'s --mcp-config names "my" (claudebridge.MCPServer). Its',
    "command comment",
)
write(p, text)

# --- shim test's mcp-config key; the command is still the magpie binary ---
p = "internal/claudetui/tui_test.go"
text = read(p)
text = sub(
    text,
    '\t\t"magpie": map[string]any{"command": "magpie", "args": []string{MCPCommand, "callback", "tools.json", listed}},',
    '\t\t"my": map[string]any{"command": "magpie", "args": []string{MCPCommand, "callback", "tools.json", listed}},',
    "shim mcp-config key",
)
write(p, text)

# --- keep the Library-name test's inputs; rewrite what the run is shown ---
p = "internal/gateway/claude_tool_names_test.go"
text = read(p)
old_comment = '''// packinggoods (Discord, 11-01): Claude Code with magpie's Library MCP
// names its tools mcp__magpie__<server>__<tool>, and through the Claude
// bridge the run's model was shown
// mcp__magpie__mcp__magpie__magpie-browser__browser_click for each tool
// sent up front, while the deferred ones its text named kept one prefix.
// The run's Claude Code is offered each such tool under the client's own
// name, in the tool list, a tool choice and the history alike, and a call
// of it comes back under the declared name.'''
new_comment = '''// packinggoods (Discord, 11-01): a client whose Library server key is
// magpie declares those tools with that prefix plus <server>__<tool>.
// The bridge strips one such layer and offers the tool under its own
// server, so the run is shown a single prefix. History and tool choice
// use that offered name. A call comes back under the declared name.'''
if old_comment in text:
    text = text.replace(old_comment, new_comment, 1)
elif "strips one such layer" not in text:
    missing.append("library-name test comment")

def split_func(text, name):
    sig = f"func {name}("
    i = text.find(sig)
    if i < 0:
        return None
    brace = text.find("{", i)
    depth = 0
    for j in range(brace, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[:i], text[i:j + 1], text[j + 1:]
    missing.append(f"unbalanced {name}")
    return None

parts = split_func(text, "TestClaudeBridgeKeepsMagpieMCPNames")
if parts:
    head, func, tail = parts
    old_seen = '''\t\tseen := "mcp__magpie__" + offer.Name
		if strings.HasPrefix(n, "mcp__magpie__") && seen != n {
			t.Errorf("%s is shown to the run's model as %s", n, seen)
		}
		if strings.Contains(seen, "mcp__magpie__mcp__magpie__") {
			t.Errorf("%s is offered with mcp__magpie__ twice: %s", n, seen)
		}'''
    new_seen = '''\t\tseen := "mcp__my__" + offer.Name
		if strings.HasPrefix(n, "mcp__magpie__") { // mcp-rename-keep
			rest := strings.TrimPrefix(n, "mcp__magpie__") // mcp-rename-keep
			if seen != "mcp__my__" + rest {
				t.Errorf("%s is shown to the run's model as %s, want one bridge prefix", n, seen)
			}
		}
		if strings.Contains(seen, "mcp__my__mcp__magpie__") || strings.Contains(seen, "mcp__magpie__mcp__magpie__") { // mcp-rename-keep
			t.Errorf("%s is offered with the caller's prefix twice: %s", n, seen)
		}'''
    func2 = sub(func, old_seen, new_seen, "library-name assertions", marker="want one bridge prefix")
    func2 = sub(
        func2,
        '''\tif !strings.Contains(text.String(), "[tool call "+declared[0]+" id=c1 ") {
		t.Errorf("history tells %s as %q", declared[0], text.String())
	}
	req.ToolChoice = "name:" + declared[0]
	if got := toolChoiceAsk(req); !strings.Contains(got, "You must call the "+declared[0]+" tool.") {
		t.Errorf("tool choice %q", got)
	}''',
        '''\twantCall := "[tool call " + bridgeName(declared[0]) + " id=c1 "
	if !strings.Contains(text.String(), wantCall) {
		t.Errorf("history tells %s as %q, want %q", declared[0], text.String(), wantCall)
	}
	req.ToolChoice = "name:" + declared[0]
	if got := toolChoiceAsk(req); !strings.Contains(got, "You must call the "+bridgeName(declared[0])+" tool.") {
		t.Errorf("tool choice %q", got)
	}''',
        "library-name history",
        marker="bridgeName(declared[0])",
    )
    func2 = re.sub(
        r'("mcp__magpie__[^"]+")(,)(?![^\n]*mcp-rename-keep)',
        r'\1\2 // mcp-rename-keep',
        func2,
    )
    text = head + func2 + tail
write(p, text)

# --- unloaded tool: bridge calls use my; the client's names stay ---
p = "internal/gateway/claude_unloaded_tool_test.go"
text = read(p)
text = sub(
    text,
    '''// Claude Code with tool search on tells its model a deferred MCP tool by
// name only ("The following deferred tools are now available via
// ToolSearch… mcp__magpie__magpie-web-search__web_search") and leaves it out
// of tools until a ToolSearch loads it. The run's model calls it as told,
// under the full name, and the client is handed that name, which it runs:''',
    '''// Claude Code with tool search on tells its model a deferred MCP tool by
// name only and leaves it out of tools until a ToolSearch loads it. The
// run's model calls that tool by the name in the client's text. The
// bridge's own calls use its server prefix. The client is handed that
// call under the full name, which it runs:''',
    "unloaded comment",
    marker="bridge's own calls use its server prefix",
)
text = sub(
    text,
    "    *call-browser*) name=mcp__magpie__magpie-browser__browser_click ;;",
    "    *call-browser*) name=mcp__my__magpie-browser__browser_click ;;",
    "unloaded browser call",
)
text = sub(
    text,
    "    *) name=mcp__magpie__Read ;;",
    "    *) name=mcp__my__Read ;;",
    "unloaded read call",
)
# caller fixtures: mark them so the gate and a later sweep leave them
marker = "// mcp-rename-keep: caller Library name, not the bridge prefix\n"
if marker.strip() not in text.split("script :=", 1)[0]:
    text = text.replace("\tscript := `#!/bin/sh\n", "\t" + marker + "\tscript := `#!/bin/sh\n", 1)
if "mcp-rename-keep: the client's loaded and announced Library tools" not in text:
    text = text.replace(
        "\ttools := `",
        "\t// mcp-rename-keep: the client's loaded and announced Library tools\n\ttools := `",
        1,
    )
# Mark the expected client names. The tools JSON uses the same bytes
# without this map-line context, and a comment inside it would be sent
# as the tool list.
def mark_line(text, line, label):
    marked = line + " // mcp-rename-keep"
    if marked in text:
        return text
    if line not in text:
        missing.append(label)
        return text
    return text.replace(line, marked, 1)

text = mark_line(
    text,
    '\t\t"call-search: search the web for magpie": "mcp__magpie__magpie-web-search__web_search",',
    "unloaded search expectation",
)
text = mark_line(
    text,
    '\t\t"call-browser: click the button":         "mcp__magpie__magpie-browser__browser_click",',
    "unloaded browser expectation",
)
write(p, text)

# --- literal sweep of the bridge prefix the run emits ---
skip_files = {
    "internal/claudebridge/surface.go",
    "internal/gateway/claude_unloaded_tool_test.go",
    "internal/gateway/mcp_surface_test.go",
    "scripts/apply-mcp-rename.sh",
    "scripts/mcp-rename-gate.sh",
    "docs/subsystems/claude-subscription-bridge.md",
    ".github/workflows/sync-upstream.yml",
}

def mask_keep_func(text):
    parts = split_func(text, "TestClaudeBridgeKeepsMagpieMCPNames")
    if not parts:
        return text, None
    head, func, tail = parts
    return head + "/*MCP_RENAME_HOLD*/" + tail, func

def sweep_file(path: pathlib.Path):
    rel = path.as_posix()
    if rel in skip_files or rel.startswith("scripts/"):
        return
    text = path.read_text(errors="replace")
    if "mcp__magpie" not in text:
        return
    held = None
    if rel == "internal/gateway/claude_tool_names_test.go":
        text, held = mask_keep_func(text)
    text2 = text.replace("mcp__magpie__", "mcp__my__")
    text2 = re.sub(r"mcp__magpie(?!_)", "mcp__my", text2)
    if held is not None:
        text2 = text2.replace("/*MCP_RENAME_HOLD*/", held, 1)
    if text2 != text:
        path.write_text(text2)

for path in root.rglob("*"):
    if not path.is_file():
        continue
    if any(part in {".git", "vendor"} for part in path.parts):
        continue
    if path.suffix not in {".go", ".md", ".js"}:
        continue
    sweep_file(path)

# --- docs that state the bridge prefix ---
p = "docs/subsystems/claude-subscription-bridge.md"
text = read(p)
text = sub(
    text,
    "which Claude Code calls `mcp__magpie__<name>`.",
    "which Claude Code calls `mcp__my__<name>`.",
    "doc bridge prefix",
)
text = sub(
    text,
    "one longer than 51 (64 with the prefix) or one\nending as a changed name ends",
    "one longer than 51 (the bridge prefix plus the\nname stays within Claude Code's 64) or one ending as a changed name ends",
    "doc length",
    marker="name stays within Claude Code's 64",
)
old_para = '''A client's MCP tool that it announced but hasn't loaded (Claude Code's
tool search names deferred tools in a reminder and leaves them out of
`tools` until `ToolSearch` loads them) is no tool of the run's, but the
run's model reads its name in the conversation and calls it,
`mcp__magpie__<server>__<tool>`. `toolStart` hands that call over under
the full name, which is the client's own, when the cut name maps to
nothing and isn't in `subscriptionRun.tools`: handed over cut, as
`<server>__<tool>`, the client answered "No such tool available" and the
model had to load it and call again (packinggoods, 11-02,
`TestClaudeBridgeHandsOverAnUnloadedMagpieTool`). A deferred tool of
another client MCP server (`mcp__linear__…`) is still not handed over.'''
new_para = '''A client's MCP tool that it announced but hasn't loaded (Claude Code's
tool search names deferred tools in a reminder and leaves them out of
`tools` until `ToolSearch` loads them) is no tool of the run's, but the
run's model reads its name in the conversation and calls it. A Library
tool the caller already named `mcp__magpie__<server>__<tool>` keeps that
name in the client's text. `bridgeToolName` strips one such layer, and
the bridge's own prefix makes the offered name `mcp__my__<server>__<tool>`,
so the run is not shown the caller's prefix again. `toolStart`
(`cutBridgePrefix`) accepts either the bridge prefix or that one caller
layer, and hands an unloaded call over under the full name the model
used, which is the client's own, when the cut name maps to nothing and
isn't in `subscriptionRun.tools`: handed over cut, as `<server>__<tool>`,
the client answered "No such tool available" and the model had to load it
and call again (packinggoods, 11-02,
`TestClaudeBridgeHandsOverAnUnloadedMagpieTool`). A deferred tool of
another client MCP server (`mcp__linear__…`) is still not handed over.'''
text = sub(text, old_para, new_para, "doc unloaded tools")
text = sub(
    text,
    "The run's MCP server is magpie itself (`magpie claude-mcp-helper`,\n`internal/claudebridge`), which hands each tool call back to the gateway",
    "The run's MCP server key is `my` (`serverInfo.name`, `--mcp-config`). The\nhelper is still `magpie claude-mcp-helper`\n(`internal/claudebridge`), which hands each tool call back to the gateway",
    "doc server key",
    marker="The run's MCP server key is `my`",
)
text = sub(
    text,
    "--allowedTools mcp__magpie[,WebSearch]",
    "--allowedTools mcp__my[,WebSearch]",
    "doc allowedTools",
)
text = sub(
    text,
    "only magpie's MCP tools",
    "only the bridge's MCP tools",
    "doc allowed prose",
)
text = sub(
    text,
    "called `mcp__magpie__StructuredOutput`",
    "called `mcp__my__StructuredOutput`",
    "doc structured output",
)
text = sub(
    text,
    "[tool call mcp__magpie__Bash",
    "[tool call mcp__my__Bash",
    "doc text call",
)
write(p, text)

# --- surface test, written once ---
# Written after the sweep, and skipped by it: the caller prefix here is
# the constant, so a literal sweep cannot turn the assertion inside out.
pathlib.Path("internal/gateway/mcp_surface_test.go").write_text('''package gateway

import (
	"strings"
	"testing"

	"github.com/yetone/magpie/internal/claudebridge"
)

// The bridge's Claude-facing MCP names are the my surface: server key my,
// tool prefix mcp__my__, collision tools my_web_search and my_wait.
// A Library tool the caller already prefixed is offered with one my
// prefix, not the caller's prefix again.
func TestMCPSurfaceNames(t *testing.T) {
	if claudebridge.MCPServer != "my" || claudebridge.MCPPrefix != "mcp__my__" || claudebridge.AllowedTools != "mcp__my" {
		t.Fatalf("bridge surface %s %s %s", claudebridge.MCPServer, claudebridge.MCPPrefix, claudebridge.AllowedTools)
	}
	if got := bridgeName("Bash"); got != "mcp__my__Bash" {
		t.Fatalf("bridgeName Bash = %s", got)
	}
	caller := claudebridge.CallerLibraryPrefix + "magpie-browser__browser_click"
	got := bridgeName(caller)
	if got != claudebridge.MCPPrefix+"magpie-browser__browser_click" {
		t.Fatalf("bridgeName library tool = %s", got)
	}
	if strings.Contains(got, claudebridge.CallerLibraryPrefix) {
		t.Fatalf("library tool offered with the caller's prefix: %s", got)
	}
	if strings.Contains(got, claudebridge.MCPPrefix+claudebridge.MCPPrefix) {
		t.Fatalf("library tool offered with the bridge prefix twice: %s", got)
	}
	if waitTool != "my_wait" {
		t.Fatalf("wait tool %s", waitTool)
	}
	if name := searchTool([]Tool{{Name: "web_search"}}).Name; name != "my_web_search" {
		t.Fatalf("search collision name %s", name)
	}
	if name := searchTool(nil).Name; name != "web_search" {
		t.Fatalf("search tool with no collision = %s", name)
	}
}
''')

# Keep a vX.Y.Z-my tag from driving the upstream release and image workflows
# when that tag is pushed by something other than this fork's GITHUB_TOKEN.
def exclude_my_tag(path):
    file = pathlib.Path(path)
    if not file.exists():
        return
    text = file.read_text()
    if "!v*-my" in text:
        return
    if "tags: ['v*']" in text:
        text = text.replace("tags: ['v*']", "tags:\n      - 'v*'\n      - '!v*-my'", 1)
    elif "      - 'v*'\n" in text:
        text = text.replace("      - 'v*'\n", "      - 'v*'\n      - '!v*-my'\n", 1)
    else:
        missing.append(f"tag filter in {path}")
        return
    file.write_text(text)

exclude_my_tag(".github/workflows/docker.yml")
exclude_my_tag(".github/workflows/release.yml")

if missing:
    print("apply-mcp-rename: required site not in the old or the new form:", file=sys.stderr)
    for m in missing:
        print(" -", m, file=sys.stderr)
    sys.exit(1)
print("apply-mcp-rename: ok")
PY

gofmt -w \
	internal/claudebridge/surface.go \
	internal/claudebridge/mcp.go \
	internal/claudetui/tui.go \
	internal/claudetui/command.go \
	internal/claudetui/tui_test.go \
	internal/gateway/claude_subscription.go \
	internal/gateway/search.go \
	internal/gateway/claude_tool_names_test.go \
	internal/gateway/claude_unloaded_tool_test.go \
	internal/gateway/mcp_surface_test.go
