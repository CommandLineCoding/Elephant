package main

import (
	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/routes"
	"github.com/commandlinecoding/elephant/server/services"
)

func main() {
	// db init
	config.InitDatabase()
	defer config.DB.Close()

	// OAuth init
	config.InitOAuth()

	// WS init
	go services.Hub.Run()

	// app init
	app := config.App

	// middlewares
	app.Use(middlewares.CorsHandler)
	app.Use(middlewares.SimpleLogger)

	// JSON 404/405. Must come before the sub-groups are mounted.
	routes.ErrorHandlers(app.Mux)

	// routes mapping using sub-groups
	routes.ApiRoute(app.Group("/api"))

	// starting the server
	config.Run()
}
