package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/go-chi/chi/v5"
)

func GroupRoute(router chi.Router) {
	router.Use(middlewares.AuthGuard)

	router.Post("/", controllers.HandleCreateGroup) // POST /api/groups
	router.Get("/", controllers.HandleListMyGroups) // GET /api/groups

	router.Route("/{id}", func(sr chi.Router) {
		sr.Use(middlewares.GroupAuthGuard)

		sr.Get("/", controllers.HandleGetGroupDetails)             // GET /api/groups/{id}
		sr.Get("/messages", controllers.HandleGetGroupMessages)    // GET /api/groups/{id}/messages
		sr.Get("/members", controllers.HandleListGroupMembers)     // GET /api/groups/{id}/members
		sr.Post("/leave", controllers.HandleLeaveGroup)            // POST /api/groups/{id}/leave
		sr.Delete("/history", controllers.HandleClearGroupHistory) // DELETE /api/groups/{id}/history

		sr.With(middlewares.GroupAdminGuard).Patch("/", controllers.HandleUpdateGroup)                   // PATCH /api/groups/{id}
		sr.With(middlewares.GroupAdminGuard).Delete("/", controllers.HandleDeleteGroup)                  // DELETE /api/groups/{id}
		sr.With(middlewares.GroupAdminGuard).Post("/members", controllers.HandleAddMember)               // POST /api/groups/{id}/members
		sr.With(middlewares.GroupAdminGuard).Delete("/members/{userId}", controllers.HandleRemoveMember) // DELETE /api/groups/{id}/members/{userId}

		// The invite link and who is waiting to be let in (admins).
		sr.With(middlewares.GroupAdminGuard).Get("/invite", controllers.HandleGetInvite)                      // GET /api/groups/{id}/invite
		sr.With(middlewares.GroupAdminGuard).Put("/invite", controllers.HandleSetInvite)                      // PUT /api/groups/{id}/invite
		sr.With(middlewares.GroupAdminGuard).Delete("/invite", controllers.HandleDeleteInvite)                // DELETE /api/groups/{id}/invite
		sr.With(middlewares.GroupAdminGuard).Get("/requests", controllers.HandleListJoinRequests)             // GET /api/groups/{id}/requests
		sr.With(middlewares.GroupAdminGuard).Post("/requests/{userId}", controllers.HandleApproveJoinRequest) // POST /api/groups/{id}/requests/{userId}
		sr.With(middlewares.GroupAdminGuard).Delete("/requests/{userId}", controllers.HandleDenyJoinRequest)  // DELETE /api/groups/{id}/requests/{userId}
	})
}
