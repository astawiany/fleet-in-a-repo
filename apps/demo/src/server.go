package main

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// portFromEnv returns the listen port, defaulting to "8080" when PORT is
// empty, non-numeric, or outside 1-65535.
func portFromEnv(getenv func(string) string) string {
	p := getenv("PORT")
	if n, err := strconv.Atoi(p); err != nil || n < 1 || n > 65535 {
		return "8080"
	}
	return p
}

// NewHandler builds the HTTP handler for the given mode using a fresh registry.
func NewHandler(mode string, newBanner bool) http.Handler {
	return newHandler(mode, newBanner, prometheus.NewRegistry())
}

func newHandler(mode string, newBanner bool, reg *prometheus.Registry) http.Handler {
	requests := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total", Help: "HTTP requests by status code.",
	}, []string{"code"})
	duration := prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name: "http_request_duration_seconds", Help: "HTTP request latency.",
		Buckets: prometheus.DefBuckets,
	}, []string{})
	reg.MustRegister(requests, duration)

	// App routes only are instrumented: kubelet probes (/healthz) and Prometheus scrapes
	// (/metrics) would otherwise dominate the Demo SLIs and burn-rate alerts.
	app := http.NewServeMux()
	if mode != "worker" {
		app.HandleFunc("/feature", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]bool{"new_banner": newBanner})
		})
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.Handle("/", promhttp.InstrumentHandlerDuration(duration,
		promhttp.InstrumentHandlerCounter(requests, app)))
	return mux
}
