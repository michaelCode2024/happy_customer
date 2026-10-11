ALTER TABLE chat_group ADD COLUMN dissolved_at timestamptz;
ALTER TABLE chat_group_message ADD COLUMN recalled_at timestamptz;

CREATE TABLE chat_group_call (
 id uuid PRIMARY KEY,
 group_id uuid NOT NULL REFERENCES chat_group(id) ON DELETE CASCADE,
 caller_kind varchar(16) NOT NULL CHECK(caller_kind IN ('agent','widget')),
 caller_id uuid NOT NULL,
 recipient_kind varchar(16) NOT NULL CHECK(recipient_kind IN ('agent','widget')),
 recipient_id uuid NOT NULL,
 state varchar(16) NOT NULL DEFAULT 'RINGING' CHECK(state IN ('RINGING','ACCEPTED','ENDED','DECLINED','MISSED')),
 offer jsonb NOT NULL,
 answer jsonb,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX chat_group_call_live ON chat_group_call(group_id,created_at DESC) WHERE state IN ('RINGING','ACCEPTED');
