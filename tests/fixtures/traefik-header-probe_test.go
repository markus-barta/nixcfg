package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEchoHeadersPreservesWhatTheProxyActuallySent(t *testing.T) {
	for _, trust := range []string{"yes", "spoofed"} {
		t.Run(trust, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, "http://backend.example.test/", nil)
			request.Header.Set("X-Is-Trusted", trust)
			request.Header.Set("X-Real-IP", "203.0.113.9")
			response := httptest.NewRecorder()
			echoHeaders(response, request)
			if response.Code != http.StatusOK {
				t.Fatalf("unexpected status: %d", response.Code)
			}
			body := response.Body.String()
			if !strings.Contains(body, "X-Is-Trusted: "+trust) || !strings.Contains(body, "X-Real-Ip: 203.0.113.9") {
				t.Fatal("backend did not preserve the received headers")
			}
		})
	}
}
