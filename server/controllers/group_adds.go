package controllers

import (
	"context"
	"log"
	"net/http"
	"strings"

	"github.com/commandlinecoding/elephant/server/middlewares"
	"github.com/commandlinecoding/elephant/server/repository"
)

const (
	errAddNobody      = "This person doesn't allow being added to groups."
	errAddContacts    = "This person only allows people they chat with to add them to groups."
	errAddCheckFailed = "Couldn't check whether this person can be added."
)

func requesterID(r *http.Request) string {
	uid, _ := r.Context().Value(middlewares.UserIDKey).(string)
	return uid
}

// whoMayAdd checks target's "who can add me to groups" setting for adder. It
// returns "" if adder may add them, or the message to show. Settings that
// can't be loaded mean no, since the setting is a promise.
func whoMayAdd(ctx context.Context, adder, target string) string {
	if strings.EqualFold(adder, target) {
		return ""
	}
	settings, err := repository.NewUserSettingsRepository().Get(ctx, target)
	if err != nil {
		log.Printf("group add: couldn't load settings: %v", err)
		return errAddCheckFailed
	}
	switch settings.GroupAdds {
	case repository.AudienceNobody:
		return errAddNobody
	case repository.AudienceContacts:
		ids, err := repository.NewContactRepository().GetContactIDs(ctx, target)
		if err != nil {
			log.Printf("group add: couldn't load contacts: %v", err)
			return errAddCheckFailed
		}
		for _, id := range ids {
			if strings.EqualFold(id, adder) {
				return ""
			}
		}
		return errAddContacts
	}
	return ""
}
