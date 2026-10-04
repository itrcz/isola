package main

import (
	"context"
	"golang.org/x/net/dns/dnsmessage"
	"net"
	"testing"
	"time"
)

func TestRoutingRules(t *testing.T) {
	c := Config{DirectRules: []string{"*company.com", "exact.test", "10.0.0.0/8", "203.0.113.5"}}
	if err := validateRules(c.DirectRules); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"company.com", "a.company.com.", "A.COMPANY.COM"} {
		if !c.directName(name) {
			t.Fatal(name)
		}
	}
	for _, name := range []string{"evilcompany.com", "company.com.evil", "a.exact.test"} {
		if c.directName(name) {
			t.Fatal(name)
		}
	}
	if !c.directIP(net.ParseIP("10.2.3.4")) || c.directIP(net.ParseIP("11.2.3.4")) {
		t.Fatal("CIDR")
	}
	for _, rule := range []string{"*", "a/b", "foo bar", "foo.*.com", "-company.com", "company..com"} {
		if validateRules([]string{rule}) == nil {
			t.Fatal(rule)
		}
	}
}
func TestExplicitDirectDialAndNoFallback(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	g := &Gateway{config: Config{Host: "127.0.0.1", Port: 1, DirectRules: []string{"127.0.0.1"}}}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := g.dialTarget(ctx, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	g.config.DirectRules = nil
	if conn, err := g.dialTarget(ctx, listener.Addr().String()); err == nil {
		conn.Close()
		t.Fatal("proxy failure fell back directly")
	}
}
func TestDNSRouteLifetimeAndValidation(t *testing.T) {
	name := dnsmessage.MustNewName("a.company.com.")
	q := dnsmessage.Message{Header: dnsmessage.Header{ID: 42}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	query, _ := q.Pack()
	r := q
	r.Response = true
	r.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, Body: &dnsmessage.AResource{A: [4]byte{8, 8, 8, 8}}}}
	response, _ := r.Pack()
	g := &Gateway{config: Config{DirectRules: []string{"*company.com"}}}
	g.rememberDNS(query, response)
	if !g.useDirect("8.8.8.8:443") || g.useDirect("9.9.9.9:443") {
		t.Fatal("DNS routing")
	}
	g.routes.addresses["8.8.8.8"] = time.Now().Add(-time.Second)
	if g.useDirect("8.8.8.8:443") {
		t.Fatal("expired DNS rule")
	}
	r.ID++
	response, _ = r.Pack()
	g.rememberDNS(query, response)
	if g.useDirect("8.8.8.8:443") {
		t.Fatal("accepted mismatched DNS response")
	}
}
