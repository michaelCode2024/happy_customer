import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/ui/platform_support.dart';

void main() {
  test('工作台只接通语官方技术支持收件箱', () {
    final page = platformSupportPage(
      origin: 'https://chat.lookfunny.xyz/',
      displayName: '彩站 · 客服主管 · 小林',
      subject: '工作台席位与套餐',
    );
    expect(page.path, '/h5/$officialSupportInboxKey');
    expect(page.queryParameters['title'], '通语技术支持');
    expect(page.queryParameters['storage'], 'tongyu.console.support');
    expect(page.queryParameters['source'], 'PC');
    expect(page.queryParameters.containsKey('externalId'), isFalse);
    expect(page.toString(), isNot(contains('business')));
  });

  test('配置指向其他入口时拒绝', () {
    expect(
      officialSupportKeyFromConfig({
        'entries': {
          'business': {'inboxKey': ''},
          'support': {'inboxKey': officialSupportInboxKey},
        },
      }),
      officialSupportInboxKey,
    );
    expect(
      officialSupportKeyFromConfig({
        'entries': {
          'support': {'inboxKey': 'some-customer-inbox'},
        },
      }),
      isNull,
    );
    expect(
      officialSupportKeyFromConfig({
        'entries': {
          'business': {'inboxKey': 'tongyu-business'},
          'support': {'inboxKey': ''},
        },
      }),
      isNull,
    );
  });

  test('已登录成员名称带上企业与角色', () {
    expect(
      supportVisitorLabel(
        tenantName: '彩站',
        role: 'SUPERVISOR',
        displayName: '小林',
      ),
      '彩站 · 客服主管 · 小林',
    );
    expect(supportVisitorLabel(), '工作台访客');
  });
}
