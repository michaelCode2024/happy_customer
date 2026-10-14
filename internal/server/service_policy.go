package server

import (
	"context"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"net/http"
	"time"
)

type serviceError struct{ code, message string }

func (e serviceError) Error() string { return e.message }
func failServiceError(w http.ResponseWriter, err error) bool {
	var policy serviceError
	if errors.As(err, &policy) {
		failCode(w, 403, policy.code, policy.message)
		return true
	}
	return false
}

// Quota accounting uses the same rows as the usage screen, including group
// messages. The tenant lock serialises sends across every conversation/group.
func (a *API) checkMessageQuota(ctx context.Context, tx pgx.Tx, tenant uuid.UUID) error {
	if _, err := tx.Exec(ctx, `select pg_advisory_xact_lock(hashtextextended($1,0))`, tenant.String()); err != nil {
		return err
	}
	var active bool
	var limit int64
	err := tx.QueryRow(ctx, `select status='ACTIVE' and (plan<>'TRIAL' or trial_ends_at is null or trial_ends_at>now()) and (service_starts_at is null or service_starts_at<=now()) and (service_ends_at is null or service_ends_at>now()),monthly_message_limit::bigint+coalesce((select messages from tenant_quota_bonus where tenant_id=$1 and month=date_trunc('month',now())::date),0) from tenant_subscription where tenant_id=$1`, tenant).Scan(&active, &limit)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if !active {
		return serviceError{"SUBSCRIPTION_INACTIVE", "服务套餐已暂停或试用已到期，请联系平台管理员恢复服务"}
	}
	var used int64
	err = tx.QueryRow(ctx, monthlyUsageSQL, tenant).Scan(&used)
	if err != nil {
		return err
	}
	if limit > 0 && used >= int64(limit) {
		return serviceError{"MESSAGE_LIMIT_REACHED", "本月消息额度已用完，请联系平台管理员调整额度"}
	}
	return nil
}

const monthlyUsageSQL = `select (select count(*) from message where tenant_id=$1 and not is_private and message_type not in ('EVENT','SYSTEM','RATING') and created_at>=date_trunc('month',now())) + (select count(*) from chat_group_message m join chat_group g on g.id=m.group_id where g.tenant_id=$1 and m.created_at>=date_trunc('month',now()))`

func (a *API) currentAgent(ctx context.Context, p auth.Principal) (auth.Principal, bool) {
	var role string
	err := a.db.QueryRow(ctx, `select ag.role from agent ag join tenant t on t.id=ag.tenant_id where ag.id=$1 and ag.tenant_id=$2 and ag.status='ACTIVE' and t.status='ACTIVE'`, p.AgentID, p.TenantID).Scan(&role)
	if err != nil {
		return p, false
	}
	p.Role = role
	return p, true
}

// Long-lived sockets also observe administrative changes; a revoked login or
// disabled tenant cannot keep receiving data on an old subscribed channel.
func (a *API) guardSocket(ctx context.Context, s *realtime.Subscriber, p auth.Principal) {
	go func() {
		ticker := time.NewTicker(time.Second * 3)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-s.Done():
				return
			case <-ticker.C:
				valid := a.tenantActive(ctx, p.TenantID) && (p.ExpiresAt == 0 || time.Now().Unix() < p.ExpiresAt)
				if p.Kind == auth.KindAgent {
					current, ok := a.currentAgent(ctx, p)
					valid = valid && ok && current.Role == p.Role && a.authn.SessionValid(ctx, p.SessionID, p.AgentID)
				}
				if p.Kind == auth.KindWidget {
					valid = valid && a.marketplaceVisitorActive(ctx, p)
					if p.MarketplaceID != uuid.Nil {
						valid = valid && a.marketplaceBuyerValid(ctx, p)
					}
					var active bool
					err := a.db.QueryRow(ctx, `select exists(select 1 from inbox where id=$1 and tenant_id=$2 and status='ACTIVE')`, p.InboxID, p.TenantID).Scan(&active)
					valid = valid && err == nil && active
				}
				if !valid {
					s.Close()
					return
				}
			}
		}
	}()
}
