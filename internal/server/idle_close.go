package server

import (
	"context"
	"time"

	"github.com/google/uuid"

	"github.com/tongyu/tongyu/internal/realtime"
	"github.com/tongyu/tongyu/internal/webhook"
)

// resolveConversation 把会话标记为已结束。手动「已解决」和空闲超时自动结束共用收尾那一段，
// 保证 closed_at、结束提示、日统计和 conversation.closed 广播不会走成两条路。
// 返回 false 表示会话早已结束：不补提示，也不再叠加统计和广播，
// 否则坐席连点或两个实例同一轮扫到都会把 conversations_closed 吹大。
func (a *API) resolveConversation(ctx context.Context, tenantID, conversationID uuid.UUID, closedBy any, notice string) (bool, error) {
	res, err := a.db.Exec(ctx, `update conversation
		set status='RESOLVED', closed_at=now(), updated_at=now(), agent_unread=0
		where id=$1 and tenant_id=$2 and status <> 'RESOLVED'`, conversationID, tenantID)
	if err != nil {
		return false, err
	}
	if res.RowsAffected() == 0 {
		return false, nil
	}
	a.afterConversationResolved(ctx, tenantID, conversationID, closedBy, notice)
	return true, nil
}

// resolveIdleConversation 只结束确实还没动过的会话。判定条件直接写进 where，
// 免得扫描和收尾之间访客刚好插了句话，却被上一轮取到的旧快照掐掉。
func (a *API) resolveIdleConversation(ctx context.Context, tenantID, conversationID uuid.UUID) (bool, error) {
	res, err := a.db.Exec(ctx, `update conversation c
		set status='RESOLVED', closed_at=now(), updated_at=now(), agent_unread=0
		from tenant t
		where c.id=$1 and c.tenant_id=$2 and t.id = c.tenant_id
		  and c.status <> 'RESOLVED'
		  and t.conversation_auto_close_minutes > 0
		  and c.last_message_at <= now() - make_interval(mins => t.conversation_auto_close_minutes)`,
		conversationID, tenantID)
	if err != nil {
		return false, err
	}
	if res.RowsAffected() == 0 {
		return false, nil
	}
	a.afterConversationResolved(ctx, tenantID, conversationID, nil, endNoticeIdle)
	return true, nil
}

func (a *API) afterConversationResolved(ctx context.Context, tenantID, conversationID uuid.UUID, closedBy any, notice string) {
	a.appendEndedNotice(ctx, tenantID, conversationID, notice)
	a.bumpDailyStat(ctx, tenantID, "conversations_closed")
	a.publish(ctx, a.conversationChannels(ctx, conversationID), realtime.Event{
		Type: "conversation.closed", TenantID: tenantID.String(), ConversationID: conversationID.String(),
		Data: map[string]any{"closedBy": closedBy},
	})
	a.notifyWebhook(ctx, tenantID, webhook.EventConversationClosed, map[string]any{
		"conversationId": conversationID, "closedBy": closedBy, "closedAt": nowUTC(),
	})
}

// idleCloseLoop 定期结束长时间没有新消息的会话。时长按企业设置，0 表示该企业不自动结束。
func (a *API) idleCloseLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			work, cancel := context.WithTimeout(ctx, 30*time.Second)
			if err := a.closeIdleConversations(work, 0); err != nil && ctx.Err() == nil {
				a.logger.Warn("空闲会话自动结束失败", "error", err)
			}
			cancel()
		}
	}
}

// closeIdleConversations 用 last_message_at 而不是 updated_at 判定空闲：updated_at 会被
// 转接、内部备注等动作推着走，早就没人说话的会话会被一直续下去。
// 取候选时不加行锁——认领在 update 里按 status 和 last_message_at 完成，
// 多实例同一轮扫到同一批也只有一个实例会补提示和统计。
func (a *API) closeIdleConversations(ctx context.Context, idle time.Duration) error {
	_ = idle
	rows, err := a.db.Query(ctx, `
		select c.id, c.tenant_id from conversation c
		  join tenant t on t.id = c.tenant_id
		 where c.status <> 'RESOLVED'
		   and t.conversation_auto_close_minutes > 0
		   and c.last_message_at <= now() - make_interval(mins => t.conversation_auto_close_minutes)
		 order by c.last_message_at
		 limit 50`)
	if err != nil {
		return err
	}
	type item struct {
		id, tenant uuid.UUID
	}
	items := []item{}
	for rows.Next() {
		var v item
		if err = rows.Scan(&v.id, &v.tenant); err != nil {
			rows.Close()
			return err
		}
		items = append(items, v)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, v := range items {
		if _, err = a.resolveIdleConversation(ctx, v.tenant, v.id); err != nil {
			return err
		}
	}
	return nil
}
