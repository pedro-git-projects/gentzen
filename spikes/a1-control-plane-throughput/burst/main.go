// Command a1burst drives a one-shot burst-drain benchmark against the Gentzen
// A-1 control-plane job table.
//
// Unlike the recycle-churn workload, this driver does not recycle anything.
// A fixed burst of READY jobs is seeded externally, every claimer is connected
// and prepared up front, all claimers are released simultaneously by a barrier,
// and the run ends the instant the last job has been claimed.
//
// The measured interval is therefore "time to drain the burst", not
// "throughput during a fixed window".
package main

import (
	"context"
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
)

// claimSQL is the control-plane hot path.
//
// It is the same claim used by the recycle-churn benchmark, with two
// differences: it is issued as a single implicit transaction rather than
// wrapped in explicit BEGIN/COMMIT, and it is parameterized so the driver can
// vary batch size without re-preparing.
const claimSQL = `
WITH picked AS (
    SELECT id
    FROM jobs
    WHERE state = 0
      AND available_at <= clock_timestamp()
    ORDER BY available_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT $2
)
UPDATE jobs AS j
SET
    state       = 1,
    claimed_by  = $1,
    claimed_at  = clock_timestamp(),
    claim_count = claim_count + 1
FROM picked
WHERE j.id = picked.id`

// txn is one claim round trip.
type txn struct {
	worker int
	// Nanoseconds relative to the barrier release.
	startNs int64
	endNs   int64
	rows    int64
	failed  bool
}

func main() {
	var (
		claimers = flag.Int("claimers", 8, "number of concurrent claimers")
		batch    = flag.Int("batch", 50, "rows requested per claim")
		total    = flag.Int64("jobs", 22000, "burst size; the run ends when this many jobs are claimed")
		out      = flag.String("out", ".", "directory to write results into")
		timeout  = flag.Duration("timeout", 5*time.Minute, "abort if the burst has not drained within this")
	)

	flag.Parse()

	if err := run(*claimers, *batch, *total, *out, *timeout); err != nil {
		fmt.Fprintf(os.Stderr, "a1burst: %v\n", err)
		os.Exit(1)
	}
}

func run(claimers, batch int, total int64, out string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// Connect and prepare every claimer before the measured interval starts.
	// A real dispatcher runs with a warm pool; connection establishment is
	// not part of burst-drain latency.
	connectStart := time.Now()

	conns := make([]*pgx.Conn, claimers)

	for i := range conns {
		conn, err := pgx.Connect(ctx, "")
		if err != nil {
			return fmt.Errorf("connect claimer %d: %w", i, err)
		}

		if _, err := conn.Prepare(ctx, "claim", claimSQL); err != nil {
			return fmt.Errorf("prepare claimer %d: %w", i, err)
		}

		conns[i] = conn
	}

	connectElapsed := time.Since(connectStart)

	defer func() {
		for _, conn := range conns {
			if conn != nil {
				_ = conn.Close(context.Background())
			}
		}
	}()

	// Sized for the worst case where a single worker drains the whole burst,
	// so that recording a transaction never allocates inside the measured
	// interval.
	capacityPerWorker := total/int64(batch) + 1024

	var (
		claimed atomic.Int64
		release = make(chan struct{})
		ready   sync.WaitGroup
		done    sync.WaitGroup

		records = make([][]txn, claimers)
		errs    = make([]error, claimers)
	)

	ready.Add(claimers)
	done.Add(claimers)

	for i := range conns {
		records[i] = make([]txn, 0, capacityPerWorker)

		go func(worker int, conn *pgx.Conn) {
			defer done.Done()

			ready.Done()
			<-release

			for claimed.Load() < total {
				start := time.Now()

				tag, err := conn.Exec(ctx, "claim", worker, batch)

				end := time.Now()

				rec := txn{
					worker:  worker,
					startNs: start.UnixNano(),
					endNs:   end.UnixNano(),
				}

				if err != nil {
					rec.failed = true
					records[worker] = append(records[worker], rec)
					errs[worker] = err

					return
				}

				rec.rows = tag.RowsAffected()
				records[worker] = append(records[worker], rec)

				if rec.rows > 0 {
					claimed.Add(rec.rows)
				}

				// A zero-row claim means every remaining job is momentarily
				// locked by another claimer. Retry immediately; the loop
				// condition is what ends the run.
			}
		}(i, conns[i])
	}

	ready.Wait()

	// Barrier release. This timestamp is t=0 for the whole benchmark.
	burstStart := time.Now()

	close(release)

	done.Wait()

	for worker, err := range errs {
		if err != nil {
			return fmt.Errorf("claimer %d failed: %w", worker, err)
		}
	}

	if err := ctx.Err(); err != nil {
		return fmt.Errorf("burst did not drain within %s (claimed %d of %d): %w",
			timeout, claimed.Load(), total, err)
	}

	return report(out, claimers, batch, total, burstStart, connectElapsed, records)
}

