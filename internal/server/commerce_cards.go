package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"github.com/relaydesk/relaydesk/internal/auth"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

type commerceCard struct {
	Kind        string `json:"kind"`
	ID          string `json:"id"`
	Title       string `json:"title"`
	ImageURL    string `json:"imageUrl,omitempty"`
	URL         string `json:"url,omitempty"`
	AmountMinor int64  `json:"amountMinor"`
	Currency    string `json:"currency"`
	OrderNumber string `json:"orderNumber,omitempty"`
	Status      string `json:"status,omitempty"`
}

func (a *API) marketplaceGroupCard(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	var in struct {
		ExternalID      string       `json:"externalId"`
		ClientMessageID string       `json:"clientMessageId"`
		Card            commerceCard `json:"card"`
		ShareOrder      bool         `json:"shareOrder"`
	}
	if !decode(w, r, &in) {
		return
	}
	gid, err := uuid.Parse(r.PathValue("id"))
	if err != nil || !in.Card.valid() || !validExternalID(in.ExternalID) {
		fail(w, 400, "群卡片参数无效")
		return
	}
	if in.Card.Kind == "ORDER" && !in.ShareOrder {
		fail(w, 400, "订单分享到群需明确shareOrder授权，避免泄露私密订单")
		return
	}
	var p auth.Principal
	if a.db.QueryRow(r.Context(), `select s.tenant_id,s.inbox_id,v.id from marketplace_shop s join chat_group g on g.inbox_id=s.inbox_id join visitor v on v.inbox_id=s.inbox_id and v.external_id=$3 where s.marketplace_id=$1 and s.external_id=$2 and g.id=$4`, mid, r.PathValue("shopId"), in.ExternalID, gid).Scan(&p.TenantID, &p.InboxID, &p.VisitorID) != nil || !a.tenantActive(r.Context(), p.TenantID) {
		fail(w, 404, "群或成员不属于该店铺")
		return
	}
	p.Kind = auth.KindWidget
	if !a.marketplaceVisitorActive(r.Context(), p) {
		fail(w, 403, "店员已停用，不能发送群卡片")
		return
	}
	raw, _ := json.Marshal(map[string]any{"content": in.Card.preview(), "clientId": in.ClientMessageID, "messageType": "CARD", "metadata": map[string]any{"card": in.Card, "source": "marketplace"}})
	request := r.Clone(r.Context())
	request.Body = io.NopCloser(bytes.NewReader(raw))
	a.groupSendWithCommerce(w, request, p, true)
}

var commerceCurrency = regexp.MustCompile(`^[A-Z]{3}$`)

func commerceURL(raw string) bool {
	if raw == "" {
		return true
	}
	u, err := url.Parse(raw)
	return err == nil && len(raw) <= 2048 && (u.Scheme == "https" || u.Scheme == "http") && u.Host != "" && u.User == nil
}
func (c commerceCard) valid() bool {
	return (c.Kind == "PRODUCT" || c.Kind == "ORDER") && validExternalID(c.ID) && validDisplayName(c.Title) && commerceURL(c.URL) && commerceURL(c.ImageURL) && c.AmountMinor >= 0 && c.AmountMinor <= 9007199254740991 && commerceCurrency.MatchString(c.Currency) && len([]rune(c.OrderNumber)) <= 120 && len([]rune(c.Status)) <= 120 && (c.Kind != "ORDER" || strings.TrimSpace(c.OrderNumber) != "")
}
func (c commerceCard) preview() string {
	text := fmt.Sprintf("%s %s %d.%02d", c.Title, c.Currency, c.AmountMinor/100, c.AmountMinor%100)
	if c.Kind == "ORDER" {
		text = "订单 " + c.OrderNumber + " " + text + " " + c.Status
	}
	return text
}

func validateCommerceMetadata(metadata map[string]any, trusted bool) error {
	raw, ok := metadata["card"]
	if !ok {
		return nil
	}
	encoded, err := json.Marshal(raw)
	if err != nil {
		return fmt.Errorf("卡片格式无效")
	}
	var card commerceCard
	if json.Unmarshal(encoded, &card) != nil || !card.valid() {
		return fmt.Errorf("商品订单卡片字段无效")
	}
	if !trusted {
		return fmt.Errorf("商品订单卡片必须由商城业务后端发送")
	}
	return nil
}

// 商品归属、订单归属与访问权限由持有商城密钥的业务后端验证，前端不能自报权威价格或订单状态。
func (a *API) marketplaceCard(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	var in struct {
		SenderType      string       `json:"senderType"`
		ExternalID      string       `json:"externalId"`
		ClientMessageID string       `json:"clientMessageId"`
		Card            commerceCard `json:"card"`
	}
	if !decode(w, r, &in) {
		return
	}
	cid, err := uuid.Parse(r.PathValue("id"))
	if err != nil || !in.Card.valid() || !validExternalID(in.ExternalID) {
		fail(w, 400, "会话、发送人或卡片参数无效")
		return
	}
	if _, err = uuid.Parse(in.ClientMessageID); err != nil {
		fail(w, 400, "需要UUID消息幂等标识")
		return
	}
	var tenant, visitor uuid.UUID
	if a.db.QueryRow(r.Context(), `select c.tenant_id,c.visitor_id from conversation c join marketplace_shop s on s.tenant_id=c.tenant_id and s.inbox_id=c.inbox_id where s.marketplace_id=$1 and s.external_id=$2 and c.id=$3`, mid, r.PathValue("shopId"), cid).Scan(&tenant, &visitor) != nil || !a.tenantActive(r.Context(), tenant) {
		fail(w, 404, "会话不属于该店铺或店铺不可用")
		return
	}
	actor := visitor
	switch in.SenderType {
	case "VISITOR":
		var ok bool
		if a.db.QueryRow(r.Context(), `select exists(select 1 from visitor where id=$1 and external_id=$2)`, visitor, in.ExternalID).Scan(&ok) != nil || !ok {
			fail(w, 403, "买家不属于此会话")
			return
		}
	case "AGENT":
		if a.db.QueryRow(r.Context(), `select ms.agent_id from marketplace_staff ms join agent ag on ag.id=ms.agent_id where ms.marketplace_id=$1 and ms.shop_id=$2 and ms.external_id=$3 and ag.status='ACTIVE'`, mid, r.PathValue("shopId"), in.ExternalID).Scan(&actor) != nil {
			fail(w, 403, "店员不属于此店铺")
			return
		}
	default:
		fail(w, 400, "发送身份需VISITOR或AGENT")
		return
	}
	msg, err := a.appendMessage(r.Context(), tenant, cid, messageInput{SenderType: in.SenderType, SenderID: &actor, ClientMessageID: in.ClientMessageID, MessageType: "CARD", Content: in.Card.preview(), Metadata: map[string]any{"card": in.Card, "source": "marketplace"}, CommerceTrusted: true})
	if err != nil {
		if !failServiceError(w, err) {
			fail(w, 400, err.Error())
		}
		return
	}
	respond(w, 201, msg)
}
