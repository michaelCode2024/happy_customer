package server

import (
	"github.com/google/uuid"
	"github.com/tongyu/tongyu/internal/auth"
	"net/http"
	"time"
)

const marketplaceThreadsSQL = `with threads as (
 select 'CONVERSATION'::text as kind,c.id,s.external_id as shop,t.name as title,c.status,coalesce(c.last_message_preview,'') as preview,c.last_sequence as sequence,c.updated_at,
 (select count(*) from message m where m.conversation_id=c.id and not m.is_private and m.sender_type='AGENT' and m.sequence>coalesce((select last_read_sequence from conversation_read where conversation_id=c.id and reader_type='VISITOR' and reader_id=v.id),0)) as unread
 from marketplace_shop s join tenant t on t.id=s.tenant_id join visitor v on v.inbox_id=s.inbox_id and v.tenant_id=s.tenant_id and v.external_id=$2 join conversation c on c.visitor_id=v.id and c.tenant_id=s.tenant_id where s.marketplace_id=$1
 union all
 select 'GROUP',g.id,s.external_id,g.name,case when g.dissolved_at is not null then 'DISSOLVED' when g.archived then 'ARCHIVED' else 'OPEN' end,
 coalesce((select case when gm.recalled_at is null then gm.content else '消息已撤回' end from chat_group_message gm where gm.group_id=g.id order by gm.sequence desc limit 1),''),g.sequence,g.updated_at,
 (select count(*) from chat_group_message gm where gm.group_id=g.id and gm.sequence>member.last_read and (gm.actor_kind<>'widget' or gm.actor_id<>v.id))
 from marketplace_shop s join visitor v on v.inbox_id=s.inbox_id and v.tenant_id=s.tenant_id and v.external_id=$2 join chat_group_member member on member.actor_kind='widget' and member.actor_id=v.id join chat_group g on g.id=member.group_id and g.inbox_id=s.inbox_id and g.tenant_id=s.tenant_id where s.marketplace_id=$1
 ) `

func (a *API) marketplaceBuyerThreads(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	limit := queryInt(r, "limit", 50)
	if limit < 1 {
		limit = 50
	}
	if limit > 100 {
		limit = 100
	}
	offset := queryInt(r, "offset", 0)
	if offset < 0 {
		offset = 0
	}
	rows, err := a.db.Query(r.Context(), marketplaceThreadsSQL+`select kind,id,shop,title,status,preview,sequence,updated_at,unread from threads order by updated_at desc,id limit $3 offset $4`, p.MarketplaceID, p.ExternalID, limit, offset)
	if err != nil {
		fail(w, 500, "读取统一消息失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var kind, shop, title, status, preview string
		var id uuid.UUID
		var sequence, unread int64
		var at time.Time
		if rows.Scan(&kind, &id, &shop, &title, &status, &preview, &sequence, &at, &unread) != nil {
			fail(w, 500, "读取消息失败")
			return
		}
		items = append(items, map[string]any{"kind": kind, "id": id, "shopId": shop, "title": title, "status": status, "lastMessagePreview": preview, "lastSequence": sequence, "updatedAt": at, "unread": unread})
	}
	if rows.Err() != nil {
		fail(w, 500, "读取消息失败")
		return
	}
	rows.Close()
	var total, unread int64
	if a.db.QueryRow(r.Context(), marketplaceThreadsSQL+`select count(*),coalesce(sum(unread),0) from threads`, p.MarketplaceID, p.ExternalID).Scan(&total, &unread) != nil {
		fail(w, 500, "读取未读失败")
		return
	}
	respond(w, 200, map[string]any{"items": items, "total": total, "unread": unread, "limit": limit, "offset": offset})
}
