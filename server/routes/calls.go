package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/go-chi/chi/v5"
)

func CallRoute(router chi.Router) {
	// Each call asks once, so a few a minute is plenty.
	limiter := middlewares.NewRateLimiter(0.2, 5.0).WithMessage("Rate limit exceeded. Too many call setup requests.")

	router.Use(middlewares.AuthGuard)
	router.With(limiter.Limit).Get("/ice-servers", controllers.HandleICEServers)
}
