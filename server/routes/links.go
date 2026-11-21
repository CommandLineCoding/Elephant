package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/go-chi/chi/v5"
)

// LinkRoutes serves profile links (/u/<username>), group invite links (/g/<code>) and the Android app-link
// declaration, on the root router.
func LinkRoutes(router chi.Router) {
	router.Get("/.well-known/assetlinks.json", controllers.HandleAssetLinks)
	router.Get("/u/{username}", controllers.HandleProfileLink)
	router.Get("/g/{code}", controllers.HandleGroupLink)
}
