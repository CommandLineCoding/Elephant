package routes

import (
	"github.com/commandlinecoding/elephant/server/controllers"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/go-chi/chi/v5"
)

func MessageRoute(router chi.Router) {
	router.Use(middlewares.AuthGuard)

	router.Post("/", controllers.HandleSendMessage)                                      // POST   /api/messages
	router.Get("/", controllers.HandleGetChatHistory)                                    // GET    /api/messages?with=UUID
	router.Get("/conversations", controllers.HandleGetConversations)                     // GET    /api/messages/conversations
	router.Delete("/conversations/{userId}", controllers.HandleDeleteDirectConversation) // DELETE /api/messages/conversations/:userId?for=me|everyone
	router.Put("/{id}", controllers.HandleEditMessage)                                   // PUT    /api/messages/:id
	router.Delete("/{id}", controllers.HandleDeleteMessage)                              // DELETE /api/messages/:id?for=me|everyone
	router.Post("/requests/{userId}/accept", controllers.HandleAcceptRequest)            // POST   /api/messages/requests/:userId/accept
	router.Post("/read", controllers.HandleMarkRead)                                     // POST   /api/messages/read
}
