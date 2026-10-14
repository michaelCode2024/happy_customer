package server

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/relaydesk/relaydesk/internal/realtime"
)

func receptionNotice(ctx context.Context, tx pgx.Tx, tenant, conversation uuid.UUID, content, state string) error {
	_, err := tx.Exec(ctx, `insert into reception_notice(tenant_id,conversation_id,content,state) values($1,$2,$3,$4)`, tenant, conversation, content, state)
	return err
}

// 确认与超时共用会话行锁；过期的分配不能被迟到的确认重新接走。
func (a *API) acceptReception(ctx context.Context, tenant, conversation, agent uuid.UUID, name string) error {
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var owner *uuid.UUID
	var accepted *time.Time
	var valid bool
	err = tx.QueryRow(ctx, `select assignee_id,accepted_at,assignment_expires_at is null or assignment_expires_at>clock_timestamp() from conversation where id=$1 and tenant_id=$2 and status<>'RESOLVED' for update`, conversation, tenant).Scan(&owner, &accepted, &valid)
	if err != nil {
		return err
	}
	if owner != nil && (*owner != agent || !valid) {
		return fmt.Errorf("会话已分配给其他客服或接单已超时，请刷新列表")
	}
	if accepted != nil {
		return tx.Commit(ctx)
	}
	tag, err := tx.Exec(ctx, `update conversation set assignee_id=$3,assigned_at=coalesce(assigned_at,now()),accepted_at=now(),assignment_expires_at=null,bot_paused=true,updated_at=now() where id=$1 and tenant_id=$2 and (assignment_expires_at is null or assignment_expires_at>clock_timestamp())`, conversation, tenant, agent)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("接单已超时，请刷新列表")
	}
	if err = receptionNotice(ctx, tx, tenant, conversation, fmt.Sprintf("客服「%s」已接入，请继续描述您的问题。", name), "ACCEPTED"); err != nil {
		return err
	}
	if err = tx.Commit(ctx); err != nil {
		return err
	}
	a.flushReceptionNotices(ctx)
	return nil
}

func (a *API) receptionLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			work, cancel := context.WithTimeout(ctx, 10*time.Second)
			if err := a.advanceReception(work); err != nil && ctx.Err() == nil {
				a.logger.Warn("reception routing failed", "error", err)
			}
			a.flushReceptionNotices(work)
			cancel()
		}
	}
}

func (a *API) advanceReception(ctx context.Context) error {
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx, `select id,tenant_id,assignee_id from conversation where status<>'RESOLVED' and accepted_at is null and ((assignee_id is not null and assignment_expires_at<=now()) or (assignee_id is null and handoff_requested_at is not null)) order by updated_at limit 50 for update skip locked`)
	if err != nil {
		return err
	}
	type item struct {
		id, tenant uuid.UUID
		owner      *uuid.UUID
	}
	items := []item{}
	for rows.Next() {
		var v item
		if err = rows.Scan(&v.id, &v.tenant, &v.owner); err != nil {
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
		if v.owner != nil {
			if _, err = tx.Exec(ctx, `insert into reception_timeout values($1,$2) on conflict do nothing`, v.id, *v.owner); err != nil {
				return err
			}
			if _, err = tx.Exec(ctx, `update conversation set assignee_id=null,assigned_at=null,assignment_expires_at=null,updated_at=now() where id=$1`, v.id); err != nil {
				return err
			}
			if err = receptionNotice(ctx, tx, v.tenant, v.id, "客服未在规定时间内接单，正在为您重新分配。", "QUEUED"); err != nil {
				return err
			}
		}
		var assigned *uuid.UUID
		if assigned, err = a.autoAssign(ctx, tx, v.tenant, v.id, nil, "VISITOR"); err != nil {
			return err
		}
		if assigned == nil && v.owner != nil {
			if err = receptionNotice(ctx, tx, v.tenant, v.id, "暂无其他客服可以接单，已为您排队。", "QUEUED"); err != nil {
				return err
			}
		}
	}
	return tx.Commit(ctx)
}

// 持久通知确保进程重启后不丢提示；数据库锁保证各实例按真实状态发生顺序投递。
func (a *API) flushReceptionNotices(ctx context.Context) {
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return
	}
	defer tx.Rollback(ctx)
	var locked bool
	if tx.QueryRow(ctx, `select pg_try_advisory_xact_lock(73190418)`).Scan(&locked) != nil || !locked {
		return
	}
	for i := 0; i < 100; i++ {
		var id int64
		var tenant, conversation uuid.UUID
		var content, state string
		err = tx.QueryRow(ctx, `select id,tenant_id,conversation_id,content,state from reception_notice where not delivered order by id limit 1`).Scan(&id, &tenant, &conversation, &content, &state)
		if err == pgx.ErrNoRows {
			break
		}
		if err != nil {
			return
		}
		_, err = a.appendMessage(ctx, tenant, conversation, messageInput{SenderType: "SYSTEM", MessageType: "SYSTEM", Content: content, ClientMessageID: fmt.Sprintf("reception:%d", id), Metadata: map[string]any{"handoff": true, "receptionState": state}})
		if err != nil {
			return
		}
		if _, err = tx.Exec(ctx, `update reception_notice set delivered=true where id=$1`, id); err != nil {
			return
		}
		a.publish(ctx, a.conversationChannels(ctx, conversation), realtime.Event{Type: "conversation.handoff", TenantID: tenant.String(), ConversationID: conversation.String(), Data: map[string]any{"receptionState": state}})
	}
	_ = tx.Commit(ctx)
}
