package main

import (
	"context"
	"log"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/migrations"
	"github.com/commandlinecoding/elephant/server/routes"
	"github.com/commandlinecoding/elephant/server/services"
)

func main() {
	// db init
	config.InitDatabase()
	defer config.DB.Close()

	// Bring the schema up to date before serving, so a deploy can't go live
	// with a column the code expects missing. Set AUTO_MIGRATE=false to manage
	// migrations yourself (e.g. when the database user can't change the schema).
	if strings.EqualFold(env.AUTO_MIGRATE, "false") {
		log.Println("Migrations: AUTO_MIGRATE=false, skipping")
	} else {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		if err := config.Migrate(ctx, config.DB, migrations.FS); err != nil {
			log.Fatalf("Database migration failed: %v", err)
		}
		cancel()
	}

	// OAuth init
	config.InitOAuth()

	// A mistyped REGISTRATION would silently leave sign-ups open, so refuse to start.
	if r := strings.ToLower(strings.TrimSpace(env.REGISTRATION)); r != "open" && r != "closed" {
		log.Fatalf("REGISTRATION must be \"open\" or \"closed\", got %q", env.REGISTRATION)
	}

	// WS init
	go services.Hub.Run()

	// UnifiedPush pings for users with no live connection
	services.Push.Start(4)

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
