package main

import (
	"encoding/binary"
	"net"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// The host clock is the VM's local reference clock. NTP never opens an upstream
// socket, including when SOCKS is unavailable. Only ordinary unauthenticated
// client requests are supported; control, symmetric and extension packets drop.
func timeReply(request []byte, received, sent time.Time) []byte {
	if len(request) != 48 || request[0]&7 != 3 {
		return nil
	}
	version := (request[0] >> 3) & 7
	if version != 3 && version != 4 {
		return nil
	}
	reply := make([]byte, 48)
	reply[0] = version<<3 | 4
	reply[1] = 1 // virtual local reference clock, not an Internet source
	reply[2] = request[2]
	reply[3] = 0xec                                // -20: nominal microsecond clock precision
	binary.BigEndian.PutUint32(reply[8:12], 1<<10) // 1/64 second dispersion
	copy(reply[12:16], "LOCL")
	putNTPTime(reply[16:24], received)
	copy(reply[24:32], request[40:48])
	putNTPTime(reply[32:40], received)
	putNTPTime(reply[40:48], sent)
	return reply
}

func putNTPTime(dst []byte, t time.Time) {
	// The 32-bit seconds field intentionally wraps at the NTP era boundary.
	binary.BigEndian.PutUint32(dst[:4], uint32(t.Unix()+2208988800))
	binary.BigEndian.PutUint32(dst[4:8], uint32((uint64(t.Nanosecond())<<32)/1_000_000_000))
}

func (g *Gateway) serveTime(r *udp.ForwarderRequest) {
	id := r.ID()
	ip := net.IP(id.LocalAddress.AsSlice())
	if !ip.Equal(gatewayIP) && !allowed(ip) {
		return
	}
	select {
	case g.timeSlots <- struct{}{}:
	default:
		return
	}
	var wq waiter.Queue
	ep, err := r.CreateEndpoint(&wq)
	if err != nil {
		<-g.timeSlots
		return
	}
	conn := gonet.NewUDPConn(&wq, ep)
	go func() {
		defer func() { conn.Close(); <-g.timeSlots }()
		// Short, bounded exchanges cannot occupy all TCP/DNS forwarding slots.
		conn.SetDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 512)
		for i := 0; i < 8; i++ {
			n, err := conn.Read(buf)
			if err != nil {
				return
			}
			received := time.Now()
			if reply := timeReply(buf[:n], received, time.Now()); reply != nil {
				if _, err = conn.Write(reply); err != nil {
					return
				}
				g.timeReplies.Add(1)
			}
		}
	}()
}
