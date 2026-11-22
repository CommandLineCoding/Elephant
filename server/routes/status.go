package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/go-chi/chi/v5"
)

// StatusRoute is mounted at /api/status.
func StatusRoute(router chi.Router) {
	// A person posts a few statuses in a row at most; the daily cap is in the
	// handler.
	limiter := middlewares.NewRateLimiter(0.1, 5.0).WithMessage("Rate limit exceeded. Too many statuses.")

	router.Use(middlewares.AuthGuard)
	router.With(limiter.Limit).Post("/", controllers.HandlePostStatus) // POST   /api/status
	router.Get("/", controllers.HandleListStatuses)                    // GET    /api/status
	router.Get("/mine", controllers.HandleListOwnStatuses)             // GET    /api/status/mine
	router.Delete("/{id}", controllers.HandleDeleteStatus)             // DELETE /api/status/:id
	router.Post("/{id}/view", controllers.HandleViewStatus)            // POST   /api/status/:id/view
}
