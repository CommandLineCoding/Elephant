package services

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/repository"
)

// cleanupLockID is the Postgres advisory lock held while cleaning, so that
// when several instances run only one of them does it each time.
const cleanupLockID int64 = 7249081116

const (
	cleanupBatch = 500
	// A run does at most this many full batches of one kind, so one backlog
	// can't keep the job busy for ever. The next run carries on.
	cleanupMaxBatches = 40
	// A push endpoint is dropped after this many failed pings in a row.
	pushFailureLimit = 20
)

// CleanupTask deletes one kind of expired data. Run deletes at most limit rows
// and reports how many it deleted; a full batch means there may be more.
type CleanupTask struct {
	Name string
	Run  func(ctx context.Context, limit int) (int64, error)
}

// CleanupReport is what one run deleted, by task name.
type CleanupReport map[string]int64

// Total is the number of rows deleted across all tasks.
func (r CleanupReport) Total() int64 {
	var n int64
	for _, c := range r {
		n += c
	}
	return n
}

func (r CleanupReport) String() string {
	var parts []string
	for name, c := range r {
		if c > 0 {
			parts = append(parts, fmt.Sprintf("%s=%d", name, c))
		}
	}
	if len(parts) == 0 {
		return "nothing to delete"
	}
	return strings.Join(parts, " ")
}

// Cleaner runs cleanup tasks on a schedule.
type Cleaner struct {
	tasks []CleanupTask

	mu       sync.Mutex
	lastRun  time.Time
	lastRan  bool // whether the last attempt held the lock
	totals   CleanupReport
	lastDone CleanupReport
}

// NewCleaner makes a cleaner that runs tasks, in order.
func NewCleaner(tasks ...CleanupTask) *Cleaner {
	return &Cleaner{tasks: tasks, totals: CleanupReport{}}
}

// Cleanup is the server's cleaner. Features that keep data with an expiry add
// their task here.
var Cleanup = NewCleaner(defaultCleanupTasks()...)

func defaultCleanupTasks() []CleanupTask {
	repo := repository.NewCleanupRepository()
	return []CleanupTask{
		{Name: "refresh_tokens", Run: repo.DeleteExpiredRefreshTokens},
		{Name: "messages", Run: repo.DeleteExpiredMessages},
		{Name: "statuses", Run: repo.DeleteExpiredStatuses},
		{Name: "push_endpoints", Run: func(ctx context.Context, limit int) (int64, error) {
			return repo.DeleteFailingPushEndpoints(ctx, pushFailureLimit, limit)
		}},
	}
}

// Add registers another task.
func (c *Cleaner) Add(t CleanupTask) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.tasks = append(c.tasks, t)
}

// RunOnce cleans if no other instance is. ran is false when another instance
// held the lock and this one did nothing.
func (c *Cleaner) RunOnce(ctx context.Context) (report CleanupReport, ran bool, err error) {
	conn, err := config.DB.Acquire(ctx)
	if err != nil {
		return nil, false, fmt.Errorf("acquire connection: %w", err)
	}
	defer conn.Release()

	var got bool
	if err := conn.QueryRow(ctx, "SELECT pg_try_advisory_lock($1)", cleanupLockID).Scan(&got); err != nil {
		return nil, false, fmt.Errorf("take cleanup lock: %w", err)
	}
	if !got {
		return nil, false, nil
	}
	defer func() { _, _ = conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", cleanupLockID) }()

	c.mu.Lock()
	tasks := append([]CleanupTask(nil), c.tasks...)
	c.mu.Unlock()

	report = CleanupReport{}
	for _, task := range tasks {
		for i := 0; i < cleanupMaxBatches; i++ {
			n, terr := task.Run(ctx, cleanupBatch)
			report[task.Name] += n
			if terr != nil {
				err = fmt.Errorf("%s: %w", task.Name, terr)
				break
			}
			if n < cleanupBatch {
				break
			}
		}
	}

	c.mu.Lock()
	c.lastRun, c.lastRan, c.lastDone = time.Now().UTC(), true, report
	for name, n := range report {
		c.totals[name] += n
	}
	c.mu.Unlock()
	return report, true, err
}

// Start runs the cleanup now and then every interval until ctx ends. It
// returns at once.
func (c *Cleaner) Start(ctx context.Context, interval time.Duration) {
	go func() {
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			c.runAndLog(ctx)
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
		}
	}()
}

func (c *Cleaner) runAndLog(ctx context.Context) {
	runCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	report, ran, err := c.RunOnce(runCtx)
	switch {
	case err != nil:
		log.Printf("cleanup: %v (deleted: %s)", err, report)
	case ran && report.Total() > 0:
		log.Printf("cleanup: deleted %s", report)
	}
}

// Status is what the health check shows about the cleanup: when it last ran
// here, what that run deleted and how much has been deleted since this
// instance started. It holds counts only.
func (c *Cleaner) Status() map[string]interface{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	status := map[string]interface{}{
		"deleted_total": c.totals.Total(),
	}
	if c.lastRan {
		status["last_run"] = c.lastRun
		last := map[string]int64{}
		for k, v := range c.lastDone {
			last[k] = v
		}
		status["last_deleted"] = last
	}
	return status
}

// CleanupInterval reads CLEANUP_INTERVAL_MINUTES. Zero, or anything that
// isn't a positive whole number, means the job is off.
func CleanupInterval() time.Duration {
	n, err := strconv.Atoi(strings.TrimSpace(env.CLEANUP_INTERVAL_MINUTES))
	if err != nil || n <= 0 {
		return 0
	}
	return time.Duration(n) * time.Minute
}
