package claudebridge

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
