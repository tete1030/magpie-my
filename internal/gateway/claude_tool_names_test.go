package gateway

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/yetone/magpie/internal/provider"
	"github.com/yetone/magpie/internal/testenv"
)

// The manifest is the repair agent's map of bridge-owned names. Keep its
// assertions separate so a gate failure identifies the field and source site.
func TestMCPSurfaceContract(t *testing.T) {
	type site struct {
		Path   string `json:"path"`
		Code   string `json:"code"`
		Count  int    `json:"count"`
		Reason string `json:"reason,omitempty"`
	}
	var manifest struct {
		Surface map[string]struct {
			Value string `json:"value"`
			Sites []site `json:"sites"`
		} `json:"surface"`
		Legacy    []site   `json:"legacy_caller_literals"`
		Allowed   []string `json:"allowed_paths"`
		Forbidden []string `json:"forbidden_paths"`
	}
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Join(filepath.Dir(file), "..", "..")
	data, err := os.ReadFile(filepath.Join(root, "scripts/mcp-my/surface.manifest.yml"))
	if err != nil {
		t.Fatal(err)
	}
	// JSON is a YAML subset; both the Go contract and the shell gate read it
	// without another dependency.
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&manifest); err != nil {
		t.Fatalf("surface manifest: %v", err)
	}
	compact := func(s string) string { return strings.Join(strings.Fields(s), " ") }
	sources := map[string]string{}
	read := func(t *testing.T, path string) string {
		t.Helper()
		if src, ok := sources[path]; ok {
			return src
		}
		b, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			t.Fatal(err)
		}
		sources[path] = string(b)
		return string(b)
	}
	check := func(t *testing.T, s site) {
		t.Helper()
		if s.Code == "" || s.Count < 1 {
			t.Fatalf("invalid source site: %+v", s)
		}
		if got := strings.Count(compact(read(t, s.Path)), compact(s.Code)); got != s.Count {
			t.Errorf("%s: %q occurs %d times, want %d", s.Path, s.Code, got, s.Count)
		}
	}
	want := map[string]string{
		"serverKey": "my", "serverInfo": "my", "allowedTools": "mcp__my",
		"bridgePrefix": "mcp__my__", "waitTool": "my_wait", "searchCollision": "my_",
	}
	if len(manifest.Surface) != len(want) {
		t.Errorf("surface fields = %d, want %d", len(manifest.Surface), len(want))
	}
	for field, value := range want {
		t.Run(field, func(t *testing.T) {
			entry := manifest.Surface[field]
			if entry.Value != value || len(entry.Sites) == 0 {
				t.Fatalf("manifest value = %q, sites = %d; want %q and source sites", entry.Value, len(entry.Sites), value)
			}
			for _, s := range entry.Sites {
				check(t, s)
			}
		})
	}
	t.Run("legacyCaller", func(t *testing.T) {
		if len(manifest.Legacy) != 2 {
			t.Fatalf("legacy caller sites = %d, want exactly two caller-prefix consumers", len(manifest.Legacy))
		}
		allowed := map[string]bool{}
		for _, s := range manifest.Legacy {
			if s.Reason == "" {
				t.Errorf("legacy caller site %s needs a reason", s.Code)
			}
			check(t, s)
			allowed[s.Path+":"+compact(s.Code)] = true
		}
		for path, src := range sources {
			fs := token.NewFileSet()
			f, err := parser.ParseFile(fs, path, src, 0)
			if err != nil {
				t.Fatal(err)
			}
			lines := strings.Split(src, "\n")
			ast.Inspect(f, func(n ast.Node) bool {
				lit, ok := n.(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING || !strings.Contains(lit.Value, "mcp__magpie") {
					return true
				}
				pos := fs.Position(lit.Pos())
				code := compact(lines[pos.Line-1])
				if !allowed[path+":"+code] {
					t.Errorf("%s:%d: unexpected legacy caller literal: %s", path, pos.Line, code)
				}
				return true
			})
		}
	})
}

