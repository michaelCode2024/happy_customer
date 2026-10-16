package server

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/config"
	"github.com/tongyu/tongyu/internal/platform/database"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestMarketplaceShopsStaffUnifiedInboxCardsAndRevocation(t *testing.T) {
	dsn := os.Getenv("TONGYU_TEST_DATABASE")
	if dsn == "" {
		t.Skip("database not configured")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = database.Migrate(ctx, db); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	cfg.Storage.LocalDir = t.TempDir()
	cfg.WidgetTokenKey = "marketplace-regression"
	cfg.AgentSessionTTL = time.Hour
	cfg.WidgetTokenTTL = time.Hour
	cfg.AllowedOrigins = []string{"*"}
	a, err := New(cfg, db, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(a.Handler())
	defer srv.Close()
	request := func(method, path, key, token string, body any, status int) map[string]any {
		t.Helper()
		raw, _ := json.Marshal(body)
		r, _ := http.NewRequest(method, srv.URL+path, strings.NewReader(string(raw)))
		r.Header.Set("Content-Type", "application/json")
		if key != "" {
			r.Header.Set("X-TongYu-Marketplace-Key", key)
		}
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		res, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		data := map[string]any{}
		json.NewDecoder(res.Body).Decode(&data)
		if res.StatusCode != status {
			t.Fatalf("%s %s: expected %d, got %d (%v)", method, path, status, res.StatusCode, data)
		}
		return data
	}
	createMarket := func() (uuid.UUID, string) {
		r := httptest.NewRequest("POST", "/", strings.NewReader(`{"name":"商城回归测试"}`))
		w := httptest.NewRecorder()
		a.platformMarketplace(w, r, auth.Principal{})
		var data struct {
			ID  uuid.UUID `json:"id"`
			Key string    `json:"apiKey"`
		}
		if w.Code != 201 || json.Unmarshal(w.Body.Bytes(), &data) != nil {
			t.Fatal(w.Body.String())
		}
		return data.ID, data.Key
	}
	mid, key := createMarket()
	foreign, foreignKey := createMarket()
	defer func() {
		for _, market := range []uuid.UUID{mid, foreign} {
			// 清理只属于本测试商城的租户。
			db.Exec(ctx, `delete from marketplace_buyer_session where marketplace_id=$1`, market)
			db.Exec(ctx, `delete from marketplace_staff where marketplace_id=$1`, market)
			rows, _ := db.Query(ctx, `select tenant_id from marketplace_shop where marketplace_id=$1`, market)
			ids := []uuid.UUID{}
			if rows != nil {
				for rows.Next() {
					var id uuid.UUID
					rows.Scan(&id)
					ids = append(ids, id)
				}
				rows.Close()
			}
			db.Exec(ctx, `delete from marketplace_shop where marketplace_id=$1`, market)
			for _, id := range ids {
				db.Exec(ctx, `delete from tenant where id=$1`, id)
			}
			db.Exec(ctx, `delete from marketplace where id=$1`, market)
		}
	}()
	for _, shop := range []string{"a", "b"} {
		request("PUT", "/api/v1/marketplace/shops/"+shop, key, "", map[string]any{"name": "店铺" + shop}, 201)
		repeated := request("PUT", "/api/v1/marketplace/shops/"+shop, key, "", map[string]any{"name": "店铺" + shop}, 200)
		if repeated["created"] != false {
			t.Fatal("shop retry created duplicate")
		}
		request("PUT", "/api/v1/marketplace/shops/"+shop+"/staff/owner", key, "", map[string]any{"displayName": "店主", "role": "SUPERVISOR"}, 201)
	}
	request("GET", "/api/v1/marketplace/shops/a", foreignKey, "", nil, 404)
	buyer := request("POST", "/api/v1/marketplace/buyer-session", key, "", map[string]any{"externalId": "buyer", "displayName": "买家"}, 200)["token"].(string)
	other := request("POST", "/api/v1/marketplace/buyer-session", key, "", map[string]any{"externalId": "other", "displayName": "其他买家"}, 200)["token"].(string)
	foreignBuyer := request("POST", "/api/v1/marketplace/buyer-session", foreignKey, "", map[string]any{"externalId": "buyer", "displayName": "买家"}, 200)["token"].(string)
	sessions := map[string]string{}
	conversations := map[string]string{}
	for _, shop := range []string{"a", "b"} {
		session := request("POST", "/api/v1/marketplace/buyer/shops/"+shop+"/session", "", buyer, nil, 200)["token"].(string)
		sessions[shop] = session
		conversation := request("POST", "/api/v1/widget/conversations", "", session, map[string]any{"source": "APP"}, 201)["conversation"].(map[string]any)["id"].(string)
		conversations[shop] = conversation
	}
	request("GET", "/api/v1/marketplace/buyer/threads", "", sessions["a"], nil, 401)
	bridge := request("POST", "/api/v1/marketplace/buyer/shops/a/session", "", buyer, nil, 200)
	bridgeWidget := request("POST", "/api/v1/widget/bootstrap", "", "", map[string]any{"inboxKey": bridge["inboxKey"], "identityToken": bridge["identityToken"]}, 200)["token"].(string)
	request("POST", "/api/v1/marketplace/buyer/shops/a/session", "", foreignBuyer, nil, 404)
	request("GET", "/api/v1/widget/conversations/"+conversations["b"]+"/messages", "", sessions["a"], nil, 404)
	staff := request("POST", "/api/v1/marketplace/shops/a/staff-session", key, "", map[string]any{"externalId": "owner"}, 200)["token"].(string)
	request("POST", "/api/v1/console/me/presence", "", staff, map[string]any{"status": "ONLINE"}, 200)
	request("POST", "/api/v1/console/conversations/"+conversations["a"]+"/claim", "", staff, map[string]any{}, 200)
	card := map[string]any{"kind": "ORDER", "id": "order-1", "title": "订单商品", "orderNumber": "NO-1", "status": "待发货", "currency": "CNY", "amountMinor": 29900, "url": "https://shop.example/orders/1"}
	input := map[string]any{"senderType": "AGENT", "externalId": "owner", "clientMessageId": uuid.NewString(), "card": card}
	cardMessage := request("POST", "/api/v1/marketplace/shops/a/conversations/"+conversations["a"]+"/cards", key, "", input, 201)
	privateId := uuid.NewString()
	request("POST", "/api/v1/console/conversations/"+conversations["a"]+"/messages", "", staff, map[string]any{"content": "内部订单备注", "private": true, "clientMessageId": privateId}, 201)
	request("POST", "/api/v1/widget/conversations/"+conversations["a"]+"/messages", "", sessions["a"], map[string]any{"content": "冒用内部消息标识", "clientMessageId": privateId}, 403)
	request("POST", "/api/v1/marketplace/shops/b/conversations/"+conversations["a"]+"/cards", key, "", input, 404)
	invalid := map[string]any{"kind": "PRODUCT", "id": "p", "title": "危险链接", "currency": "CNY", "amountMinor": 100, "url": "javascript:alert(1)"}
	request("POST", "/api/v1/marketplace/shops/a/conversations/"+conversations["a"]+"/cards", key, "", map[string]any{"senderType": "VISITOR", "externalId": "buyer", "clientMessageId": uuid.NewString(), "card": invalid}, 400)
	list := request("GET", "/api/v1/marketplace/buyer/conversations", "", buyer, nil, 200)
	if len(list["items"].([]any)) != 2 || list["unread"] != float64(1) {
		t.Fatalf("unified inbox: %v", list)
	}
	for _, token := range []string{other, foreignBuyer} {
		isolated := request("GET", "/api/v1/marketplace/buyer/conversations", "", token, nil, 200)
		if len(isolated["items"].([]any)) != 0 {
			t.Fatal("unified inbox leaked identity")
		}
	}
	request("POST", "/api/v1/widget/conversations/"+conversations["a"]+"/read", "", sessions["a"], map[string]any{"sequence": cardMessage["sequence"]}, 200)
	list = request("GET", "/api/v1/marketplace/buyer/conversations", "", buyer, nil, 200)
	if list["unread"] != float64(0) {
		t.Fatal("unified unread did not clear")
	}
	request("PUT", "/api/v1/marketplace/shops/a/staff/owner", key, "", map[string]any{"displayName": "店主", "role": "SUPERVISOR"}, 200)
	request("GET", "/api/v1/console/me", "", staff, nil, 200)
	request("POST", "/api/v1/marketplace/shops/a/groups", key, "", map[string]any{"externalGroupId": "bad", "name": "越权建群", "owner": map[string]any{"externalId": "buyer"}}, 403)
	group := request("POST", "/api/v1/marketplace/shops/a/groups", key, "", map[string]any{"externalGroupId": "benefits", "name": "福利群", "owner": map[string]any{"externalId": "owner"}, "members": []map[string]any{{"externalId": "buyer"}}}, 201)["groupId"].(string)
	ownerGroupToken := request("POST", "/api/v1/marketplace/staff/groups/"+group+"/session", "", staff, nil, 200)["token"].(string)
	buyerGroupToken := request("POST", "/api/v1/marketplace/buyer/groups/"+group+"/session", "", buyer, nil, 200)["token"].(string)
	request("POST", "/api/v1/marketplace/buyer/groups/"+group+"/session", "", foreignBuyer, nil, 404)
	product := map[string]any{"kind": "PRODUCT", "id": "p-1", "title": "福利商品", "currency": "CNY", "amountMinor": 19900}
	request("POST", "/api/v1/marketplace/shops/a/groups/"+group+"/cards", key, "", map[string]any{"externalId": "owner", "clientMessageId": uuid.NewString(), "card": product}, 201)
	request("POST", "/api/v1/marketplace/shops/a/groups/"+group+"/cards", key, "", map[string]any{"externalId": "owner", "clientMessageId": uuid.NewString(), "card": card}, 400)
	threads := request("GET", "/api/v1/marketplace/buyer/threads", "", buyer, nil, 200)
	if len(threads["items"].([]any)) != 3 || threads["unread"] != float64(1) {
		t.Fatalf("unified groups missing: %v", threads)
	}
	messages := request("GET", "/api/v1/groups/"+group+"/messages", "", buyerGroupToken, nil, 200)
	if messages["items"].([]any)[0].(map[string]any)["messageType"] != "CARD" {
		t.Fatal("group card not persisted")
	}
	request("POST", "/api/v1/groups/"+group+"/messages", "", buyerGroupToken, map[string]any{"content": "伪造", "clientId": uuid.NewString(), "messageType": "CARD", "metadata": map[string]any{"card": product}}, 400)
	request("POST", "/api/v1/groups/"+group+"/read", "", buyerGroupToken, map[string]any{"sequence": 1}, 200)
	threads = request("GET", "/api/v1/marketplace/buyer/threads", "", buyer, nil, 200)
	if threads["unread"] != float64(0) {
		t.Fatal("unified group unread did not clear")
	}
	request("PUT", "/api/v1/marketplace/shops/a/staff/owner", key, "", map[string]any{"displayName": "店主", "role": "SUPERVISOR", "status": "DISABLED"}, 200)
	request("GET", "/api/v1/groups/"+group, "", ownerGroupToken, nil, 401)
	request("POST", "/api/v1/marketplace/shops/a/groups/"+group+"/cards", key, "", map[string]any{"externalId": "owner", "clientMessageId": uuid.NewString(), "card": product}, 403)
	request("POST", "/api/v1/marketplace/shops/a/groups/"+group+"/member-token", key, "", map[string]any{"externalId": "owner"}, 403)
	request("GET", "/api/v1/console/me", "", staff, nil, 401)
	request("POST", "/api/v1/marketplace/shops/a/staff-session", key, "", map[string]any{"externalId": "owner"}, 404)
	request("POST", "/api/v1/marketplace/buyer/logout", "", buyer, nil, 200)
	request("GET", "/api/v1/groups/"+group, "", buyerGroupToken, nil, 401)
	request("GET", "/api/v1/marketplace/buyer/conversations", "", buyer, nil, 401)
	request("GET", "/api/v1/widget/conversations", "", sessions["a"], nil, 401)
	request("GET", "/api/v1/widget/conversations", "", bridgeWidget, nil, 401)
	request("POST", "/api/v1/uploads?conversationId="+conversations["a"], "", sessions["a"], nil, 404)
}
