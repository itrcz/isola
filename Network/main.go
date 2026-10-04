// SOCKS5 gateway with explicit direct routing exceptions; never automatic fallback.
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
	"golang.org/x/net/proxy"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

var gatewayIP = net.IPv4(10, 77, 0, 1).To4()
var guestIP = net.IPv4(10, 77, 0, 2).To4()
var gatewayMAC = net.HardwareAddr{2, 0x49, 0x53, 0, 0, 1}
var guestMAC = net.HardwareAddr{2, 0x49, 0x53, 0, 0, 2}

type Config struct {
	DirectRules []string
	Host        string
	Port        int
	Username    string
	Password    string
	GuestMAC    string
}

func (c Config) validate() error {
	if err := validateRules(c.DirectRules); err != nil {
		return err
	}
	if c.GuestMAC != "" {
		mac, err := net.ParseMAC(c.GuestMAC)
		if err != nil || len(mac) != 6 || mac[0]&3 != 2 {
			return errors.New("guest MAC must be a locally administered unicast Ethernet address")
		}
	}
	// Numeric endpoint means even proxy bootstrap never uses the host DNS resolver.
	if net.ParseIP(c.Host) == nil {
		return errors.New("SOCKS endpoint must be a numeric IPv4 or IPv6 address")
	}
	if c.Port < 1 || c.Port > 65535 {
		return errors.New("invalid SOCKS port")
	}
	if len(c.Username) > 255 || len(c.Password) > 255 {
		return errors.New("SOCKS credentials exceed 255 bytes")
	}
	if (c.Username == "") != (c.Password == "") {
		return errors.New("provide both username and password")
	}
	return nil
}
func (c Config) dial(ctx context.Context, target string) (net.Conn, error) {
	if err := c.validate(); err != nil {
		return nil, err
	}
	var auth *proxy.Auth
	if c.Username != "" {
		auth = &proxy.Auth{User: c.Username, Password: c.Password}
	}
	d, err := proxy.SOCKS5("tcp", net.JoinHostPort(c.Host, strconv.Itoa(c.Port)), auth, &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second})
	if err != nil {
		return nil, err
	}
	return d.(proxy.ContextDialer).DialContext(ctx, "tcp", target)
}
func allowed(ip net.IP) bool {
	ip = ip.To4()
	return ip != nil && ip.To4() != nil && ip.IsGlobalUnicast() && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() && !net.IPv4(100, 64, 0, 0).Equal(ip.Mask(net.CIDRMask(10, 32))) && ip[0] != 0 && ip[0] < 224
}
func destination(address tcpip.Address, port uint16) (string, bool) {
	ip := net.IP(address.AsSlice())
	if port == 53 && ip.Equal(gatewayIP) {
		return "1.1.1.1:53", true
	}
	if !allowed(ip) {
		return "", false
	}
	return net.JoinHostPort(ip.String(), strconv.Itoa(int(port))), true
}

type Gateway struct {
	routes      routeCache
	guestMAC    net.HardwareAddr
	s           *stack.Stack
	link        *channel.Endpoint
	config      Config
	emit        func([]byte)
	ctx         context.Context
	cancel      context.CancelFunc
	slots       chan struct{}
	frames      atomic.Uint64
	oversize    atomic.Uint64
	tcpDials    atomic.Uint64
	tcpFailures atomic.Uint64
	dnsQueries  atomic.Uint64
	dnsFailures atomic.Uint64
	udpBlocked  atomic.Uint64
	sendErrors  atomic.Uint64
}