func report(
	out string,
	claimers, batch int,
	total int64,
	burstStart time.Time,
	connectElapsed time.Duration,
	records [][]txn,
) error {
	base := burstStart.UnixNano()

	var (
		all       []txn
		latencies []int64 // productive claims only, in microseconds
		empties   int64
		claimed   int64
		drainEnd  int64
		fullBatch int64
	)

	for _, workerRecords := range records {
		for _, rec := range workerRecords {
			all = append(all, rec)

			if rec.rows == 0 {
				empties++

				continue
			}

			claimed += rec.rows
			latencies = append(latencies, (rec.endNs-rec.startNs)/1000)

			if rec.rows == int64(batch) {
				fullBatch++
			}

			if rec.endNs > drainEnd {
				drainEnd = rec.endNs
			}
		}
	}

	// Drain time is measured from barrier release to the commit of the claim
	// that took the last job, not to when the last worker goroutine noticed.
	drainNs := drainEnd - base
	drainSeconds := float64(drainNs) / 1e9

	sort.Slice(all, func(i, j int) bool { return all[i].startNs < all[j].startNs })

	if err := writeTxnCSV(filepath.Join(out, "burst-transactions.csv"), base, all); err != nil {
		return err
	}

	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })

	productive := int64(len(latencies))

	summary := filepath.Join(out, "burst-summary.txt")

	f, err := os.Create(summary)
	if err != nil {
		return err
	}
	defer f.Close()

	emit := func(format string, args ...any) {
		fmt.Fprintf(f, format+"\n", args...)
		fmt.Printf(format+"\n", args...)
	}

	emit("claimers=%d", claimers)
	emit("batch=%d", batch)
	emit("burst_jobs=%d", total)
	emit("connect_setup_ms=%.3f", float64(connectElapsed.Microseconds())/1000)
	emit("drain_seconds=%.6f", drainSeconds)
	emit("drain_ms=%.3f", drainSeconds*1000)
	emit("jobs_per_second=%.2f", float64(claimed)/drainSeconds)
	emit("claimed=%d", claimed)
	emit("transactions=%d", int64(len(all)))
	emit("productive_transactions=%d", productive)
	emit("empty_transactions=%d", empties)
	emit("full_batch_transactions=%d", fullBatch)

	if productive > 0 {
		emit("batch_fill_pct=%.2f", float64(claimed)/float64(productive*int64(batch))*100)
		emit("mean_claim_latency_ms=%.3f", meanUs(latencies)/1000)
		emit("p50_ms=%.3f", float64(percentile(latencies, 0.50))/1000)
		emit("p95_ms=%.3f", float64(percentile(latencies, 0.95))/1000)
		emit("p99_ms=%.3f", float64(percentile(latencies, 0.99))/1000)
		emit("max_ms=%.3f", float64(latencies[len(latencies)-1])/1000)
	}

	return nil
}

func writeTxnCSV(path string, base int64, all []txn) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	w := csv.NewWriter(f)
	defer w.Flush()

	if err := w.Write([]string{"worker", "start_us", "end_us", "latency_us", "rows", "failed"}); err != nil {
		return err
	}

	for _, rec := range all {
		row := []string{
			strconv.Itoa(rec.worker),
			strconv.FormatInt((rec.startNs-base)/1000, 10),
			strconv.FormatInt((rec.endNs-base)/1000, 10),
			strconv.FormatInt((rec.endNs-rec.startNs)/1000, 10),
			strconv.FormatInt(rec.rows, 10),
			strconv.FormatBool(rec.failed),
		}

		if err := w.Write(row); err != nil {
			return err
		}
	}

	return w.Error()
}

func percentile(sorted []int64, p float64) int64 {
	if len(sorted) == 0 {
		return 0
	}

	index := int(float64(len(sorted))*p+0.9999999) - 1

	if index < 0 {
		index = 0
	}

	if index >= len(sorted) {
		index = len(sorted) - 1
	}

	return sorted[index]
}

func meanUs(values []int64) float64 {
	if len(values) == 0 {
		return 0
	}

	var sum int64

	for _, v := range values {
		sum += v
	}

	return float64(sum) / float64(len(values))
}
