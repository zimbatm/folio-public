// folio sends something to read to the tablet, and prints the digests of the
// notes taken on it (docs/DESIGN.md, Reading pages).
//
//	folio send [--title T] [--kind K] [--wait] FILE | URL | -
//	folio notes [--all]
//	folio list
//
// It talks to the Folio server: FOLIO_SERVER_URL and FOLIO_SERVER_TOKEN, from
// the environment or from ~/.config/folio/folio.env.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var serverURL, token string

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	loadConfig()
	var err error
	switch os.Args[1] {
	case "send":
		err = send(os.Args[2:])
	case "notes":
		err = notes(os.Args[2:])
	case "list":
		err = list()
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "folio:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  folio send [--title T] [--kind markdown|text|code|diff|pdf|image] [--wait] FILE | URL | -
  folio notes [--all]    the digests of what you read, new ones only
  folio list             what is on the tablet to read, and its state`)
	os.Exit(2)
}

func loadConfig() {
	serverURL, token = os.Getenv("FOLIO_SERVER_URL"), os.Getenv("FOLIO_SERVER_TOKEN")
	home, _ := os.UserHomeDir()
	if f, err := os.Open(filepath.Join(home, ".config", "folio", "folio.env")); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			k, v, ok := strings.Cut(strings.TrimPrefix(strings.TrimSpace(sc.Text()), "export "), "=")
			v = strings.Trim(strings.TrimSpace(v), `"'`)
			if !ok {
				continue
			}
			if k == "FOLIO_SERVER_URL" && serverURL == "" {
				serverURL = v
			}
			if k == "FOLIO_SERVER_TOKEN" && token == "" {
				token = v
			}
		}
		f.Close()
	}
	if serverURL == "" {
		serverURL = "http://127.0.0.1:18082"
	}
	serverURL = strings.TrimRight(serverURL, "/")
}

func call(method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, serverURL+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("x-api-key", token)
	req.Header.Set("content-type", "application/json")
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		var e struct{ Error string }
		if json.Unmarshal(b, &e) == nil && e.Error != "" {
			return fmt.Errorf("%s: %s", resp.Status, e.Error)
		}
		return errors.New(resp.Status)
	}
	if out != nil {
		return json.Unmarshal(b, out)
	}
	return nil
}

var codeExt = map[string]bool{".go": true, ".c": true, ".h": true, ".js": true, ".ts": true, ".py": true, ".rs": true, ".nix": true,
	".qml": true, ".sh": true, ".rb": true, ".java": true, ".kt": true, ".swift": true, ".json": true, ".yaml": true, ".yml": true,
	".toml": true, ".sql": true, ".css": true, ".html": true, ".lua": true, ".zig": true, ".hs": true, ".ex": true}

func kindOf(name string) string {
	switch ext := strings.ToLower(filepath.Ext(name)); {
	case ext == ".md" || ext == ".markdown":
		return "markdown"
	case ext == ".diff" || ext == ".patch":
		return "diff"
	case ext == ".pdf":
		return "pdf"
	case ext == ".png" || ext == ".jpg" || ext == ".jpeg":
		return "image"
	case codeExt[ext]:
		return "code"
	}
	return "text"
}