func newGateway(config Config, emit func([]byte)) (*Gateway, error) {
	if err := config.validate(); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	g := &Gateway{config: config, emit: emit, ctx: ctx, cancel: cancel, slots: make(chan struct{}, 256)}
	g.guestMAC = append(net.HardwareAddr(nil), guestMAC...)
	if config.GuestMAC != "" {
		g.guestMAC, _ = net.ParseMAC(config.GuestMAC)
	}
	g.link = channel.New(1024, 1500, "")
	g.s = stack.New(stack.Options{NetworkProtocols: []stack.NetworkProtocolFactory{ipv4.NewProtocol}, TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol}})
	if e := g.s.CreateNIC(1, g.link); e != nil {
		return nil, errors.New(e.String())
	}
	if e := g.s.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber, AddressWithPrefix: tcpip.AddrFrom4Slice(gatewayIP).WithPrefix()}, stack.AddressProperties{}); e != nil {
		g.close()
		return nil, errors.New(e.String())
	}
	g.s.SetPromiscuousMode(1, true)
	g.s.SetSpoofing(1, true)
	g.s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
	g.s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcp.NewForwarder(g.s, 0, 128, g.forwardTCP).HandlePacket)
	dnsForwarder := udp.NewForwarder(g.s, g.forwardDNS)
	g.s.SetTransportProtocolHandler(udp.ProtocolNumber, func(id stack.TransportEndpointID, pkt *stack.PacketBuffer) bool {
		if id.LocalPort != 53 {
			g.udpBlocked.Add(1)
			// Let the local stack return ICMP port-unreachable, so QUIC can
			// fall back to TCP immediately. This never forwards UDP upstream.
			return false
		}
		return dnsForwarder.HandlePacket(id, pkt)
	})
	go func() {
		for {
			p := g.link.ReadContext(ctx)
			if p == nil {
				return
			}
			b := p.ToView()
			payload := append([]byte(nil), b.AsSlice()...)
			b.Release()
			p.DecRef()
			g.send(&layers.Ethernet{SrcMAC: gatewayMAC, DstMAC: g.guestMAC, EthernetType: layers.EthernetTypeIPv4}, gopacket.Payload(payload))
		}
	}()
	return g, nil
}
func (g *Gateway) close() { g.cancel(); g.s.Close(); g.link.Close() }
func (g *Gateway) acquire() bool {
	select {
	case g.slots <- struct{}{}:
		return true
	default:
		return false
	}
}
func (g *Gateway) forwardTCP(r *tcp.ForwarderRequest) {
	id := r.ID()
	target, ok := destination(id.LocalAddress, id.LocalPort)
	if !ok && g.config.directIP(net.IP(id.LocalAddress.AsSlice())) {
		target = net.JoinHostPort(net.IP(id.LocalAddress.AsSlice()).String(), strconv.Itoa(int(r.ID().LocalPort)))
		ok = true
	}
	if !ok || !g.acquire() {
		r.Complete(true)
		return
	}
	go func() {
		defer func() { <-g.slots }()
		if id.LocalPort == 53 {
			var wq waiter.Queue
			ep, e := r.CreateEndpoint(&wq)
			if e != nil {
				r.Complete(true)
				return
			}
			r.Complete(false)
			in := gonet.NewTCPConn(&wq, ep)
			defer in.Close()
			for {
				in.SetDeadline(time.Now().Add(20 * time.Second))
				var length [2]byte
				if _, err := io.ReadFull(in, length[:]); err != nil {
					return
				}
				q := make([]byte, int(binary.BigEndian.Uint16(length[:])))
				if _, err := io.ReadFull(in, q); err != nil {
					return
				}
				response, err := g.dnsQuery(target, q)
				if err != nil {
					return
				}
				binary.BigEndian.PutUint16(length[:], uint16(len(response)))
				if _, err := io.Copy(in, bytes.NewReader(append(length[:], response...))); err != nil {
					return
				}
			}
		}
		ctx, cancel := context.WithTimeout(g.ctx, 12*time.Second)
		g.tcpDials.Add(1)
		out, err := g.dialTarget(ctx, target)
		cancel()
		if err != nil {
			g.tcpFailures.Add(1)
			r.Complete(true)
			return
		}
		defer out.Close()
		var wq waiter.Queue
		ep, e := r.CreateEndpoint(&wq)
		if e != nil {
			r.Complete(true)
			return
		}
		r.Complete(false)
		in := gonet.NewTCPConn(&wq, ep)
		defer in.Close()
		done := make(chan struct{})
		go func() {
			io.Copy(out, in)
			if c, ok := out.(interface{ CloseWrite() error }); ok {
				c.CloseWrite()
			}
			close(done)
		}()
		io.Copy(in, out)
		in.Close()
		out.Close()
		<-done
	}()
}
func (g *Gateway) forwardDNS(r *udp.ForwarderRequest) {
	// All other UDP (including QUIC, STUN and multicast) is dropped. No direct fallback.
	if r.ID().LocalPort != 53 {
		g.udpBlocked.Add(1)
		return
	}
	id := r.ID()
	target, ok := destination(id.LocalAddress, 53)
	if !ok && g.config.directIP(net.IP(id.LocalAddress.AsSlice())) {
		target = net.JoinHostPort(net.IP(id.LocalAddress.AsSlice()).String(), "53")
		ok = true
	}
	if !ok || !g.acquire() {
		return
	}
	var wq waiter.Queue
	ep, e := r.CreateEndpoint(&wq)
	if e != nil {
		<-g.slots
		return
	}
	in := gonet.NewUDPConn(&wq, ep)
	go func() {
		defer func() { <-g.slots }()
		defer in.Close()
		buf := make([]byte, 4096)
		for {
			in.SetReadDeadline(time.Now().Add(20 * time.Second))
			n, err := in.Read(buf)
			if err != nil {
				return
			}
			g.dnsQueries.Add(1)
			response, err := g.dnsQuery(target, buf[:n])
			if err != nil {
				g.dnsFailures.Add(1)
			}
			if err == nil {
				in.Write(response)
			}
		}
	}()
}
func (g *Gateway) dnsQuery(target string, q []byte) ([]byte, error) {
	if len(q) < 12 {
		return nil, errors.New("short DNS query")
	}
	ctx, cancel := context.WithTimeout(g.ctx, 10*time.Second)
	defer cancel()
	c, err := g.dialTarget(ctx, target)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	packet := make([]byte, len(q)+2)
	binary.BigEndian.PutUint16(packet, uint16(len(q)))
	copy(packet[2:], q)
	if _, err = io.Copy(c, bytes.NewReader(packet)); err != nil {
		return nil, err
	}
	var size [2]byte
	if _, err = io.ReadFull(c, size[:]); err != nil {
		return nil, err
	}
	n := int(binary.BigEndian.Uint16(size[:]))
	if n < 12 {
		return nil, errors.New("short DNS response")
	}
	response := make([]byte, n)
	_, err = io.ReadFull(c, response)
	if err == nil {
		g.rememberDNS(q, response)
	}
	return response, err
}

