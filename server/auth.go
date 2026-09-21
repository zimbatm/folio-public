package main

import (
	"crypto/subtle"
	"log"
	"net/http"
	"os"
	"strings"
)

// the server starts builds with full tools and holds the notebooks, so every
// route needs the token: the network in front of it is not the gate
func readToken() string {
	if *tokenFile == "" {
		log.Fatal("folio-server: --token-file is required")
	}
	b, err := os.ReadFile(*tokenFile)
	if err != nil {
		log.Fatalf("folio-server: --token-file: %v", err)
	}
	t := strings.TrimSpace(string(b))
	if t == "" {
		log.Fatal("folio-server: --token-file is empty")
	}
	return t
}

func requireToken(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("x-api-key")), []byte(token)) != 1 {
			fail(w, http.StatusUnauthorized, "invalid x-api-key")
			return
		}
		next.ServeHTTP(w, r)
	})
}
