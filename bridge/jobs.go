package main

// Jobs: the same request as /v1/messages, answered in the background. The
// tablet app closes whenever the user closes it, and a synchronous request
// dies with it; a job keeps running here, and the app fetches the answer when
// it opens again. With --jobs-dir, a job survives a bridge restart: it is a
// file there, and a job that was still running starts again.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	maxRunning = 4
	keepDone   = time.Hour
)

var jobsDir = flag.String("jobs-dir", "", "directory that keeps jobs across restarts (they hold the page text); empty keeps them in memory only")

type job struct {
	State    string         `json:"state"` // running, done or failed
	Message  map[string]any `json:"message,omitempty"`
	Error    string         `json:"error,omitempty"`
	finished time.Time
}

type savedJob struct {
	job
	Finished time.Time `json:"finished"`
	Request  request   `json:"request"`
}

var (
	jobsMu sync.Mutex
	jobs   = map[string]*job{}
)

func jobPath(id string) string { return filepath.Join(*jobsDir, id+".json") }

// save writes the job atomically; the caller holds jobsMu
func save(id string, j *job, req request) {
	if *jobsDir == "" {
		return
	}
	b, _ := json.Marshal(savedJob{job: *j, Finished: j.finished, Request: req})
	tmp := jobPath(id) + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		log.Printf("job %s: save: %v", id, err)
		return
	}
	if err := os.Rename(tmp, jobPath(id)); err != nil {
		log.Printf("job %s: save: %v", id, err)
	}
}

// loadJobs restores the saved jobs and starts again the ones a restart cut off
func loadJobs() {
	if *jobsDir == "" {
		return
	}
	if err := os.MkdirAll(*jobsDir, 0o700); err != nil {
		log.Fatalf("folio-bridge: --jobs-dir: %v", err)
	}
	files, _ := filepath.Glob(filepath.Join(*jobsDir, "*.json"))
	restarted := 0
	for _, f := range files {
		id := strings.TrimSuffix(filepath.Base(f), ".json")
		var s savedJob
		b, err := os.ReadFile(f)
		if err == nil {
			err = json.Unmarshal(b, &s)
		}
		if err != nil || (s.State != "running" && time.Since(s.Finished) > keepDone) {
			os.Remove(f)
			continue
		}
		j := &job{State: s.State, Message: s.Message, Error: s.Error, finished: s.Finished}
		jobs[id] = j
		if j.State == "running" {
			restarted++
			go runJob(id, j, s.Request)
		}
	}
	log.Printf("jobs: %d kept, %d started again", len(jobs), restarted)
}

func runJob(id string, j *job, req request) {
	msg, err := answer(context.Background(), req)
	jobsMu.Lock()
	defer jobsMu.Unlock()
	j.finished = time.Now()
	if err != nil {
		j.State, j.Error = "failed", err.Error()
	} else {
		j.State, j.Message = "done", msg
	}
	save(id, j, req)
}

func startJob(w http.ResponseWriter, r *http.Request) {
	req, ok := decode(w, r)
	if !ok {
		return
	}
	jobsMu.Lock()
	running := 0
	for id, j := range jobs {
		if j.State == "running" {
			running++
		} else if time.Since(j.finished) > keepDone {
			delete(jobs, id)
			if *jobsDir != "" {
				os.Remove(jobPath(id))
			}
		}
	}
	if running >= maxRunning {
		jobsMu.Unlock()
		apiError(w, http.StatusTooManyRequests, "rate_limit_error", "too many jobs running")
		return
	}
	b := make([]byte, 16)
	rand.Read(b)
	id := hex.EncodeToString(b)
	j := &job{State: "running"}
	jobs[id] = j
	save(id, j, req)
	jobsMu.Unlock()

	go runJob(id, j, req)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(map[string]string{"id": id, "state": "running"})
}

func getJob(w http.ResponseWriter, r *http.Request) {
	if !authorized(r) {
		apiError(w, http.StatusUnauthorized, "authentication_error", "invalid x-api-key")
		return
	}
	jobsMu.Lock()
	j, ok := jobs[r.PathValue("id")]
	var out job
	if ok {
		out = *j
	}
	jobsMu.Unlock()
	if !ok {
		apiError(w, http.StatusNotFound, "not_found_error", "no such job (the bridge may have restarted)")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}
