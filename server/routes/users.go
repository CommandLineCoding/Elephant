package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/go-chi/chi/v5"
)

func UserRoute(router chi.Router) {
	searchLimiter := middlewares.NewRateLimiter(2.0, 10.0).WithMessage("Rate limit exceeded. Too many search requests.")

	router.Use(middlewares.AuthGuard)

	router.Get("/me", controllers.HandleGetMe)
	router.Delete("/me", controllers.HandleDeleteMe)
	router.Post("/me/push", controllers.HandlePushRegister)
	router.Delete("/me/push", controllers.HandlePushUnregister)
	router.With(searchLimiter.Limit).Get("/search", controllers.HandleUserSearch)
	router.Get("/{id}", controllers.HandleGetUserByID)
}
