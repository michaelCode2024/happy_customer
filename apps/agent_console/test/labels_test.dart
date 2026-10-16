import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/util/labels.dart';

void main() {
  test('business codes are displayed in Chinese without changing API values',
      () {
    expect(planLabel('TRIAL'), '体验版');
    expect(planLabel('STARTER'), '专业版');
    expect(planLabel('GROWTH'), '旗舰版');
    expect(planLabel('ENTERPRISE'), '企业版');
    expect(billingStatusLabel('PAST_DUE'), '已逾期');
    expect(tenantStatusLabel('SUSPENDED'), '已停用');
    expect(agentRoleLabel('SUPERVISOR'), '客服主管');
    expect(agentRoleLabel('AGENT'), '客服坐席');
    expect(agentRoleLabel('SUPERVISOR'), '客服主管');
    expect(agentRoleLabel('AGENT'), '客服坐席');
    expect(conversationSourceLabel('WEB'), '网站');
    expect(planLabel('CUSTOM'), 'CUSTOM');
  });
}
