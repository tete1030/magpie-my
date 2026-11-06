package gateway

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
