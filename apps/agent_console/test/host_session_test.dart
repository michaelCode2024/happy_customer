import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/state/credential_store.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';
void main() {
 test('宿主店员经服务端验证，票据不写入持久凭据', () async {
  final store=MemoryCredentialStore();
  final session=SessionController(store:store,apiFactory:(server)=>RelayDeskApi(server:server,client:MockClient((request)async{
   expect(request.headers['Authorization'] ?? request.headers['authorization'],'Bearer host-ticket');
   if(request.url.path.endsWith('/me'))return http.Response(jsonEncode({'id':'staff-1','email':'','displayName':'店主','role':'SUPERVISOR','presence':'ONLINE','tenant':{'id':'shop-1','name':'店铺','slug':'shop'}}),200,headers:{'content-type':'application/json; charset=utf-8'});
   return http.Response(jsonEncode({'items':[]}),200,headers:{'content-type':'application/json; charset=utf-8'});
  })));
  await session.adoptHostSession('http://localhost','host-ticket');
  expect(session.phase,SessionPhase.loggedIn);
  expect(session.tenant?.id,'shop-1');
  expect(await store.load(),isNull);
  session.dispose();
 });
 test('失效宿主身份不能沿用旧店员会话', () async {
  final session=SessionController(store:MemoryCredentialStore(),apiFactory:(server)=>RelayDeskApi(server:server,client:MockClient((_)async=>http.Response('{"message":"身份失效"}',401,headers:{'content-type':'application/json; charset=utf-8'}))));
  await session.adoptHostSession('http://localhost','expired');
  expect(session.phase,SessionPhase.loggedOut);
  expect(session.agent,isNull);
  session.dispose();
 });
}
