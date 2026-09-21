package main

// The reading inbox: documents sent from the computer to read on the tablet,
// and the digest of the notes the user took on each (docs/DESIGN.md). One
// JSON file per document in --inbox.

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

var inboxDir = flag.String("inbox", "inbox", "documents to read on the tablet, and their digests")

// a PDF or a picture comes as base64 in the JSON
const maxDoc = 48 << 20

type reading struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	// markdown, text, code or diff: the tablet shows it as markdown; url: the
	// tablet opens the page itself
	Kind    string    `json:"kind"`
	Content string    `json:"content,omitempty"`
	URL     string    `json:"url,omitempty"`
	From    string    `json:"from,omitempty"`
	State   string    `json:"state"` // new, reading or done
	Created time.Time `json:"created"`
	Digest  string    `json:"digest,omitempty"`
	Done    time.Time `json:"done,omitzero"`
	// pdf and image: each page, a PNG at /v1/inbox/{id}/page/{n}
	Pages []docPage `json:"pages,omitempty"`
}

var (
	inboxMu sync.Mutex
	docID   = regexp.MustCompile(`^[0-9a-z]{8,40}$`)
	kinds   = map[string]bool{"markdown": true, "text": true, "code": true, "diff": true, "url": true, "pdf": true, "image": true}
)

func docPath(id string) string { return filepath.Join(*inboxDir, id+".json") }

func loadDoc(id string) (*reading, error) {
	if !docID.MatchString(id) {
		return nil, os.ErrNotExist
	}
	b, err := os.ReadFile(docPath(id))
	if err != nil {
		return nil, err
	}
	var d reading
	return &d, json.Unmarshal(b, &d)
}

func saveDoc(d *reading) error {
	b, err := json.Marshal(d)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(*inboxDir, 0o750); err != nil {
		return err
	}
	tmp := docPath(d.ID) + ".tmp"
	if err := os.WriteFile(tmp, b, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, docPath(d.ID))
}

func allDocs() []*reading {
	files, _ := filepath.Glob(filepath.Join(*inboxDir, "*.json"))
	var out []*reading
	for _, f := range files {
		if d, err := loadDoc(strings.TrimSuffix(filepath.Base(f), ".json")); err == nil {
			out = append(out, d)
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Created.After(out[b].Created) })
	return out
}

// markdown for the tablet: code, diffs and plain text in a fence
func asMarkdown(kind, content string) string {
	if kind == "markdown" || kind == "url" {
		return content
	}
	lang := map[string]string{"diff": "diff", "code": "", "text": ""}[kind]
	fence := "```"
	for strings.Contains(content, fence) {
		fence += "`"
	}
	return fence + lang + "\n" + strings.TrimRight(content, "\n") + "\n" + fence
}

func inboxAdd(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Title   string `json:"title"`
		Kind    string `json:"kind"`
		Content string `json:"content"`
		URL     string `json:"url"`
		From    string `json:"from"`
		Data    []byte `json:"data"` // pdf and image, base64
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxDoc)).Decode(&in); err != nil {
		fail(w, http.StatusBadRequest, err.Error())
		return
	}
	if in.Kind == "" {
		in.Kind = "markdown"
	}
	if !kinds[in.Kind] {
		fail(w, http.StatusBadRequest, "kind: want markdown, text, code, diff, url, pdf or image")
		return
	}
	if in.Kind == "url" && !strings.HasPrefix(in.URL, "http://") && !strings.HasPrefix(in.URL, "https://") {
		fail(w, http.StatusBadRequest, "url: want an http or https address")
		return
	}
	binary := in.Kind == "pdf" || in.Kind == "image"
	if binary && len(in.Data) == 0 {
		fail(w, http.StatusBadRequest, "empty data")
		return
	}
	if !binary && in.Kind != "url" && strings.TrimSpace(in.Content) == "" {
		fail(w, http.StatusBadRequest, "empty content")
		return
	}
	b := make([]byte, 6)
	rand.Read(b)
	d := &reading{ID: fmt.Sprintf("%x%s", time.Now().Unix(), hex.EncodeToString(b)), Title: strings.TrimSpace(in.Title), Kind: in.Kind,
		Content: asMarkdown(in.Kind, in.Content), URL: in.URL, From: strings.TrimSpace(in.From), State: "new", Created: time.Now()}
	if d.Title == "" {
		d.Title = "Untitled"
	}
	if binary {
		var err error
		if in.Kind == "pdf" {
			d.Pages, err = renderPDF(d.ID, in.Data)
		} else {
			d.Pages, err = storePicture(d.ID, in.Data)
		}
		if err != nil {
			os.RemoveAll(pagesDirOf(d.ID))
			fail(w, http.StatusBadRequest, err.Error())
			return
		}
		// the tablet shows the page pictures; folio:page/N is page N here
		var md strings.Builder
		for n := range d.Pages {
			fmt.Fprintf(&md, "![page %d](folio:page/%d)\n\n", n+1, n+1)
		}
		d.Content = md.String()
	}
	inboxMu.Lock()
	defer inboxMu.Unlock()
	if err := saveDoc(d); err != nil {
		fail(w, http.StatusInternalServerError, err.Error())
		return
	}
	reply(w, http.StatusCreated, map[string]string{"id": d.ID, "state": d.State})
}

// the list, without the documents' text
func inboxList(w http.ResponseWriter, r *http.Request) {
	inboxMu.Lock()
	docs := allDocs()
	inboxMu.Unlock()
	out := []map[string]any{}
	for _, d := range docs {
		e := map[string]any{"id": d.ID, "title": d.Title, "kind": d.Kind, "from": d.From, "state": d.State,
			"created": d.Created, "digest": d.Digest != ""}
		if !d.Done.IsZero() {
			e["done"] = d.Done
		}
		out = append(out, e)
	}
	reply(w, http.StatusOK, out)
}

func inboxGet(w http.ResponseWriter, r *http.Request) {
	inboxMu.Lock()
	d, err := loadDoc(r.PathValue("id"))
	inboxMu.Unlock()
	if err != nil {
		fail(w, http.StatusNotFound, "no such document")
		return
	}
	reply(w, http.StatusOK, d)
}

// the tablet reports that it opened the document, or sends the digest
func inboxUpdate(w http.ResponseWriter, r *http.Request) {
	var in struct {
		State  string `json:"state"`
		Digest string `json:"digest"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxDoc)).Decode(&in); err != nil {
		fail(w, http.StatusBadRequest, err.Error())
		return
	}
	inboxMu.Lock()
	defer inboxMu.Unlock()
	d, err := loadDoc(r.PathValue("id"))
	if err != nil {
		fail(w, http.StatusNotFound, "no such document")
		return
	}
	switch {
	case strings.TrimSpace(in.Digest) != "":
		d.Digest, d.State, d.Done = in.Digest, "done", time.Now()
	case in.State == "reading" && d.State == "new":
		d.State = "reading"
	case in.State == "reading" || in.State == "":
	default:
		fail(w, http.StatusBadRequest, "state: want reading, or a digest")
		return
	}
	if err := saveDoc(d); err != nil {
		fail(w, http.StatusInternalServerError, err.Error())
		return
	}
	reply(w, http.StatusOK, map[string]string{"id": d.ID, "state": d.State})
}
