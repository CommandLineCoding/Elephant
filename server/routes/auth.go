package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/go-chi/chi/v5"
)

func AuthRoute(router chi.Router) {
	// Each attempt costs an Argon2 hash (CPU and memory), and logins are the
	// way to guess passwords, so both get a per-address limit. A burst covers a
	// normal user retrying a typo; the refill is slow on purpose.
	loginLimiter := middlewares.NewRateLimiter(1.0/5, 10).
		WithMessage("Too many sign-in attempts. Please wait a moment and try again.")
	registerLimiter := middlewares.NewRateLimiter(1.0/20, 5).
		WithMessage("Too many sign-up attempts. Please wait a moment and try again.")

	router.With(registerLimiter.Limit).Post("/register", controllers.HandleRegister)
	router.With(loginLimiter.Limit).Post("/login", controllers.HandleLogin)
	router.Post("/refresh", controllers.HandleRefresh)

	router.Get("/{provider}", controllers.HandleOAuthRedirect)
	router.Get("/{provider}/callback", controllers.HandleOAuthCallback)
}
