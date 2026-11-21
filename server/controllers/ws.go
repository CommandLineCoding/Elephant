package controllers

import (
	"net/http"

	"github.com/commandlinecoding/elephant/server/repository"
	"github.com/commandlinecoding/elephant/server/services"
	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

func HandleWSUpgrade(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	if token == "" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}

	uid, sid, err := services.ParseToken(token)
	if err != nil {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}

	// A device that was signed out can't reconnect with the access token it
	// still holds. (A token from before sessions has no session to check.)
	if sid != "" {
		active, err := repository.NewRefreshTokenRepository().SessionActive(r.Context(), uid, sid)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if !active {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}

	client := services.NewWSClient(uid, conn)
	client.SessionID = sid

	services.Hub.Register <- client

	go client.WritePump()
	go client.ReadPump()
}
