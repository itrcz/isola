package main

import (
	"context"
	"errors"
	"net"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// Only explicit IP/CIDR rules allow private destinations. DNS rules never grant LAN access.
func (c Config) directIP(ip net.IP) bool {
	for _, rule := range c.DirectRules {
		if parsed := net.ParseIP(rule); parsed != nil && parsed.Equal(ip) {
			return true
		}
		if _, subnet, err := net.ParseCIDR(rule); err == nil && subnet.Contains(ip) {
			return true
		}
	}
	return false
}
func (c Config) directName(name string) bool {
	name = strings.ToLower(strings.TrimSuffix(name, "."))
	for _, rule := range c.DirectRules {
		if net.ParseIP(rule) != nil || strings.Contains(rule, "/") {
			continue
		}
		rule = strings.ToLower(strings.TrimSuffix(rule, "."))
		if strings.HasPrefix(rule, "*") {
			suffix := strings.TrimPrefix(strings.TrimPrefix(rule, "*"), ".")
			if name == suffix || strings.HasSuffix(name, "."+suffix) {
				return true
			}
		} else if name == rule {
			return true
		}
	}
	return false
}
func validateRules(rules []string) error {
	if len(rules) > 256 {
		return errors.New("at most 256 direct rules")
	}
	for _, rule := range rules {
		if net.ParseIP(rule) != nil {
			continue
		}
		if _, _, err := net.ParseCIDR(rule); err == nil {
			continue
		}
		if strings.HasPrefix(rule, ".") {
			return errors.New("use *domain.com for suffix rules")
		}
		name := strings.TrimSuffix(strings.TrimPrefix(strings.TrimPrefix(rule, "*"), "."), ".")
		if len(name) == 0 || len(name) > 253 {
			return errors.New("invalid direct rule")
		}
		for _, label := range strings.Split(name, ".") {
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
				return errors.New("invalid domain rule")
			}
			for _, ch := range label {
				if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') {
					return errors.New("invalid domain rule; use IP, CIDR or *company.com")
				}
			}
		}
	}
	return nil
}

type routeCache struct {
	mu        sync.Mutex
	addresses map[string]time.Time
}

func (g *Gateway) useDirect(target string) bool {
	host, _, _ := net.SplitHostPort(target)
	if g.config.directIP(net.ParseIP(host)) {
		return true
	}
	g.routes.mu.Lock()
	defer g.routes.mu.Unlock()
	return time.Now().Before(g.routes.addresses[host])
}
func (g *Gateway) dialTarget(ctx context.Context, target string) (net.Conn, error) {
	if g.useDirect(target) {
		return (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext(ctx, "tcp", target)
	}
	return g.config.dial(ctx, target)
}
func (g *Gateway) rememberDNS(query, response []byte) {
	var q, r dnsmessage.Message
	if q.Unpack(query) != nil || r.Unpack(response) != nil || len(q.Questions) != 1 || !r.Response || r.ID != q.ID || r.RCode != dnsmessage.RCodeSuccess || len(r.Questions) != 1 || r.Questions[0] != q.Questions[0] || !g.config.directName(q.Questions[0].Name.String()) {
		return
	}
	// Only accept A records belonging to the queried name or its CNAME chain.
	names := map[string]bool{strings.ToLower(q.Questions[0].Name.String()): true}
	ttl := uint32(3600)
	for i := 0; i < len(r.Answers); i++ {
		for _, answer := range r.Answers {
			if cname, ok := answer.Body.(*dnsmessage.CNAMEResource); ok && names[strings.ToLower(answer.Header.Name.String())] {
				names[strings.ToLower(cname.CNAME.String())] = true
				if answer.Header.TTL < ttl {
					ttl = answer.Header.TTL
				}
			}
		}
	}
	g.routes.mu.Lock()
	defer g.routes.mu.Unlock()
	if g.routes.addresses == nil {
		g.routes.addresses = map[string]time.Time{}
	}
	now := time.Now()
	for ip, expiry := range g.routes.addresses {
		if !now.Before(expiry) {
			delete(g.routes.addresses, ip)
		}
	}
	for _, answer := range r.Answers {
		a, ok := answer.Body.(*dnsmessage.AResource)
		if !ok || !names[strings.ToLower(answer.Header.Name.String())] || !allowed(net.IP(a.A[:])) {
			continue
		}
		lifetime := min(ttl, answer.Header.TTL)
		if lifetime == 0 || len(g.routes.addresses) >= 8192 {
			continue
		}
		g.routes.addresses[net.IP(a.A[:]).String()] = now.Add(time.Duration(lifetime) * time.Second)
	}
}
