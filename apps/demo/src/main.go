package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

func main() {
	mode := flag.String("mode", "web", "web|api|worker")
	flag.Parse()
	switch *mode {
	case "web", "api", "worker":
	default:
		fmt.Fprintf(os.Stderr, "invalid --mode %q (want web|api|worker)\n", *mode)
		os.Exit(2)
	}
	newBanner := os.Getenv("FEATURE_NEW_BANNER") == "true"

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	reg := prometheus.NewRegistry()
	if *mode == "worker" {
		go RunWorker(ctx, reg, 5*time.Second)
	}
	srv := &http.Server{
		Addr:              ":" + portFromEnv(os.Getenv),
		Handler:           newHandler(*mode, newBanner, reg),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()
	log.Printf("demo mode=%s addr=%s new_banner=%v", *mode, srv.Addr, newBanner)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
