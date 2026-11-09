package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/go-chi/chi/v5"
)

// ErrorHandlers makes unknown routes and wrong methods answer with JSON. chi
// copies these handlers to routers mounted *after* they are set, so call this
// on the root router before mounting ApiRoute.
func ErrorHandlers(router chi.Router) {
	router.NotFound(controllers.HandleNotFound)
	router.MethodNotAllowed(controllers.HandleMethodNotAllowed)
}

func ApiRoute(router chi.Router) {
	router.Get("/health", controllers.HandleHealthCheck) // resolves to /api/health
	router.Get("/ws", controllers.HandleWSUpgrade)

	router.Route("/auth", AuthRoute)
	router.Route("/users", UserRoute)
	router.Route("/messages", MessageRoute)
	router.Route("/groups", GroupRoute)
	router.Route("/e2ee", E2EERoute)
}
