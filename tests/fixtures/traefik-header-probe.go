// Synthetic T75 backend: echo the request headers received through Traefik.
package main

import (
	"log"
	"net/http"
	"net/http/httputil"
)

func echoHeaders(w http.ResponseWriter, r *http.Request) {
	request, err := httputil.DumpRequest(r, false)
	if err != nil {
		http.Error(w, "synthetic request dump failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write(request)
}

func main() {
	log.Fatal(http.ListenAndServe(":80", http.HandlerFunc(echoHeaders)))
}