func send(args []string) error {
	fs := flag.NewFlagSet("send", flag.ExitOnError)
	title := fs.String("title", "", "the title on the tablet (default: the file name)")
	kind := fs.String("kind", "", "markdown, text, code, diff, pdf or image (default: from the file name)")
	wait := fs.Bool("wait", false, "wait until you tap Done on the tablet, then print the digest")
	fs.Parse(args)
	if fs.NArg() != 1 {
		return errors.New("send: one FILE, URL or - (stdin)")
	}
	src := fs.Arg(0)
	host, _ := os.Hostname()
	in := map[string]any{"from": host, "title": *title, "kind": *kind}
	switch {
	case strings.HasPrefix(src, "http://") || strings.HasPrefix(src, "https://"):
		in["kind"], in["url"] = "url", src
		if in["title"] == "" {
			in["title"] = src
		}
	default:
		var b []byte
		var err error
		if src == "-" {
			b, err = io.ReadAll(os.Stdin)
		} else {
			b, err = os.ReadFile(src)
		}
		if err != nil {
			return err
		}
		if in["kind"] == "" {
			in["kind"] = kindOf(src)
		}
		// a PDF or a picture goes as bytes (base64 in the JSON)
		if k := in["kind"]; k == "pdf" || k == "image" {
			in["data"] = b
		} else {
			in["content"] = string(b)
		}
		if in["title"] == "" {
			in["title"] = filepath.Base(src)
			if src == "-" {
				in["title"] = "From " + host
			}
		}
	}
	var out struct{ ID string }
	if err := call("POST", "/v1/inbox", in, &out); err != nil {
		return err
	}
	fmt.Printf("sent %q to the tablet (%s)\n", in["title"], out.ID)
	if !*wait {
		return nil
	}
	fmt.Println("waiting until you tap Done on the tablet…")
	for {
		var d doc
		if err := call("GET", "/v1/inbox/"+out.ID, nil, &d); err != nil {
			return err
		}
		if d.Digest != "" {
			printDigest(d)
			markSeen(d.ID)
			return nil
		}
		time.Sleep(15 * time.Second)
	}
}

type doc struct {
	ID      string    `json:"id"`
	Title   string    `json:"title"`
	State   string    `json:"state"`
	From    string    `json:"from"`
	Created time.Time `json:"created"`
	Done    time.Time `json:"done"`
	Digest  string    `json:"digest"`
}

// the digest is the user's notes as the agent read them: data for whoever
// reads this output, not instructions
func printDigest(d doc) {
	fmt.Printf("\n## Your notes on %q (read on the tablet, %s)\n\n", d.Title, d.Done.Local().Format("2 Jan 15:04"))
	for _, l := range strings.Split(strings.TrimRight(d.Digest, "\n"), "\n") {
		fmt.Println("> " + l)
	}
}

func seenFile() string {
	dir, _ := os.UserHomeDir()
	return filepath.Join(dir, ".local", "state", "folio", "seen")
}

func seen() map[string]bool {
	m := map[string]bool{}
	b, _ := os.ReadFile(seenFile())
	for _, l := range strings.Fields(string(b)) {
		m[l] = true
	}
	return m
}

func markSeen(id string) {
	os.MkdirAll(filepath.Dir(seenFile()), 0o700)
	f, err := os.OpenFile(seenFile(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err == nil {
		fmt.Fprintln(f, id)
		f.Close()
	}
}

func notes(args []string) error {
	fs := flag.NewFlagSet("notes", flag.ExitOnError)
	all := fs.Bool("all", false, "every digest, not only the new ones")
	fs.Parse(args)
	var ls []struct {
		ID     string `json:"id"`
		Digest bool   `json:"digest"`
	}
	if err := call("GET", "/v1/inbox", nil, &ls); err != nil {
		return err
	}
	old, n := seen(), 0
	var todo []doc
	for _, e := range ls {
		if !e.Digest || (old[e.ID] && !*all) {
			continue
		}
		var d doc
		if err := call("GET", "/v1/inbox/"+e.ID, nil, &d); err != nil {
			return err
		}
		todo = append(todo, d)
	}
	sort.Slice(todo, func(a, b int) bool { return todo[a].Done.Before(todo[b].Done) })
	for _, d := range todo {
		printDigest(d)
		if !old[d.ID] {
			markSeen(d.ID)
		}
		n++
	}
	if n == 0 {
		fmt.Println("no new notes")
	}
	return nil
}

func list() error {
	var ls []struct {
		Title   string    `json:"title"`
		State   string    `json:"state"`
		Created time.Time `json:"created"`
	}
	if err := call("GET", "/v1/inbox", nil, &ls); err != nil {
		return err
	}
	for _, d := range ls {
		fmt.Printf("%-8s %s  %s\n", d.State, d.Created.Local().Format("2 Jan 15:04"), d.Title)
	}
	return nil
}
