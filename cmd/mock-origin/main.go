// Package main provides a simple mock origin server for testing the cache.
// It returns synthetic responses for any URL path, allowing the cache
// experiment to run without internet access.
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"time"
)

func main() {
	port := flag.Int("port", 9999, "Port to listen on")
	flag.Parse()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// Generate a synthetic response based on the URL path
		path := r.URL.Path
		
		// Simulate some processing delay (very small)
		time.Sleep(5 * time.Millisecond)

		// Return a consistent response for each path
		response := fmt.Sprintf(`{
  "path": "%s",
  "timestamp": "%s",
  "message": "Mock origin response for testing",
  "data": "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
}`, path, time.Now().Format(time.RFC3339))

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(response))
	})

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("Mock origin server starting on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

