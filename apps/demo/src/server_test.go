package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

func get(h http.Handler, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestHealthz(t *testing.T) {
	rec := get(NewHandler("web", false), "/healthz")
	if rec.Code != 200 || rec.Body.String() != "ok" {
		t.Fatalf("got %d %q", rec.Code, rec.Body.String())
	}
}

func TestFeatureFlagOn(t *testing.T) {
	rec := get(NewHandler("api", true), "/feature")
	if rec.Code != 200 || strings.TrimSpace(rec.Body.String()) != `{"new_banner":true}` {
		t.Fatalf("got %d %q", rec.Code, rec.Body.String())
	}
}

func TestFeatureFlagOff(t *testing.T) {
	rec := get(NewHandler("web", false), "/feature")
	if strings.TrimSpace(rec.Body.String()) != `{"new_banner":false}` {
		t.Fatalf("got %q", rec.Body.String())
	}
}

func TestMetricsExposeRequestHistogram(t *testing.T) {
	h := NewHandler("web", false)
	get(h, "/healthz")
	body := get(h, "/metrics").Body.String()
	for _, want := range []string{"http_request_duration_seconds_bucket", `http_requests_total{code="200"}`} {
		if !strings.Contains(body, want) {
			t.Fatalf("metrics missing %q", want)
		}
	}
}

func TestWorkerModeServesOnlyHealthzAndMetrics(t *testing.T) {
	h := NewHandler("worker", false)
	if get(h, "/healthz").Code != 200 || get(h, "/metrics").Code != 200 {
		t.Fatal("healthz/metrics should be served")
	}
	if get(h, "/feature").Code != 404 {
		t.Fatal("/feature should 404 in worker mode")
	}
}

func TestInvalidPortFallsBackTo8080(t *testing.T) {
	cases := map[string]string{"": "8080", "abc": "8080", "0": "8080", "70000": "8080", "-1": "8080", "9090": "9090"}
	for in, want := range cases {
		if got := portFromEnv(func(string) string { return in }); got != want {
			t.Errorf("PORT=%q: got %q want %q", in, got, want)
		}
	}
}

func TestWorkerIncrementsCounter(t *testing.T) {
	reg := prometheus.NewRegistry()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	RunWorker(ctx, reg, 5*time.Millisecond)
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		if mf.GetName() == "worker_jobs_total" {
			if v := mf.GetMetric()[0].GetCounter().GetValue(); v < 2 {
				t.Fatalf("expected >=2 jobs, got %v", v)
			}
			return
		}
	}
	t.Fatal("worker_jobs_total not registered")
}
