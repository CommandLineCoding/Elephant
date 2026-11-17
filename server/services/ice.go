package services

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
)

// ICEServer is one STUN or TURN server for a call, in the shape WebRTC's
// RTCIceServer takes.
type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// ICECredentialTTL is how long TURN credentials last. Cloudflare drops a relay
// whose credential has expired, so this must outlast the longest call.
const ICECredentialTTL = 24 * time.Hour

// cloudflareTURNURL is where Cloudflare TURN credentials come from. A variable
// so tests can point it at a fake.
var cloudflareTURNURL = "https://rtc.live.cloudflare.com/v1/turn/keys/%s/credentials/generate-ice-servers"

var iceHTTP = &http.Client{Timeout: 5 * time.Second}

// iceNow tells the coturn credentials the time. Tests replace it.
var iceNow = time.Now

// ICEServers returns the STUN and TURN servers a call should use, with TURN
// credentials for userID that last ICECredentialTTL.
//
// STUN_URLS lists STUN servers (default Cloudflare's free one; set it empty
// for none). TURN comes from Cloudflare (CLOUDFLARE_TURN_KEY_ID and
// CLOUDFLARE_TURN_API_TOKEN) or from your own coturn (TURN_URLS and
// TURN_SECRET). If Cloudflare can't be reached, the call gets STUN only
// rather than failing.
func ICEServers(ctx context.Context, userID string) []ICEServer {
	servers := []ICEServer{}
	if stun := splitList(env.STUN_URLS); len(stun) > 0 {
		servers = append(servers, ICEServer{URLs: stun})
	}

	switch {
	case env.CLOUDFLARE_TURN_KEY_ID != "" && env.CLOUDFLARE_TURN_API_TOKEN != "":
		cf, err := cloudflareICEServers(ctx)
		if err != nil {
			log.Printf("Couldn't get TURN credentials from Cloudflare, calls get STUN only: %v", err)
			break
		}
		servers = mergeICEServers(servers, cf)

	case env.TURN_SECRET != "" && env.TURN_URLS != "":
		if urls := splitList(env.TURN_URLS); len(urls) > 0 {
			username, credential := coturnCredentials(env.TURN_SECRET, userID, iceNow().Add(ICECredentialTTL))
			servers = append(servers, ICEServer{URLs: urls, Username: username, Credential: credential})
		}
	}
	return servers
}

// coturnCredentials makes time-limited credentials for coturn's
// use-auth-secret mode (the "TURN REST API" scheme): the username is the
// expiry time and user, and the password is an HMAC of it with the shared
// secret, so coturn can check it without a database.
func coturnCredentials(secret, userID string, expires time.Time) (username, credential string) {
	username = fmt.Sprintf("%d:%s", expires.Unix(), userID)
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(username))
	return username, base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func cloudflareICEServers(ctx context.Context) ([]ICEServer, error) {
	body, _ := json.Marshal(map[string]int{"ttl": int(ICECredentialTTL.Seconds())})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf(cloudflareTURNURL, env.CLOUDFLARE_TURN_KEY_ID), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+env.CLOUDFLARE_TURN_API_TOKEN)
	req.Header.Set("Content-Type", "application/json")

	resp, err := iceHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return nil, fmt.Errorf("cloudflare answered %s", resp.Status)
	}

	var out struct {
		ICEServers []ICEServer `json:"iceServers"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&out); err != nil {
		return nil, err
	}
	return out.ICEServers, nil
}

// mergeICEServers adds extra to servers, leaving out URLs already listed and
// port 53, which Cloudflare offers as an alternative but many networks and
// WebRTC stacks block, so trying it only slows a call down.
func mergeICEServers(servers, extra []ICEServer) []ICEServer {
	seen := map[string]bool{}
	for _, s := range servers {
		for _, u := range s.URLs {
			seen[u] = true
		}
	}
	for _, s := range extra {
		urls := []string{}
		for _, u := range s.URLs {
			if seen[u] || strings.Contains(u, ":53?") || strings.HasSuffix(u, ":53") {
				continue
			}
			seen[u] = true
			urls = append(urls, u)
		}
		if len(urls) > 0 {
			s.URLs = urls
			servers = append(servers, s)
		}
	}
	return servers
}

func splitList(s string) []string {
	out := []string{}
	for _, part := range strings.Split(s, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}
