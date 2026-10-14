alter table chat_group_message add column message_type varchar(20) not null default 'TEXT' check(message_type in ('TEXT','CARD'));
alter table chat_group_message add column metadata jsonb not null default '{}';