// #2649 (tsy0716): a tool the client named "spawn.agent" came back as
// "spawn_agent", a tool it never offered: Claude Code takes an MCP tool's
// name as [A-Za-z0-9_-] only, and changed it. Each tool is offered under a
// name Claude Code keeps, unique and short enough with mcp__magpie__ before
// it, and its calls are handed back under the name the client declared, on
// every API the bridge serves, streamed or whole.
func TestClaudeToolNamesComeBackAsDeclared(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("a shell script stands in for Claude Code")
	}
	long := "tools.example.com/" + strings.Repeat("very_long_segment.", 5) + "end"
	declared := []string{"spawn.agent", "fs/read", "has space", long, "a.b", "a_b", "mcp__magpie__magpie-browser__browser_click"}

	dir := t.TempDir()
	offered := filepath.Join(dir, "offered")
	// Claude Code as it treats an MCP tool's name: what isn't
	// [A-Za-z0-9_-] becomes "_". It calls every tool it was offered, in
	// one message of its stream, or whole when asked to.
	script := `#!/bin/sh
for a in "$@"; do
  case "$a" in *mcpServers*) printf '%s' "$a" > "` + offered + `.config"; tp=$(printf '%s' "$a" | sed 's/.*"\([^"]*tools\.json\)".*/\1/');; esac
done
while read -r line; do
  grep -o '"name":"[^"]*"' "$tp" | sed 's/"name":"//; s/"$//' > ` + offered + `
  names=$(tr -c 'A-Za-z0-9_\n-' '_' < ` + offered + `)
  case "$line" in
  *wholeplease*)
    content="" i=0
    for n in $names; do
      i=$((i+1))
      [ -n "$content" ] && content="$content,"
      content="$content"'{"type":"tool_use","id":"toolu_'$i'","name":"mcp__my__'$n'","input":{"n":'$i'}}'
    done
    echo '{"type":"assistant","message":{"id":"m","model":"claude-sonnet-5","content":['"$content"'],"stop_reason":"tool_use","usage":{"output_tokens":3}}}' ;;
  *)
    echo '{"type":"stream_event","event":{"type":"message_start","message":{"id":"m","model":"claude-sonnet-5","usage":{"input_tokens":1}}}}'
    i=0
    for n in $names; do
      echo '{"type":"stream_event","event":{"type":"content_block_start","index":'$i',"content_block":{"type":"tool_use","id":"toolu_'$i'","name":"mcp__my__'$n'"}}}'
      echo '{"type":"stream_event","event":{"type":"content_block_delta","index":'$i',"delta":{"type":"input_json_delta","partial_json":"{\"n\":'$i'}"}}}'
      echo '{"type":"stream_event","event":{"type":"content_block_stop","index":'$i'}}'
      i=$((i+1))
    done
    echo '{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}}'
    echo '{"type":"stream_event","event":{"type":"message_stop"}}' ;;
  esac
done
`
	testenv.Program(t, filepath.Join(dir, "claude"), script)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	runsEndWithTest(t, dir)

	tools := func(f func(string) string) string {
		var out []string
		for _, n := range declared {
			q, _ := json.Marshal(n)
			out = append(out, f(string(q)))
		}
		return strings.Join(out, ",")
	}
	bodies := map[provider.Protocol]func(say string, stream bool) string{
		provider.Anthropic: func(say string, stream bool) string {
			return fmt.Sprintf(`{"model":"claude-sonnet-5","max_tokens":100,"stream":%t,"messages":[{"role":"user","content":%q}],"tools":[%s]}`, stream, say,
				tools(func(q string) string { return `{"name":` + q + `,"input_schema":{"type":"object"}}` }))
		},
		provider.Chat: func(say string, stream bool) string {
			return fmt.Sprintf(`{"model":"claude-sonnet-5","stream":%t,"messages":[{"role":"user","content":%q}],"tools":[%s]}`, stream, say,
				tools(func(q string) string {
					return `{"type":"function","function":{"name":` + q + `,"parameters":{"type":"object"}}}`
				}))
		},
		provider.Responses: func(say string, stream bool) string {
			return fmt.Sprintf(`{"model":"claude-sonnet-5","stream":%t,"input":%q,"tools":[%s]}`, stream, say,
				tools(func(q string) string { return `{"type":"function","name":` + q + `,"parameters":{"type":"object"}}` }))
		},
	}
	paths := map[provider.Protocol]string{provider.Anthropic: "/v1/messages", provider.Chat: "/v1/chat/completions", provider.Responses: "/v1/responses"}
	nameRe := regexp.MustCompile(`"name":"((?:[^"\\]|\\.)*)"`)
	validRe := regexp.MustCompile(`^[A-Za-z0-9_-]{1,51}$`)
	p := provider.Provider{ID: "claude", Account: &provider.Account{Agent: "claude", User: "u"}}
	for _, from := range []provider.Protocol{provider.Anthropic, provider.Chat, provider.Responses} {
		for _, stream := range []bool{false, true} {
			for _, say := range []string{"call them", "call them wholeplease"} {
				what := fmt.Sprintf("%s stream=%t %q", from, stream, say)
				s := New()
				body := bodies[from](say, stream)
				rec := httptest.NewRecorder()
				var u Usage
				if code, msg := s.serveClaudeSubscription(rec, httptest.NewRequest("POST", paths[from], strings.NewReader(body)), from, p, "claude-sonnet-5", []byte(body), &u); code != 200 {
					s.subscription.abortAll()
					t.Fatalf("%s: %d %s", what, code, msg)
				}
				s.subscription.abortAll()
				var got []string
				for _, m := range nameRe.FindAllStringSubmatch(rec.Body.String(), -1) {
					var n string
					_ = json.Unmarshal([]byte(`"`+m[1]+`"`), &n)
					if !slices.Contains(got, n) {
						got = append(got, n)
					}
				}
				slices.Sort(got)
				want := slices.Sorted(slices.Values(declared))
				if !slices.Equal(got, want) {
					t.Errorf("%s: the calls name %q, want the declared %q: %s", what, got, want, rec.Body)
				}
				config, _ := os.ReadFile(offered + ".config")
				var mcp struct {
					Servers map[string]any `json:"mcpServers"`
				}
				if err := json.Unmarshal(config, &mcp); err != nil || len(mcp.Servers) != 1 || mcp.Servers["my"] == nil {
					t.Fatalf("bridge MCP config = %s, want only my: %v", config, err)
				}
				b, _ := os.ReadFile(offered)
				names := strings.Fields(strings.ReplaceAll(string(b), " ", "\x00"))
				seen := map[string]bool{}
				for _, n := range names {
					if !validRe.MatchString(n) || seen[n] {
						t.Errorf("%s: Claude Code was offered %q, which isn't a valid, unique MCP tool name of at most 51: %q", what, n, names)
					}
					seen[n] = true
				}
				if len(names) != len(declared) {
					t.Errorf("%s: offered %d tools, want %d: %q", what, len(names), len(declared), names)
				}
			}
		}
	}

	// the run is told the client's earlier calls, and its tool choice,
	// under the names it was offered them by
	req := &Request{Tools: []Tool{{Name: "a.b"}, {Name: "a_b"}, {Name: long}}, ToolChoice: "name:a.b"}
	offer := bridgeTools(req)
	if len(offer) != 1 || !validRe.MatchString(offer[0].Name) || offer[0].Name == "a_b" {
		t.Fatalf("tool_choice a.b offers %+v", offer)
	}
	if got, want := toolChoiceAsk(req), "You must call the mcp__my__"+offer[0].Name+" tool."; !strings.Contains(got, want) {
		t.Errorf("tool choice %q, want %q", got, want)
	}
	var text strings.Builder
	renderParts(nil, &text, []Part{{Kind: ToolCall, ID: "c1", Name: "a.b", Args: json.RawMessage(`{}`)}, {Kind: ToolCall, ID: "c2", Name: long, Args: json.RawMessage(`{}`)}}, offeredTools(req.Tools))
	if !strings.Contains(text.String(), "[tool call mcp__my__"+offer[0].Name+" id=c1 ") {
		t.Errorf("history tells a.b otherwise than it is offered (%s): %q", offer[0].Name, text.String())
	}
	if !strings.Contains(text.String(), "[tool call mcp__my__"+bridgeToolName(long)+" id=c2 ") || len("mcp__my__"+bridgeToolName(long)) > 64 {
		t.Errorf("history tells the long name as %q", text.String())
	}
}

