package main

// PDFs and pictures to read: the server renders each page to a greyscale PNG
// for the tablet, and keeps the box of each word, so a mark on a page image
// can be read as the words under it.

import (
	"bytes"
	"context"
	"encoding/xml"
	"flag"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"
)

var (
	pdftoppm  = flag.String("pdftoppm", "pdftoppm", "pdftoppm executable (PDF pages to PNG)")
	pdftotext = flag.String("pdftotext", "pdftotext", "pdftotext executable (the words of a PDF, with their boxes)")
)

const maxPages = 60

// a page to read: its size in the units of its word boxes (PDF points, or
// pixels for a picture)
type docPage struct {
	W     float64 `json:"w"`
	H     float64 `json:"h"`
	Words []word  `json:"words,omitempty"`
}

type word struct {
	T  string  `json:"t"`
	X0 float64 `json:"x0"`
	Y0 float64 `json:"y0"`
	X1 float64 `json:"x1"`
	Y1 float64 `json:"y1"`
}

func pagesDirOf(id string) string { return filepath.Join(*inboxDir, id+".pages") }

func pagePNG(id string, n int) string {
	return filepath.Join(pagesDirOf(id), fmt.Sprintf("p-%d.png", n))
}

// renders a PDF: one PNG a page (at most maxPages), and the words
func renderPDF(id string, pdf []byte) ([]docPage, error) {
	dir := pagesDirOf(id)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, err
	}
	src := filepath.Join(dir, "doc.pdf")
	if err := os.WriteFile(src, pdf, 0o640); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	// 110 dpi: a page is about 900 px wide, the width of the paper
	if out, err := exec.CommandContext(ctx, *pdftoppm, "-gray", "-r", "110", "-png", "-l", strconv.Itoa(maxPages),
		src, filepath.Join(dir, "p")).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("pdftoppm: %v: %s", err, tail(string(out), 5))
	}
	// pdftoppm pads the page numbers to the width of the last one
	files, _ := filepath.Glob(filepath.Join(dir, "p-*.png"))
	for _, f := range files {
		var n int
		if _, err := fmt.Sscanf(filepath.Base(f), "p-%d.png", &n); err == nil && f != pagePNG(id, n) {
			os.Rename(f, pagePNG(id, n))
		}
	}
	html, err := exec.CommandContext(ctx, *pdftotext, "-bbox", "-l", strconv.Itoa(maxPages), src, "-").Output()
	if err != nil {
		return nil, fmt.Errorf("pdftotext: %v", err)
	}
	var doc struct {
		Pages []struct {
			W     float64 `xml:"width,attr"`
			H     float64 `xml:"height,attr"`
			Words []struct {
				X0 float64 `xml:"xMin,attr"`
				Y0 float64 `xml:"yMin,attr"`
				X1 float64 `xml:"xMax,attr"`
				Y1 float64 `xml:"yMax,attr"`
				T  string  `xml:",chardata"`
			} `xml:"word"`
		} `xml:"body>doc>page"`
	}
	d := xml.NewDecoder(bytes.NewReader(html))
	d.Strict = false
	d.AutoClose = xml.HTMLAutoClose
	d.Entity = xml.HTMLEntity
	if err := d.Decode(&doc); err != nil {
		return nil, fmt.Errorf("pdftotext: %v", err)
	}
	var pages []docPage
	for _, p := range doc.Pages {
		pg := docPage{W: p.W, H: p.H}
		for _, w := range p.Words {
			pg.Words = append(pg.Words, word{w.T, w.X0, w.Y0, w.X1, w.Y1})
		}
		pages = append(pages, pg)
	}
	if len(pages) == 0 {
		return nil, fmt.Errorf("the PDF has no pages")
	}
	return pages, nil
}

// a picture is one page, with no words
func storePicture(id string, pic []byte) ([]docPage, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(pic))
	if err != nil {
		return nil, fmt.Errorf("not a PNG or JPEG picture: %v", err)
	}
	if err := os.MkdirAll(pagesDirOf(id), 0o750); err != nil {
		return nil, err
	}
	// kept as sent: the tablet turns it grey itself
	if err := os.WriteFile(pagePNG(id, 1), pic, 0o640); err != nil {
		return nil, err
	}
	return []docPage{{W: float64(cfg.Width), H: float64(cfg.Height)}}, nil
}

func inboxPage(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	n, err := strconv.Atoi(r.PathValue("n"))
	if !docID.MatchString(id) || err != nil || n < 1 || n > maxPages {
		fail(w, http.StatusNotFound, "no such page")
		return
	}
	b, err := os.ReadFile(pagePNG(id, n))
	if err != nil {
		fail(w, http.StatusNotFound, "no such page")
		return
	}
	w.Header().Set("Content-Type", http.DetectContentType(b))
	w.Write(b)
}
