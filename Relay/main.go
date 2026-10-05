// Muxy's relay: lets a phone reach Muxy on a Mac from any network. It only
// forwards frames that are end-to-end encrypted between the two (see
// Sources/muxy/Remote/RemoteCrypto.swift) — it can neither read nor forge
// them, and it stores nothing.
//
//	GET /relay/mac            Authorization: Bearer <mac token, 64 hex>
//	GET /relay/phone/<room>   room = first 32 hex of SHA-256("muxy-room" + token)
//
// The Mac holds one connection per room and multiplexes phones over it:
//
//	relay → mac   0x01 ch       a phone connected on channel ch
//	              0x02 ch       that phone is gone
//	              0x03 ch data  a frame from it
//	mac → relay   0x02 ch       hang up on that phone
//	              0x03 ch data  a frame for it
//
// ch is a big-endian uint32. Phones see only their own raw frames.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	maxFrame      = 1 << 20 // one encrypted message
	maxPhones     = 8       // per room
	maxRooms      = 64      // per relay — it's meant for a handful of Macs
	pingEvery     = 25 * time.Second
	writeTimeout  = 10 * time.Second
	phoneRate     = 100 // frames per second a phone may send
	opPhoneOpen   = 0x01
	opPhoneClosed = 0x02
	opData        = 0x03
)

var roomPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

func roomFor(token []byte) string {
	sum := sha256.Sum256(append([]byte("muxy-room"), token...))
	return hex.EncodeToString(sum[:16])
}

type room struct {
	mac    *websocket.Conn
	macMu  sync.Mutex // serializes writes to mac
	phones map[uint32]*websocket.Conn
	next   uint32
}

type relay struct {
	mu    sync.Mutex
	rooms map[string]*room
	// Rooms whose Mac may register (MUXY_RELAY_ROOMS, comma-separated).
	// Empty: any Mac — fine on a relay you don't expose to strangers.
	allowed map[string]bool
}

func (r *relay) sendMac(rm *room, frame []byte) error {
	rm.macMu.Lock()
	defer rm.macMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
	defer cancel()
	return rm.mac.Write(ctx, websocket.MessageBinary, frame)
}

func header(op byte, ch uint32) []byte {
	b := make([]byte, 5)
	b[0] = op
	binary.BigEndian.PutUint32(b[1:], ch)
	return b
}

func keepAlive(ctx context.Context, c *websocket.Conn) {
	t := time.NewTicker(pingEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.Ping(pctx)
			cancel()
			if err != nil {
				c.CloseNow()
				return
			}
		}
	}
}

func (r *relay) handleMac(w http.ResponseWriter, req *http.Request) {
	auth := req.Header.Get("Authorization")
	token, err := hex.DecodeString(strings.TrimPrefix(auth, "Bearer "))
	if !strings.HasPrefix(auth, "Bearer ") || err != nil || len(token) != 32 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	id := roomFor(token)
	if len(r.allowed) > 0 && !r.allowed[id] {
		http.Error(w, "unknown mac", http.StatusForbidden)
		return
	}

	r.mu.Lock()
	if _, exists := r.rooms[id]; !exists && len(r.rooms) >= maxRooms {
		r.mu.Unlock()
		http.Error(w, "full", http.StatusServiceUnavailable)
		return
	}
	r.mu.Unlock()

	c, err := websocket.Accept(w, req, nil)
	if err != nil {
		return
	}
	c.SetReadLimit(maxFrame + 5)
	rm := &room{mac: c, phones: map[uint32]*websocket.Conn{}}

	// The newest Mac connection for a room wins (a reconnect after sleep).
	r.mu.Lock()
	if old := r.rooms[id]; old != nil {
		old.mac.Close(websocket.StatusPolicyViolation, "replaced")
		for _, p := range old.phones {
			p.Close(websocket.StatusGoingAway, "mac reconnected")
		}
	}
	r.rooms[id] = rm
	r.mu.Unlock()
	log.Printf("mac up    room=%s…", id[:6])

	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	go keepAlive(ctx, c)

	for {
		typ, frame, err := c.Read(ctx)
		if err != nil {
			break
		}
		if typ != websocket.MessageBinary || len(frame) < 5 {
			continue
		}
		ch := binary.BigEndian.Uint32(frame[1:5])
		r.mu.Lock()
		phone := rm.phones[ch]
		r.mu.Unlock()
		if phone == nil {
			continue
		}
		switch frame[0] {
		case opData:
			wctx, wcancel := context.WithTimeout(ctx, writeTimeout)
			if phone.Write(wctx, websocket.MessageBinary, frame[5:]) != nil {
				phone.CloseNow()
			}
			wcancel()
		case opPhoneClosed:
			phone.Close(websocket.StatusNormalClosure, "")
		}
	}

	r.mu.Lock()
	if r.rooms[id] == rm {
		delete(r.rooms, id)
	}
	phones := rm.phones
	r.mu.Unlock()
	for _, p := range phones {
		p.Close(websocket.StatusGoingAway, "mac offline")
	}
	c.CloseNow()
	log.Printf("mac down  room=%s…", id[:6])
}

func (r *relay) handlePhone(w http.ResponseWriter, req *http.Request) {
	id := strings.TrimPrefix(req.URL.Path, "/relay/phone/")
	if !roomPattern.MatchString(id) {
		http.NotFound(w, req)
		return
	}
	// Only pages served from this host may connect (the default check).
	c, err := websocket.Accept(w, req, nil)
	if err != nil {
		return
	}
	c.SetReadLimit(maxFrame)

	r.mu.Lock()
	rm := r.rooms[id]
	if rm == nil || len(rm.phones) >= maxPhones {
		r.mu.Unlock()
		reason := "mac offline"
		if rm != nil {
			reason = "too many phones"
		}
		c.Close(4404, reason)
		return
	}
	rm.next++
	ch := rm.next
	rm.phones[ch] = c
	r.mu.Unlock()

	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	go keepAlive(ctx, c)

	if r.sendMac(rm, header(opPhoneOpen, ch)) == nil {
		limiter := time.NewTicker(time.Second / phoneRate)
		for {
			typ, frame, err := c.Read(ctx)
			if err != nil || typ != websocket.MessageBinary {
				break
			}
			<-limiter.C
			if r.sendMac(rm, append(header(opData, ch), frame...)) != nil {
				break
			}
		}
		limiter.Stop()
	}

	r.mu.Lock()
	delete(rm.phones, ch)
	stillUp := r.rooms[id] == rm
	r.mu.Unlock()
	if stillUp {
		_ = r.sendMac(rm, header(opPhoneClosed, ch))
	}
	c.CloseNow()
}

func main() {
	addr := flag.String("listen", "127.0.0.1:8787", "address to listen on (behind nginx)")
	flag.Parse()
	r := &relay{rooms: map[string]*room{}, allowed: map[string]bool{}}
	for _, id := range strings.Split(os.Getenv("MUXY_RELAY_ROOMS"), ",") {
		if id = strings.TrimSpace(id); roomPattern.MatchString(id) {
			r.allowed[id] = true
		}
	}
	log.Printf("%d mac(s) allowed", len(r.allowed))
	mux := http.NewServeMux()
	mux.HandleFunc("GET /relay/mac", r.handleMac)
	mux.HandleFunc("GET /relay/phone/", r.handlePhone)
	mux.HandleFunc("GET /relay/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok\n"))
	})
	server := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("muxy relay on %s", *addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