// packinggoods (Discord, 11-01): Claude Code with magpie's Library MCP
// names its tools mcp__magpie__<server>__<tool>, and through the Claude
// bridge the run's model was shown
// mcp__magpie__mcp__magpie__magpie-browser__browser_click for each tool
// sent up front, while the deferred ones its text named kept one prefix.
// The run's Claude Code is offered each such tool under the client's own
// name, in the tool list, a tool choice and the history alike, and a call
// of it comes back under the declared name.
func TestClaudeBridgeKeepsMagpieMCPNames(t *testing.T) {
	// Caller Library names retain mcp__magpie__; the bridge adds mcp__my__.
	declared := []string{
		"mcp__magpie__magpie-browser__browser_click",
		"mcp__magpie__magpie-vision__analyze_image",
		"mcp__magpie__magpie-web-search__web_search",
		"mcp__linear__get_issue",
		"Read",
	}
	var tools []Tool
	for _, n := range declared {
		tools = append(tools, Tool{Name: n})
	}
	req := &Request{Tools: tools}
	names := bridgeNames(tools)
	for i, offer := range bridgeTools(req) {
		n := declared[i]
		seen := "mcp__my__" + offer.Name
		if strings.HasPrefix(n, "mcp__magpie__") && seen != "mcp__my__"+strings.TrimPrefix(n, "mcp__magpie__") {
			t.Errorf("%s is shown to the run's model as %s", n, seen)
		}
		if strings.Contains(seen, "mcp__my__mcp__magpie__") {
			t.Errorf("%s is offered with a double MCP prefix: %s", n, seen)
		}
		if got := declaredName(names, offer.Name); got != n {
			t.Errorf("a call of %s (offered %s) comes back as %s", n, offer.Name, got)
		}
		if bridgeName(n) != seen {
			t.Errorf("history and tool choice name %s as %s, the tool list as %s", n, bridgeName(n), seen)
		}
	}
	var text strings.Builder
	renderParts(nil, &text, []Part{{Kind: ToolCall, ID: "c1", Name: declared[0], Args: json.RawMessage(`{}`)}}, offeredTools(tools))
	if !strings.Contains(text.String(), "[tool call "+bridgeName(declared[0])+" id=c1 ") {
		t.Errorf("history tells %s as %q", declared[0], text.String())
	}
	req.ToolChoice = "name:" + declared[0]
	if got := toolChoiceAsk(req); !strings.Contains(got, "You must call the "+bridgeName(declared[0])+" tool.") {
		t.Errorf("tool choice %q", got)
	}
}
