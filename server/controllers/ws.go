package controllers

import (
	"net/http"

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

	uid, err := services.VerifyAccessToken(token)
	if err != nil {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}

	client := services.NewWSClient(uid, conn)

	services.Hub.Register <- client

	go client.WritePump()
	go client.ReadPump()
}
