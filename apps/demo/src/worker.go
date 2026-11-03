package main

import (
	"context"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// RunWorker simulates a job every interval, incrementing worker_jobs_total on
// reg, until ctx is cancelled.
func RunWorker(ctx context.Context, reg prometheus.Registerer, interval time.Duration) {
	jobs := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "worker_jobs_total", Help: "Jobs processed by the worker.",
	})
	reg.MustRegister(jobs)
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			jobs.Inc()
		}
	}
}
