// folio-bridge serves the Anthropic Messages API on top of `claude -p`, so
// clients that only speak the API run on a Claude subscription. Built for
// Folio on the reMarkable: one user turn (handwriting + prompt) in, one tool
// call out.
//
// Every request is untrusted input (handwriting) to a model on this
// host, so claude runs with no tools, no MCP servers, no skills and no
// settings (hence no hooks): the only thing it can do is answer. The tools a
// client sends are not run here; they become a JSON schema the answer must
// match, and the client runs the chosen one.
package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

type tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"input_schema"`
}

type message struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
}

type request struct {
	Model        string          `json:"model"`
	System       json.RawMessage `json:"system"`
	Messages     []message       `json:"messages"`
	Tools        []tool          `json:"tools"`
	OutputConfig struct {
		Effort string `json:"effort"`
	} `json:"output_config"`
}

// what a client may pick per request; these reach claude's argv, so no free text
var (
	models  = map[string]bool{"haiku": true, "sonnet": true, "opus": true, "fable": true}
	efforts = map[string]bool{"low": true, "medium": true, "high": true, "xhigh": true, "max": true}
)

var (
	listen    = flag.String("listen", "tcp:127.0.0.1:18081", "tcp:host:port or unix:/path")
	tokenFile = flag.String("token-file", "", "file holding the x-api-key clients must send")
	claudeBin = flag.String("claude", "claude", "claude executable")
	model     = flag.String("model", "sonnet", "model passed to claude -p when the request names none")
	workdir   = flag.String("workdir", os.TempDir(), "working directory for claude -p")
	timeout   = flag.Duration("timeout", 3*time.Minute, "per-request timeout")
	effort    = flag.String("effort", "", "effort level passed to claude -p when the request names none; empty keeps its default")
	token     string
)

func main() {
	flag.Parse()
	b, err := os.ReadFile(*tokenFile)
	if err != nil {
		log.Fatalf("folio-bridge: --token-file: %v", err)
	}
	if token = strings.TrimSpace(string(b)); token == "" {
		log.Fatal("folio-bridge: --token-file is empty")
	}

	netw, addr, ok := strings.Cut(*listen, ":")
	if !ok || (netw != "tcp" && netw != "unix") {
		log.Fatalf("folio-bridge: bad --listen %q (want tcp:host:port or unix:/path)", *listen)
	}
	if netw == "unix" {
		os.Remove(addr)
	}
	ln, err := net.Listen(netw, addr)
	if err != nil {
		log.Fatalf("folio-bridge: listen: %v", err)
	}
	loadJobs()
	http.HandleFunc("POST /v1/messages", handle)
	http.HandleFunc("POST /v1/jobs", startJob)
	http.HandleFunc("GET /v1/jobs/{id}", getJob)
	log.Printf("listening on %s", *listen)
	log.Fatal(http.Serve(ln, nil))
}

func authorized(r *http.Request) bool {
	return subtle.ConstantTimeCompare([]byte(r.Header.Get("x-api-key")), []byte(token)) == 1
}

// decode checks the token and the request; false means it answered already
func decode(w http.ResponseWriter, r *http.Request) (request, bool) {
	var req request
	if !authorized(r) {
		apiError(w, http.StatusUnauthorized, "authentication_error", "invalid x-api-key")
		return req, false
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apiError(w, http.StatusBadRequest, "invalid_request_error", err.Error())
		return req, false
	}
	if req.Model == "" {
		req.Model = *model
	}
	if req.OutputConfig.Effort == "" {
		req.OutputConfig.Effort = *effort
	}
	if !models[req.Model] {
		apiError(w, http.StatusBadRequest, "invalid_request_error", fmt.Sprintf("model %q: want one of haiku, sonnet, opus, fable", req.Model))
		return req, false
	}
	if req.OutputConfig.Effort != "" && !efforts[req.OutputConfig.Effort] {
		apiError(w, http.StatusBadRequest, "invalid_request_error", fmt.Sprintf("effort %q: want one of low, medium, high, xhigh, max", req.OutputConfig.Effort))
		return req, false
	}
	return req, true
}

// answer runs claude and shapes its answer as a Messages API message
func answer(ctx context.Context, req request) (map[string]any, error) {
	start := time.Now()
	content, err := run(ctx, req)
	if err != nil {
		log.Printf("claude failed after %s: %v", time.Since(start), err)
		return nil, err
	}
	picked := ""
	if len(content) == 1 && content[0]["type"] == "tool_use" {
		picked = fmt.Sprintf(", tool %v of %d", content[0]["name"], len(req.Tools))
	}
	log.Printf("answered in %s (%s, effort %s%s)", time.Since(start).Round(time.Millisecond), req.Model, req.OutputConfig.Effort, picked)
	stop := "end_turn"
	if len(req.Tools) > 0 {
		stop = "tool_use"
	}
	return map[string]any{
		"id":          fmt.Sprintf("msg_bridge_%d", start.UnixNano()),
		"type":        "message",
		"role":        "assistant",
		"model":       req.Model,
		"stop_reason": stop,
		"content":     content,
		"usage":       map[string]int{"input_tokens": 0, "output_tokens": 0},
	}, nil
}

func handle(w http.ResponseWriter, r *http.Request) {
	req, ok := decode(w, r)
	if !ok {
		return
	}
	msg, err := answer(r.Context(), req)
	if err != nil {
		apiError(w, http.StatusInternalServerError, "api_error", err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(msg)
}

func run(ctx context.Context, req request) ([]map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()

	args := []string{"-p",
		"--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
		// a leading "/" in the page text would otherwise run a skill, and
		// skills may shell out
		"--tools", "", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
		"--no-session-persistence", "--model", req.Model,
		"--system-prompt", systemPrompt(req),
	}
	if len(req.Tools) > 0 {
		args = append(args, "--json-schema", toolSchema(req.Tools))
	}
	if req.OutputConfig.Effort != "" {
		args = append(args, "--effort", req.OutputConfig.Effort)
	}

	var stdin bytes.Buffer
	enc := json.NewEncoder(&stdin)
	for _, m := range req.Messages {
		if m.Role != "user" {
			return nil, fmt.Errorf("only user messages are supported, got %q", m.Role)
		}
		enc.Encode(map[string]any{"type": "user", "message": m})
	}

	cmd := exec.CommandContext(ctx, *claudeBin, args...)
	cmd.Dir = *workdir
	cmd.Stdin = &stdin
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}

	offered := map[string]bool{}
	for _, t := range req.Tools {
		offered[t.Name] = true
	}
	for _, line := range bytes.Split(out, []byte("\n")) {
		var ev struct {
			Type    string `json:"type"`
			IsError bool   `json:"is_error"`
			Result  string `json:"result"`
			Message struct {
				Content []struct {
					Type  string          `json:"type"`
					Name  string          `json:"name"`
					Input json.RawMessage `json:"input"`
				} `json:"content"`
			} `json:"message"`
			StructuredOutput *struct {
				Call struct {
					Tool  string          `json:"tool"`
					Input json.RawMessage `json:"input"`
				} `json:"call"`
			} `json:"structured_output"`
		}
		if json.Unmarshal(line, &ev) != nil {
			continue
		}
		// the model sometimes calls an offered tool directly instead of
		// through StructuredOutput; claude answers "No such tool available"
		// and the model then gives up on it, so the direct call wins
		if ev.Type == "assistant" {
			for _, c := range ev.Message.Content {
				if c.Type == "tool_use" && offered[c.Name] {
					return []map[string]any{{"type": "tool_use", "id": "toolu_bridge", "name": c.Name, "input": c.Input}}, nil
				}
			}
		}
		if ev.Type != "result" {
			continue
		}
		if ev.IsError {
			return nil, fmt.Errorf("claude: %s", ev.Result)
		}
		if ev.StructuredOutput == nil {
			return []map[string]any{{"type": "text", "text": ev.Result}}, nil
		}
		c := ev.StructuredOutput.Call
		return []map[string]any{{"type": "tool_use", "id": "toolu_bridge", "name": c.Tool, "input": c.Input}}, nil
	}
	return nil, fmt.Errorf("no result event from claude")
}

func systemPrompt(req request) string {
	var b strings.Builder
	var s string
	if json.Unmarshal(req.System, &s) == nil && s != "" {
		b.WriteString(s + "\n\n")
	}
	if len(req.Tools) > 0 {
		// without this the model calls web_search etc. directly, gets "No such
		// tool available" and replies that live access failed
		b.WriteString("The tools below are not callable directly. To use one, call StructuredOutput once, " +
			"with the tool's name in `call.tool` and its arguments in `call.input`. That ends your turn: " +
			"the app runs the tool and asks you again with its result. The tools:\n")
		for _, t := range req.Tools {
			fmt.Fprintf(&b, "- %s: %s\n", t.Name, t.Description)
		}
	}
	return b.String()
}

// toolSchema lets structured output pick one tool and validates its input.
func toolSchema(tools []tool) string {
	var branches []any
	for _, t := range tools {
		branches = append(branches, map[string]any{
			"type": "object", "additionalProperties": false, "required": []string{"tool", "input"},
			"properties": map[string]any{"tool": map[string]any{"const": t.Name}, "input": t.InputSchema},
		})
	}
	s, _ := json.Marshal(map[string]any{
		"type": "object", "additionalProperties": false, "required": []string{"call"},
		"properties": map[string]any{"call": map[string]any{"anyOf": branches}},
	})
	return string(s)
}

func apiError(w http.ResponseWriter, code int, typ, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"type": "error", "error": map[string]string{"type": typ, "message": msg}})
}
