String planLabel(String value) => switch (value) {
      'TRIAL' => '体验版',
      'STARTER' => '专业版',
      'GROWTH' => '旗舰版',
      'ENTERPRISE' => '企业版',
      _ => value,
    };

String billingStatusLabel(String value) => switch (value) {
      'ACTIVE' => '正常',
      'TRIALING' => '试用中',
      'PAST_DUE' => '已逾期',
      'CANCELED' => '已取消',
      'EXPIRED' => '已到期',
      _ => value,
    };

String tenantStatusLabel(String value) => switch (value) {
      'ACTIVE' => '正常使用',
      'SUSPENDED' => '已停用',
      _ => value,
    };

String agentRoleLabel(String value) => switch (value) {
      'OWNER' => '客服主管',
      'ADMIN' => '客服主管',
      'SUPERVISOR' => '客服主管',
      'AGENT' => '客服坐席',
      _ => value,
    };

String conversationSourceLabel(String value) => switch (value) {
      'WEB' => '网站',
      'H5' => '手机网页',
      'APP' => '应用',
      'API' => '接口',
      _ => value,
    };

String auditActionLabel(String value) => switch (value) {
      'tenant.create' => '开通企业',
      'tenant.update' => '更新企业设置',
      'tenant.trial.extend' => '延长试用期',
      'tenant.owner_reset' => '重置企业管理员',
      'inbox.create' => '创建客服入口',
      'inbox.update' => '更新客服入口',
      'inbox.delete' => '删除客服入口',
      'agent.create' => '添加团队成员',
      'agent.update' => '更新成员资料',
      'agent.delete' => '删除团队成员',
      'agent.login' => '成员登录',
      'agent.password_reset' => '重置成员密码',
      'agent.password_changed' => '修改登录密码',
      'webhook.create' => '创建事件回调',
      'api_key.create' => '创建接口密钥',
      'api_key.revoke' => '撤销接口密钥',
      'knowledge.create' => '新增知识',
      'knowledge.update' => '更新知识',
      'knowledge.delete' => '删除知识',
      'knowledge.import' => '批量导入知识',
      'conversation.transfer' => '转接会话',
      'message.edit' => '编辑消息',
      _ => value,
    };

String aiReasonLabel(String value) => switch (value) {
      'AI_DISABLED' => '平台尚未配置可用 AI 模型，知识检索仍可使用',
      'NO_ROUTING_RULE' => '当前入口尚未配置自动接待规则',
      'NO_KNOWLEDGE_BASE' => '知识库没有匹配的答案',
      'NO_KNOWLEDGE' => '知识库没有匹配的答案',
      'LOW_CONFIDENCE' => '知识覆盖不足，需要人工确认',
      'PROVIDER_ERROR' => '模型服务暂时不可用',
      'AGENT_ALREADY_ASSIGNED' => '人工客服已接管',
      'PROMPT_INJECTION' => '问题触发安全保护',
      _ => value.isEmpty ? '未生成回答' : value,
    };
