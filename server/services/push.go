package services

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/commandlinecoding/elephant/server/env"
	"github.com/commandlinecoding/elephant/server/repository"
)

// Push sends UnifiedPush pings to users who have new messages but no live
// WebSocket. A ping never contains message content: it only tells the app to
// connect and fetch, so the push server (ntfy or similar) learns nothing about
// the conversation beyond the fact that something arrived.
var Push = NewPushService(strings.EqualFold(env.PUSH_ALLOW_PRIVATE_ENDPOINTS, "true"))

const (
	// MaxPushEndpointsPerUser caps stored endpoints; the oldest are dropped.
	MaxPushEndpointsPerUser = 5
	maxPushEndpointLength   = 2048

	pushPayload = `{"type":"new_messages"}`
)

var (
	errBlockedAddress = errors.New("push endpoint resolves to a blocked address")

	// cgnat is the shared address space (100.64.0.0/10), used by carriers and
	// Tailscale. Treated as private.
	cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}
)

// ErrInvalidPushEndpoint is wrapped by every endpoint validation failure.
var ErrInvalidPushEndpoint = errors.New("invalid push endpoint")

type PushService struct {
	repo         *repository.PushRepository
	client       *http.Client
	allowPrivate bool

	// settle is how long to wait after a message before pinging, so the message
	// is stored by the time the app fetches. minInterval spaces pings to one user.
	settle      time.Duration
	minInterval time.Duration

	queue chan string

	mu    sync.Mutex
	state map[string]*pushState
}

type pushState struct {
	last  time.Time
	timer *time.Timer
}

func NewPushService(allowPrivate bool) *PushService {
	return &PushService{
		repo:         repository.NewPushRepository(),
		client:       newPushClient(allowPrivate),
		allowPrivate: allowPrivate,
		settle:       time.Second,
		minInterval:  5 * time.Second,
		queue:        make(chan string, 1024),
		state:        make(map[string]*pushState),
	}
}

// Start launches the workers that send pings. Call it once at startup.
func (p *PushService) Start(workers int) {
	for i := 0; i < workers; i++ {
		go func() {
			for userID := range p.queue {
				p.deliver(userID)
			}
		}()
	}
}

// NotifyUsers asks for a ping to each user. It never blocks, so it is safe to
// call from the message path. Pings to one user are spaced out and coalesced:
// a message that arrives while a ping is already scheduled is covered by it,
// and one that arrives later schedules the next.
func (p *PushService) NotifyUsers(userIDs []string) {
	for _, id := range userIDs {
		p.notify(id)
	}
}

func (p *PushService) notify(userID string) {
	p.mu.Lock()
	defer p.mu.Unlock()

	st := p.state[userID]
	if st == nil {
		p.pruneLocked()
		st = &pushState{}
		p.state[userID] = st
	}
	if st.timer != nil {
		return
	}

	wait := p.settle
	if spaced := time.Until(st.last.Add(p.minInterval)); spaced > wait {
		wait = spaced
	}
	st.timer = time.AfterFunc(wait, func() {
		p.mu.Lock()
		st.timer = nil
		st.last = time.Now()
		p.mu.Unlock()

		select {
		case p.queue <- userID:
		default:
			log.Println("push: queue full, dropping a ping")
		}
	})
}

// pruneLocked forgets users that haven't been pinged for a while, so the map
// can't grow without bound. The caller holds p.mu.
func (p *PushService) pruneLocked() {
	if len(p.state) < 4096 {
		return
	}
	for id, st := range p.state {
		if st.timer == nil && time.Since(st.last) > p.minInterval {
			delete(p.state, id)
		}
	}
}

