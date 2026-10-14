"""仅监听本机的商城联调示例。模拟账号，不能用作生产登录服务。密钥仅留在后端内存。"""
import json, os, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from urllib.parse import urlparse

BASE = os.environ.get('RELAYDESK_URL', 'http://127.0.0.1:18080').rstrip('/')
if urlparse(BASE).hostname not in ('127.0.0.1', 'localhost'):
    raise RuntimeError('联调示例只允许本机服务，不能用模拟账号对接生产环境')
sessions = {}
groups = {}
def call(method, path, body=None, key=None, token=None):
    headers = {'Content-Type': 'application/json'}
    if key: headers['X-RelayDesk-Marketplace-Key'] = key
    if token: headers['Authorization'] = 'Bearer ' + token
    request = Request(BASE + path, data=json.dumps(body or {}).encode() if method != 'GET' else None, headers=headers, method=method)
    with urlopen(request, timeout=20) as response: return json.load(response)

admin = call('POST', '/api/v1/platform/login', {'email': os.environ['DEMO_ADMIN_EMAIL'], 'password': os.environ['DEMO_ADMIN_PASSWORD']})['token']
market = call('POST', '/api/v1/platform/marketplaces', {'name': '本机商城联调示例'}, token=admin)
KEY = market['apiKey']
shops = {}
for shop, name in [('a', '店铺A'), ('b', '店铺B')]:
    shops[shop] = call('PUT', '/api/v1/marketplace/shops/' + shop, {'name': name}, key=KEY)
    call('PUT', '/api/v1/marketplace/shops/' + shop + '/staff/owner', {'displayName': name + '店主', 'role': 'SUPERVISOR'}, key=KEY)
    groups[shop] = call('POST', '/api/v1/marketplace/shops/' + shop + '/groups', {'externalGroupId': 'benefits-' + shop, 'name': name + '福利群', 'owner': {'externalId': 'owner', 'displayName': name + '店主'}, 'maxMembers': 2000}, key=KEY)['groupId']

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def respond(self, data, code=200):
        raw = json.dumps(data, ensure_ascii=False).encode(); self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8'); self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        if self.path != '/': return self.respond({'message': '不存在'}, 404)
        raw = Path(__file__).with_name('index.html').read_bytes(); self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.end_headers(); self.wfile.write(raw)
    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
            if self.path == '/api/login':
                role = body.get('role'); shop = body.get('shop', 'a')
                if role not in ('buyer', 'staff') or shop not in shops: return self.respond({'message': '示例账号无效'}, 400)
                if role == 'buyer': data = call('POST', '/api/v1/marketplace/buyer-session', {'externalId': 'demo-buyer', 'displayName': '示例买家'}, key=KEY)
                else:
                    data = call('POST', '/api/v1/marketplace/shops/' + shop + '/staff-session', {'externalId': 'owner'}, key=KEY)
                    call('POST', '/api/v1/console/me/presence', {'status': 'ONLINE'}, token=data['token'])
                sid = uuid.uuid4().hex; sessions[sid] = {'role': role, 'shop': shop, 'token': data['token']}
                raw = json.dumps({**data, 'endpoint': BASE, 'shops': shops, 'role': role, 'shop': shop}).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Set-Cookie', 'demo_session=' + sid + '; HttpOnly; SameSite=Strict; Path=/'); self.end_headers(); self.wfile.write(raw); return
            cookie = dict(item.strip().split('=', 1) for item in self.headers.get('Cookie', '').split(';') if '=' in item)
            session = sessions.get(cookie.get('demo_session'))
            if not session: return self.respond({'message': '请先选择示例账号'}, 401)
            if self.path == '/api/card':
                shop = session['shop'] if session['role'] == 'staff' else body.get('shop')
                if shop not in shops: return self.respond({'message': '店铺无效'}, 400)
                # 实际宿主应从自己的商品/订单库读取，检查订单属于当前买家/店铺。
                card = {'kind': body.get('kind'), 'id': 'sample-1', 'title': '示例商品：店铺专享礼盒', 'currency': 'CNY', 'amountMinor': 29900, 'url': 'https://example.com/item/1'}
                if card['kind'] == 'ORDER': card.update(orderNumber='DEMO-20261014-001', status='待发货')
                result = call('POST', '/api/v1/marketplace/shops/' + shop + '/conversations/' + body['conversationId'] + '/cards', {'senderType': 'AGENT' if session['role'] == 'staff' else 'VISITOR', 'externalId': 'owner' if session['role'] == 'staff' else 'demo-buyer', 'clientMessageId': body.get('clientMessageId') or str(uuid.uuid4()), 'card': card}, key=KEY)
                return self.respond(result)
            if self.path == '/api/group':
                shop = session['shop'] if session['role'] == 'staff' else body.get('shop', 'a')
                if shop not in shops: return self.respond({'message': '店铺无效'}, 400)
                group = groups[shop]
                if session['role'] == 'buyer':
                    if body.get('consent') is not True: return self.respond({'message': '需买家主动确认加入'}, 400)
                    call('POST', '/api/v1/marketplace/shops/' + shop + '/groups/' + group + '/members', {'actorExternalId': 'owner', 'members': [{'externalId': 'demo-buyer', 'displayName': '示例买家'}]}, key=KEY)
                data = call('POST', '/api/v1/marketplace/' + ('staff' if session['role'] == 'staff' else 'buyer') + '/groups/' + group + '/session', token=session['token'])
                return self.respond({**data, 'groupId': group, 'endpoint': BASE})
            return self.respond({'message': '不存在'}, 404)
        except HTTPError as error:
            self.respond(json.loads(error.read()), error.code)
        except Exception as error:
            self.respond({'message': type(error).__name__ + '，请检查本机联调服务'}, 500)

print('商城联调示例：http://127.0.0.1:18090 （模拟账号，仅供本机验收）', flush=True)
ThreadingHTTPServer(('127.0.0.1', 18090), Handler).serve_forever()
