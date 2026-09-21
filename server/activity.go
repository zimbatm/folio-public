package main

// Activity: what the agents are doing, for Folio's Activity view. A build
// takes 10-15 minutes and the tablet otherwise sees only "building". Each job
// keeps a short log: the agent's tool calls from claude's stream-json output,
// one line each, and the service's own steps (tests, rebase, tag, push).

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	maxLog  = 300
	maxJobs = 50
)

type logLine struct {
	N    int       `json:"n"`
	T    time.Time `json:"t"`
	Text string    `json:"text"`
}

func (j *job) logf(format string, a ...any) {
	text := fmt.Sprintf(format, a...)
	if len(text) > 200 {
		text = text[:200] + "…"
	}
	mu.Lock()
	defer mu.Unlock()
	j.logN++
	j.log = append(j.log, logLine{N: j.logN, T: time.Now(), Text: text})
	if len(j.log) > maxLog {
		j.log = j.log[len(j.log)-maxLog:]
	}
}

// newJob registers a job and drops the oldest finished ones past maxJobs
func newJob(kind, request string) *job {
	j := &job{ID: strconv.FormatInt(time.Now().UnixNano(), 36), Kind: kind, Request: request, State: "running", Started: time.Now()}
	mu.Lock()
	defer mu.Unlock()
	jobs[j.ID] = j
	if len(jobs) > maxJobs {
		var done []*job
		for _, o := range jobs {
			if o.State != "running" {
				done = append(done, o)
			}
		}
		sort.Slice(done, func(a, b int) bool { return done[a].Started.Before(done[b].Started) })
		for i := 0; i < len(done) && len(jobs) > maxJobs; i++ {
			delete(jobs, done[i].ID)
		}
	}
	return j
}

// runAgent runs claude -p with stream-json output, logging each tool call
// through say, and returns the final result text
func runAgent(ctx context.Context, dir string, args []string, say func(string)) (string, error) {
	args = append(args, "--output-format", "stream-json", "--verbose")
	cmd := exec.CommandContext(ctx, *claude, args...)
	cmd.Dir = dir
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	var errb strings.Builder
	cmd.Stderr = &errb
	if err := cmd.Start(); err != nil {
		return "", err
	}
	var result string
	isError, gotResult := false, false
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		var ev struct {
			Type    string `json:"type"`
			IsError bool   `json:"is_error"`
			Result  string `json:"result"`
			Message struct {
				Content []struct {
					Type  string          `json:"type"`
					Name  string          `json:"name"`
					Text  string          `json:"text"`
					Input json.RawMessage `json:"input"`
				} `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(sc.Bytes(), &ev) != nil {
			continue
		}
		switch ev.Type {
		case "assistant":
			for _, c := range ev.Message.Content {
				switch c.Type {
				case "tool_use":
					say(describe(dir, c.Name, c.Input))
				case "text":
					if line := firstLine(strings.TrimSpace(c.Text)); line != "" {
						say("“" + line + "”")
					}
				}
			}
		case "result":
			result, isError, gotResult = ev.Result, ev.IsError, true
		}
	}
	if err := cmd.Wait(); err != nil {
		return "", fmt.Errorf("%v: %s", err, tail(errb.String(), 20))
	}
	if !gotResult || isError {
		return "", fmt.Errorf("%s", tail(result+errb.String(), 20))
	}
	return result, nil
}

func describe(dir, name string, raw json.RawMessage) string {
	var in map[string]any
	json.Unmarshal(raw, &in)
	str := func(k string) string { s, _ := in[k].(string); return s }
	rel := func(p string) string {
		if r, err := filepath.Rel(dir, p); err == nil && !strings.HasPrefix(r, "..") {
			return r
		}
		return p
	}
	switch name {
	case "Read":
		return "Read " + rel(str("file_path"))
	case "Edit", "MultiEdit":
		return "Edit " + rel(str("file_path"))
	case "Write":
		return "Write " + rel(str("file_path"))
	case "Bash":
		return "Run: " + firstLine(str("command"))
	case "Grep":
		return "Search: " + str("pattern")
	case "Glob":
		return "Find: " + str("pattern")
	case "TodoWrite":
		return "Update the plan"
	}
	return name
}

func listJobs(w http.ResponseWriter, r *http.Request) {
	type entry struct {
		ID       string    `json:"id"`
		Kind     string    `json:"kind"`
		Request  string    `json:"request"`
		State    string    `json:"state"`
		Version  string    `json:"version,omitempty"`
		Started  time.Time `json:"started"`
		Finished time.Time `json:"finished,omitzero"`
		Lines    int       `json:"lines"`
	}
	mu.Lock()
	list := []entry{}
	for _, j := range jobs {
		req := j.Request
		if len(req) > 200 {
			req = req[:200] + "…"
		}
		list = append(list, entry{j.ID, j.Kind, req, j.State, j.Version, j.Started, j.Finished, j.logN})
	}
	mu.Unlock()
	sort.Slice(list, func(a, b int) bool { return list[a].Started.After(list[b].Started) })
	reply(w, http.StatusOK, list)
}

func jobLog(w http.ResponseWriter, r *http.Request) {
	after, _ := strconv.Atoi(r.URL.Query().Get("after"))
	mu.Lock()
	defer mu.Unlock()
	j, ok := jobs[r.PathValue("id")]
	if !ok {
		fail(w, http.StatusNotFound, "no such job")
		return
	}
	lines := []logLine{}
	for _, l := range j.log {
		if l.N > after {
			lines = append(lines, l)
		}
	}
	reply(w, http.StatusOK, map[string]any{"state": j.State, "lines": lines})
}