// deliver pings every endpoint stored for the user.
func (p *PushService) deliver(userID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	targets, err := p.repo.ListByUser(ctx, userID)
	if err != nil {
		log.Printf("push: could not load endpoints: %v", err)
		return
	}
	for _, t := range targets {
		gone, err := p.send(ctx, t.Endpoint)
		if gone {
			// The distributor says this endpoint no longer exists (app
			// uninstalled or unregistered). Stop pinging it.
			if err := p.repo.DeleteByID(ctx, t.ID); err != nil {
				log.Printf("push: could not remove a dead endpoint: %v", err)
			}
			continue
		}
		if err != nil {
			// Log the host only: the full URL is a secret.
			log.Printf("push: ping to %s failed: %v", hostOf(t.Endpoint), err)
		}
	}
}

// send POSTs the ping. gone is true when the endpoint answered 404 or 410.
func (p *PushService) send(ctx context.Context, endpoint string) (gone bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader([]byte(pushPayload)))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("TTL", "3600")

	resp, err := p.client.Do(req)
	if err != nil {
		return false, scrubURLError(err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return false, nil
	case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
		return true, nil
	default:
		return false, fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
}

// ValidateEndpoint checks an endpoint a client wants to register. Connect-time
// checks in the HTTP client are what actually enforce the address rules, since
// a hostname can resolve to anything later; this gives early, clear errors.
func (p *PushService) ValidateEndpoint(raw string) error {
	return validatePushEndpoint(raw, p.allowPrivate)
}

func validatePushEndpoint(raw string, allowPrivate bool) error {
	bad := func(msg string) error { return fmt.Errorf("%w: %s", ErrInvalidPushEndpoint, msg) }

	raw = strings.TrimSpace(raw)
	if raw == "" {
		return bad("endpoint is required")
	}
	if len(raw) > maxPushEndpointLength {
		return bad("endpoint is too long")
	}

	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return bad("not a valid URL")
	}
	if u.User != nil {
		return bad("credentials in the URL are not allowed")
	}
	switch u.Scheme {
	case "https":
	case "http":
		if !allowPrivate {
			return bad("endpoint must use https")
		}
	default:
		return bad("endpoint must use https")
	}

	host := u.Hostname()
	if strings.EqualFold(host, "localhost") && !allowPrivate {
		return bad("endpoint must not point at this server's own network")
	}
	if ip := net.ParseIP(host); ip != nil && blockedIP(ip, allowPrivate) {
		return bad("endpoint must not point at a private or reserved address")
	}
	return nil
}

// blockedIP reports whether the server must not connect to ip. Link-local
// (including the cloud metadata address 169.254.169.254), unspecified and
// multicast addresses are always blocked. Loopback, private and shared (CGNAT)
// ranges are blocked unless the operator allows private endpoints.
func blockedIP(ip net.IP, allowPrivate bool) bool {
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	if ip.IsUnspecified() || ip.IsMulticast() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
		return true
	}
	if allowPrivate {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate() || cgnat.Contains(ip)
}

// newPushClient builds an HTTP client for calling user-supplied URLs: it
// checks the address it is really connecting to (so DNS can't smuggle in a
// private one), ignores proxy settings, never follows redirects, and times out.
func newPushClient(allowPrivate bool) *http.Client {
	dialer := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(_, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			ip := net.ParseIP(host)
			if ip == nil || blockedIP(ip, allowPrivate) {
				return errBlockedAddress
			}
			return nil
		},
	}
	return &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			Proxy:                 nil,
			DialContext:           dialer.DialContext,
			TLSHandshakeTimeout:   5 * time.Second,
			ResponseHeaderTimeout: 5 * time.Second,
			MaxIdleConns:          20,
			IdleConnTimeout:       30 * time.Second,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func hostOf(endpoint string) string {
	if u, err := url.Parse(endpoint); err == nil && u.Host != "" {
		return u.Host
	}
	return "unknown host"
}

// scrubURLError removes the request URL from net/http errors, because the
// endpoint path is a secret and must not end up in logs.
func scrubURLError(err error) error {
	var ue *url.Error
	if errors.As(err, &ue) {
		return ue.Err
	}
	return err
}
