package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/go-chi/chi/v5"
)

// ReportRoute is mounted at /api/reports.
func ReportRoute(router chi.Router) {
	// A person reports a handful of times, not in a stream.
	limiter := middlewares.NewRateLimiter(0.05, 3.0).WithMessage("Rate limit exceeded. Too many reports.")

	router.Use(middlewares.AuthGuard)
	router.With(limiter.Limit).Post("/", controllers.HandleCreateReport)
}

// AdminRoute is mounted at /api/admin. Only accounts in ADMIN_USER_IDS may use it.
func AdminRoute(router chi.Router) {
	router.Use(middlewares.AuthGuard)
	router.Use(middlewares.AdminGuard)
	router.Get("/reports", controllers.HandleAdminListReports)
}
