create table if not exists agent_alert_preference (
 agent_id uuid primary key references agent(id) on delete cascade,
 tenant_id uuid not null references tenant(id) on delete cascade,
 quiet_until timestamptz
);
