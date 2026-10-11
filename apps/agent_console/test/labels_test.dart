import 'package:flutter_test/flutter_test.dart';
import 'package:relaydesk_agent_console/src/util/labels.dart';

void main() {
  test('business codes are displayed in Chinese without changing API values', () {
    expect(planLabel('TRIAL'), '试用版');
    expect(planLabel('ENTERPRISE'), '企业版');
    expect(billingStatusLabel('PAST_DUE'), '已逾期');
    expect(tenantStatusLabel('SUSPENDED'), '已停用');
    expect(agentRoleLabel('OWNER'), '企业所有者');
    expect(conversationSourceLabel('WEB'), '网站');
    expect(planLabel('CUSTOM'), 'CUSTOM');
  });
}
