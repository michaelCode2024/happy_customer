String planLabel(String value) => switch (value) {
      'TRIAL' => '试用版',
      'STARTER' => '入门版',
      'GROWTH' => '成长版',
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
      'OWNER' => '企业所有者',
      'ADMIN' => '管理员',
      'SUPERVISOR' => '主管',
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
