package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/go-chi/chi/v5"
)

// InviteRoute is mounted at /api/invites: what a group invite link shows, and
// using it.
func InviteRoute(router chi.Router) {
	// A code is long and random, so guessing is hopeless; this only keeps a
	// flood of tries from costing the database.
	limiter := middlewares.NewRateLimiter(0.2, 10.0).WithMessage("Rate limit exceeded. Too many invite link tries.")

	router.Use(middlewares.AuthGuard)
	router.With(limiter.Limit).Get("/{code}", controllers.HandlePreviewInvite)
	router.With(limiter.Limit).Post("/{code}/join", controllers.HandleJoinInvite)
}
