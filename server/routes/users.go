package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/go-chi/chi/v5"
)

func UserRoute(router chi.Router) {
	searchLimiter := middlewares.NewRateLimiter(2.0, 10.0).WithMessage("Rate limit exceeded. Too many search requests.")
	codeLimiter := middlewares.NewRateLimiter(1.0/5, 10).WithMessage("Too many attempts. Please wait a moment and try again.")
	// An export reads everything the person has, so a few in a row is plenty.
	exportLimiter := middlewares.NewRateLimiter(1.0/60, 3).WithMessage("Too many exports. Please wait a minute and try again.")
	// Each page of messages is bounded, so paging through a big account only
	// has to be slow enough that pages don't pile up in memory.
	exportPageLimiter := middlewares.NewRateLimiter(1.0/2, 3).WithMessage("Too many export pages. Please wait a moment and try again.")

	router.Use(middlewares.AuthGuard)

	router.Get("/me", controllers.HandleGetMe)
	router.Delete("/me", controllers.HandleDeleteMe)
	router.Patch("/me", controllers.HandleUpdateMe)
	router.With(exportLimiter.Limit).Get("/me/export", controllers.HandleExportMe)
	router.With(exportPageLimiter.Limit).Get("/me/export/messages", controllers.HandleExportMessages)
	router.Post("/me/push", controllers.HandlePushRegister)
	router.Delete("/me/push", controllers.HandlePushUnregister)
	router.Get("/me/blocked", controllers.HandleListBlocked)
	router.Get("/me/settings", controllers.HandleGetSettings)
	router.Patch("/me/settings", controllers.HandleUpdateSettings)
	router.Get("/me/2fa", controllers.HandleTwoFactorStatus)
	router.Post("/me/2fa/setup", controllers.HandleTwoFactorSetup)
	router.With(codeLimiter.Limit).Post("/me/2fa/enable", controllers.HandleTwoFactorEnable)
	router.With(codeLimiter.Limit).Post("/me/2fa/disable", controllers.HandleTwoFactorDisable)
	router.Get("/me/sessions", controllers.HandleListSessions)
	router.Delete("/me/sessions", controllers.HandleDeleteOtherSessions)
	router.Delete("/me/sessions/{id}", controllers.HandleDeleteSession)
	router.With(searchLimiter.Limit).Get("/search", controllers.HandleUserSearch)
	router.Get("/{id}", controllers.HandleGetUserByID)
	router.Post("/{id}/block", controllers.HandleBlockUser)
	router.Delete("/{id}/block", controllers.HandleUnblockUser)
}