func (g *Gateway) send(ls ...gopacket.SerializableLayer) {
	b := gopacket.NewSerializeBuffer()
	if gopacket.SerializeLayers(b, gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}, ls...) == nil {
		g.emit(b.Bytes())
	}
}
func (g *Gateway) frame(frame []byte) {
	g.frames.Add(1)
	if len(frame) > 1600 {
		g.oversize.Add(1)
		return
	}
	p := gopacket.NewPacket(frame, layers.LayerTypeEthernet, gopacket.Default)
	ethL := p.Layer(layers.LayerTypeEthernet)
	if ethL == nil {
		return
	}
	eth := ethL.(*layers.Ethernet)
	if string(eth.SrcMAC) != string(g.guestMAC) {
		return
	}
	if a := p.Layer(layers.LayerTypeARP); a != nil {
		arp := a.(*layers.ARP)
		if arp.Operation == 1 && net.IP(arp.DstProtAddress).Equal(gatewayIP) {
			g.send(&layers.Ethernet{SrcMAC: gatewayMAC, DstMAC: g.guestMAC, EthernetType: layers.EthernetTypeARP}, &layers.ARP{AddrType: layers.LinkTypeEthernet, Protocol: layers.EthernetTypeIPv4, HwAddressSize: 6, ProtAddressSize: 4, Operation: 2, SourceHwAddress: gatewayMAC, SourceProtAddress: gatewayIP, DstHwAddress: g.guestMAC, DstProtAddress: arp.SourceProtAddress})
		}
		return
	}
	ipL := p.Layer(layers.LayerTypeIPv4)
	if ipL == nil {
		return
	}
	ip := ipL.(*layers.IPv4)
	if d := p.Layer(layers.LayerTypeDHCPv4); d != nil {
		u := p.Layer(layers.LayerTypeUDP)
		if u != nil && u.(*layers.UDP).SrcPort == 68 && u.(*layers.UDP).DstPort == 67 {
			g.dhcp(d.(*layers.DHCPv4))
		}
		return
	}
	if !ip.SrcIP.Equal(guestIP) {
		return
	}
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(eth.Payload)})
	g.link.InjectInbound(ipv4.ProtocolNumber, pkt)
	pkt.DecRef()
}
func (g *Gateway) dhcp(d *layers.DHCPv4) {
	if d.Operation != layers.DHCPOpRequest || string(d.ClientHWAddr) != string(g.guestMAC) {
		return
	}
	var kind byte
	for _, o := range d.Options {
		if o.Type == layers.DHCPOptMessageType && len(o.Data) == 1 {
			kind = o.Data[0]
		}
		if o.Type == layers.DHCPOptServerID && !net.IP(o.Data).Equal(gatewayIP) {
			return
		}
	}
	var reply byte
	switch kind {
	case 1:
		reply = 2
	case 3:
		reply = 5
	default:
		return
	}
	lease := make([]byte, 4)
	binary.BigEndian.PutUint32(lease, 86400)
	answer := &layers.DHCPv4{Operation: layers.DHCPOpReply, HardwareType: layers.LinkTypeEthernet, HardwareLen: 6, Xid: d.Xid, Flags: d.Flags, YourClientIP: guestIP, NextServerIP: gatewayIP, ClientHWAddr: g.guestMAC, Options: layers.DHCPOptions{
		layers.NewDHCPOption(layers.DHCPOptMessageType, []byte{reply}), layers.NewDHCPOption(layers.DHCPOptServerID, gatewayIP), layers.NewDHCPOption(layers.DHCPOptLeaseTime, lease), layers.NewDHCPOption(layers.DHCPOptSubnetMask, []byte{255, 255, 255, 0}), layers.NewDHCPOption(layers.DHCPOptRouter, gatewayIP), layers.NewDHCPOption(layers.DHCPOptDNS, gatewayIP)}}
	ip := &layers.IPv4{Version: 4, IHL: 5, TTL: 64, Protocol: layers.IPProtocolUDP, SrcIP: gatewayIP, DstIP: net.IPv4bcast}
	u := &layers.UDP{SrcPort: 67, DstPort: 68}
	u.SetNetworkLayerForChecksum(ip)
	g.send(&layers.Ethernet{SrcMAC: gatewayMAC, DstMAC: net.HardwareAddr{255, 255, 255, 255, 255, 255}, EthernetType: layers.EthernetTypeIPv4}, ip, u, answer)
}
func main() {
	socket := flag.String("socket", "", "private UNIX datagram socket path")
	peer := flag.String("peer", "", "VM socket path")
	statsPath := flag.String("stats", "", "aggregate network health counters; no addresses or credentials")
	check := flag.Bool("check", false, "verify SOCKS connection")
	flag.Parse()
	var c Config
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 128*1024)).Decode(&c); err != nil {
		fatal("invalid proxy configuration")
	}
	if err := c.validate(); err != nil {
		fatal(err.Error())
	}
	if *check {
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		conn, err := c.dial(ctx, "1.1.1.1:443")
		if err != nil {
			fatal("SOCKS connection failed; verify endpoint and credentials")
		}
		conn.Close()
		fmt.Println("SOCKS CONNECT OK")
		return
	}
	// Parent holds stdin open for our lifetime. Exit on parent crash as well as normal shutdown.
	go func() { io.Copy(io.Discard, os.Stdin); os.Exit(0) }()
	if *socket == "" || *peer == "" {
		fatal("missing private socket paths")
	}
	conn, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: *socket, Net: "unixgram"})
	if err != nil {
		fatal("cannot create network socket")
	}
	defer conn.Close()
	defer os.Remove(*socket)
	os.Chmod(*socket, 0600)
	remote := &net.UnixAddr{Name: *peer, Net: "unixgram"}
	if conn.SetReadBuffer(1024*1024) != nil || conn.SetWriteBuffer(256*1024) != nil {
		fatal("cannot configure network socket buffers")
	}
	// Never write synchronously from the receive loop: both datagram sockets
	// can fill simultaneously and deadlock ARP/DHCP against guest TX.
	output := make(chan []byte, 1024)
	var dropped atomic.Uint64
	g, err := newGateway(c, func(b []byte) {
		packet := append([]byte(nil), b...)
		select {
		case output <- packet:
		default:
			dropped.Add(1)
		}
	})
	if err != nil {
		fatal("cannot initialize gateway")
	}
	defer g.close()
	go func() {
		for {
			select {
			case <-g.ctx.Done():
				return
			case packet := <-output:
				conn.SetWriteDeadline(time.Now().Add(250 * time.Millisecond))
				if _, err := conn.WriteToUnix(packet, remote); err != nil {
					g.sendErrors.Add(1)
				}
			}
		}
	}()
	if *statsPath != "" {
		go func() {
			t := time.NewTicker(time.Second)
			defer t.Stop()
			for {
				select {
				case <-g.ctx.Done():
					return
				case <-t.C:
					metrics := g.metrics()
					metrics["send_queue_dropped"] = dropped.Load()
					data, _ := json.Marshal(metrics)
					temp := *statsPath + ".tmp"
					if os.WriteFile(temp, data, 0600) == nil {
						os.Rename(temp, *statsPath)
					}
				}
			}
		}()
	}
	fmt.Println("READY")
	buf := make([]byte, 65536)
	for {
		n, from, err := conn.ReadFromUnix(buf)
		if err != nil {
			return
		}
		if from.Name == *peer {
			g.frame(buf[:n])
		}
	}
}
func fatal(message string) { fmt.Fprintln(os.Stderr, message); os.Exit(1) }

func (g *Gateway) metrics() map[string]uint64 {
	s := g.s.Stats()
	return map[string]uint64{"send_errors": g.sendErrors.Load(), "frames": g.frames.Load(), "oversize": g.oversize.Load(), "tcp_dials": g.tcpDials.Load(), "tcp_failures": g.tcpFailures.Load(), "dns_queries": g.dnsQueries.Load(), "dns_failures": g.dnsFailures.Load(), "udp_blocked": g.udpBlocked.Load(), "tcp_checksum_errors": s.TCP.ChecksumErrors.Value(), "udp_checksum_errors": s.UDP.ChecksumErrors.Value(), "ip_malformed": s.IP.MalformedPacketsReceived.Value(), "tcp_retransmits": s.TCP.Retransmits.Value(), "tcp_invalid": s.TCP.InvalidSegmentsReceived.Value(), "tcp_connected": s.TCP.CurrentConnected.Value(), "udp_buffer_errors": s.UDP.ReceiveBufferErrors.Value()}
}
