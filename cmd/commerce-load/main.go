// 仅用于隔离数据库的可重复在线压测；不会读取项目.env或连接生产。
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/coder/websocket"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/platform/database"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}

type client struct {
	conn          *websocket.Conn
	token, base   string
	events        atomic.Int64
	expectedClose atomic.Bool
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	dsn := os.Getenv("LOAD_DATABASE_URL")
	if dsn == "" {
		panic("LOAD_DATABASE_URL is required")
	}
	db, err := pgxpool.New(ctx, dsn)
	must(err)
	defer db.Close()
	var dbName string
	must(db.QueryRow(ctx, `select current_database()`).Scan(&dbName))
	if !strings.HasSuffix(dbName, "_test") {
		panic("load writes require an isolated database ending in _test")
	}
	must(database.Migrate(ctx, db))
	bases := strings.Split(os.Getenv("LOAD_URLS"), ",")
	if len(bases) < 2 {
		panic("two local instances are required")
	}
	for _, base := range bases {
		u, err := url.Parse(base)
		must(err)
		if u.Hostname() != "127.0.0.1" && u.Hostname() != "localhost" && !strings.HasPrefix(u.Hostname(), "relaydesk-commerce-") {
			panic("load targets must be isolated local servers")
		}
	}
	tenant, inbox, group := uuid.New(), uuid.New(), uuid.New()
	exec := func(sql string, args ...any) { _, err := db.Exec(ctx, sql, args...); must(err) }
	exec(`insert into tenant(id,name,slug,status) values($1,'千人在线隔离压测',$2,'ACTIVE')`, tenant, "load-"+tenant.String())
	exec(`insert into tenant_subscription(tenant_id,plan,status,seat_limit,monthly_message_limit) values($1,'ENTERPRISE','ACTIVE',100,100000)`, tenant)
	exec(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'load',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	owner := uuid.New()
	exec(`insert into visitor(id,tenant_id,inbox_id,display_name) values($1,$2,$3,'load owner')`, owner, tenant, inbox)
	exec(`insert into chat_group(id,tenant_id,inbox_id,name,kind,owner_id,owner_kind,max_members) values($1,$2,$3,'千人福利群','SERVICE',$4,'widget',2000)`, group, tenant, inbox, owner)
	clients := make([]*client, 1000)
	tokens := auth.NewTokenService(os.Getenv("LOAD_TOKEN_SECRET"), time.Hour, time.Hour)
	tx, err := db.Begin(ctx)
	must(err)
	for i := range clients {
		actor := owner
		if i > 0 {
			actor = uuid.New()
			_, err = tx.Exec(ctx, `insert into visitor(id,tenant_id,inbox_id,display_name) values($1,$2,$3,$4)`, actor, tenant, inbox, fmt.Sprintf("load-%d", i))
			must(err)
		}
		_, err = tx.Exec(ctx, `insert into chat_group_member(group_id,actor_kind,actor_id,name) values($1,'widget',$2,$3)`, group, actor, fmt.Sprintf("load-%d", i))
		must(err)
		token, err := tokens.IssueWidget(tenant, inbox, actor)
		must(err)
		clients[i] = &client{token: token, base: bases[i%len(bases)]}
	}
	must(tx.Commit(ctx))
	var unexpected atomic.Int64
	var latMu sync.Mutex
	latencies := []float64{}
	httpClient := &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{MaxIdleConns: 1100, MaxIdleConnsPerHost: 600, MaxConnsPerHost: 600}}
	request := func(c *client, method, path string, body any) map[string]any {
		start := time.Now()
		raw, _ := json.Marshal(body)
		req, _ := http.NewRequestWithContext(ctx, method, c.base+path, bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+c.token)
		req.Header.Set("Content-Type", "application/json")
		res, err := httpClient.Do(req)
		must(err)
		defer res.Body.Close()
		var data map[string]any
		must(json.NewDecoder(res.Body).Decode(&data))
		if res.StatusCode >= 300 {
			panic(fmt.Sprintf("load HTTP %d %v", res.StatusCode, data))
		}
		latMu.Lock()
		latencies = append(latencies, float64(time.Since(start).Microseconds())/1000)
		latMu.Unlock()
		return data
	}
	dial := func(c *client) {
		start := time.Now()
		wsURL := strings.Replace(c.base, "http", "ws", 1) + "/ws/groups?token=" + url.QueryEscape(c.token)
		conn, res, err := websocket.Dial(ctx, wsURL, nil)
		if res != nil && res.Body != nil {
			res.Body.Close()
		}
		must(err)
		c.conn = conn
		_, raw, err := conn.Read(ctx)
		must(err)
		var ready struct{ Type string }
		must(json.Unmarshal(raw, &ready))
		if ready.Type != "ready" {
			panic("subscription not ready")
		}
		latMu.Lock()
		latencies = append(latencies, float64(time.Since(start).Microseconds())/1000)
		latMu.Unlock()
		go func() {
			for {
				_, raw, err := conn.Read(ctx)
				if err != nil {
					if !c.expectedClose.Load() && ctx.Err() == nil {
						unexpected.Add(1)
					}
					return
				}
				var e struct{ Type string }
				if json.Unmarshal(raw, &e) == nil && e.Type == "group.updated" {
					c.events.Add(1)
				}
			}
		}()
	}
	runParallel := func(total, concurrency int, fn func(int)) {
		var wg sync.WaitGroup
		gate := make(chan struct{}, concurrency)
		for i := 0; i < total; i++ {
			wg.Add(1)
			gate <- struct{}{}
			go func(i int) { defer wg.Done(); defer func() { <-gate }(); fn(i) }(i)
		}
		wg.Wait()
	}
	started := time.Now()
	runParallel(1000, 40, func(i int) { dial(clients[i]) })
	fmt.Println("1000 sockets acknowledged across two instances")
	readyCounts := []int{}
	for _, base := range bases {
		res, err := httpClient.Get(base + "/ready")
		must(err)
		var data map[string]any
		must(json.NewDecoder(res.Body).Decode(&data))
		res.Body.Close()
		readyCounts = append(readyCounts, int(data["realtimeConnections"].(float64)))
	}
	stableStart := time.Now()
	notificationsExpected := int64(20)
	for i := 0; i < int(notificationsExpected); i++ {
		request(clients[i], "POST", "/api/v1/groups/"+group.String()+"/messages", map[string]any{"content": fmt.Sprintf("千人在线通知-%d", i), "clientId": uuid.NewString()})
		time.Sleep(150 * time.Millisecond)
	}
	deadline := time.Now().Add(20 * time.Second)
	for {
		complete := true
		for _, c := range clients {
			if c.events.Load() < notificationsExpected {
				complete = false
				break
			}
		}
		if complete {
			break
		}
		if time.Now().After(deadline) {
			panic("group notification delivery timeout")
		}
		time.Sleep(100 * time.Millisecond)
	}
	var delivered int64
	for _, c := range clients {
		delivered += c.events.Load()
	}
	historySuccess := atomic.Int64{}
	runParallel(1000, 80, func(i int) {
		data := request(clients[i], "GET", "/api/v1/groups/"+group.String()+"/messages?after=0", nil)
		if len(data["items"].([]any)) != int(notificationsExpected) {
			panic("history sequence gap")
		}
		request(clients[i], "POST", "/api/v1/groups/"+group.String()+"/read", map[string]any{"sequence": notificationsExpected})
		historySuccess.Add(1)
	})
	// 间隔心跳维持在线，包含多个服务端权限复核周期。
	for time.Since(stableStart) < 60*time.Second {
		runParallel(1000, 80, func(i int) { must(clients[i].conn.Write(ctx, websocket.MessageText, []byte(`{"type":"ping"}`))) })
		time.Sleep(5 * time.Second)
	}
	// 模拟100个客户端断线，然后验证补拉不会丢掉已落库消息。
	runParallel(100, 20, func(i int) {
		old := clients[i]
		old.expectedClose.Store(true)
		old.conn.CloseNow()
		replacement := &client{token: old.token, base: old.base}
		dial(replacement)
		clients[i] = replacement
		data := request(replacement, "GET", "/api/v1/groups/"+group.String()+"/messages?after=10", nil)
		if len(data["items"].([]any)) != 10 {
			panic("reconnect backfill gap")
		}
	})
	latMu.Lock()
	sort.Float64s(latencies)
	p95 := latencies[(len(latencies)-1)*95/100]
	p99 := latencies[(len(latencies)-1)*99/100]
	latMu.Unlock()
	report := map[string]any{"dateUTC": time.Now().UTC(), "clients": 1000, "instances": len(bases), "instanceOnlineCounts": readyCounts, "messages": 20, "expectedNotificationDeliveries": 20000, "observedNotificationDeliveries": delivered, "historyAndReadSuccess": historySuccess.Load(), "reconnectBackfillSuccess": 100, "unexpectedDisconnects": unexpected.Load(), "stableOnlineSeconds": time.Since(stableStart).Seconds(), "totalSeconds": time.Since(started).Seconds(), "combinedConnectAndRestP95Ms": p95, "combinedConnectAndRestP99Ms": p99, "scope": "isolated local two-instance group chat; 20 sequential broadcasts; not production capacity certification"}
	for _, c := range clients {
		c.expectedClose.Store(true)
		c.conn.CloseNow()
	}
	raw, _ := json.MarshalIndent(report, "", "  ")
	fmt.Println(string(raw))
	if output := os.Getenv("LOAD_REPORT"); output != "" {
		must(os.WriteFile(output, raw, 0644))
	}
	if unexpected.Load() != 0 {
		panic("unexpected disconnects")
	}
}
