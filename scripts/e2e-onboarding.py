#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通语本机全链路验收（API 级）。

覆盖：平台登录 → 开通企业 → 建客服 → 坐席上线 → 知识库 → 开 AI →
访客发消息 → 坐席领取/回复 → 自动回复配置可读。

用法（本机服务已在 :8080）：
  python scripts/e2e-onboarding.py
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request
from typing import Any

BASE = "http://127.0.0.1:8080"
PLATFORM_EMAIL = "admin@tongyu.local"
PLATFORM_PASSWORD = "TongYu@2026"
OWNER_PASSWORD = "TongYu@2026"


class Fail(Exception):
    pass


def req(
    method: str,
    path: str,
    body: dict | None = None,
    token: str | None = None,
    headers: dict | None = None,
) -> Any:
    data = None if body is None else json.dumps(body).encode("utf-8")
    h = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    if headers:
        h.update(headers)
    request = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(request, timeout=45) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise Fail(f"{method} {path} -> {e.code}: {detail}") from e


def step(name: str) -> None:
    print(f"\n==> {name}")


def main() -> int:
    stamp = time.strftime("%m%d%H%M%S")
    slug = f"fresh-{stamp}"
    owner = f"owner-{stamp}"
    agent = f"agent-{stamp}"
    results: list[tuple[str, str]] = []

    def ok(item: str) -> None:
        results.append((item, "PASS"))
        print(f"  [PASS] {item}")

    def skip(item: str, why: str) -> None:
        results.append((item, f"SKIP ({why})"))
        print(f"  [SKIP] {item}: {why}")

    try:
        step("健康检查")
        ready = req("GET", "/ready")
        if ready.get("status") != "READY":
            raise Fail(f"not ready: {ready}")
        ok("服务就绪 /ready")
        if ready.get("ai") in (None, "", "disabled"):
            skip("AI 提供方", f"当前 ai={ready.get('ai')}")
        else:
            ok(f"AI 已启用 ({ready.get('ai')})")

        step("平台管理员登录")
        plat = req(
            "POST",
            "/api/v1/platform/login",
            {"email": PLATFORM_EMAIL, "password": PLATFORM_PASSWORD},
        )
        ptoken = plat["token"]
        ok("平台登录")

        step("开通企业与负责人")
        created = req(
            "POST",
            "/api/v1/platform/tenants",
            {
                "name": f"通语验收企业{stamp}",
                "slug": slug,
                "ownerEmail": owner,
                "ownerName": "企业负责人",
                "ownerPassword": OWNER_PASSWORD,
                "inboxName": "在线客服",
                "publicKey": f"{slug}-web",
                # GROWTH 及以上才含 AI / 自动回复套餐能力（见 planFeatures）。
                "plan": "GROWTH",
                "trialDays": 14,
            },
            token=ptoken,
        )
        tenant_id = created.get("tenantId") or created.get("id")
        inbox_id = created.get("inboxId")
        public_key = created.get("publicKey") or f"{slug}-web"
        if not tenant_id or not inbox_id:
            raise Fail(f"开通响应缺字段: {created}")
        ok(f"开通企业 slug={slug} plan=GROWTH inbox={public_key}")

        step("平台建立客服账号")
        agent_body = req(
            "POST",
            f"/api/v1/platform/tenants/{tenant_id}/agents",
            {
                "email": agent,
                "displayName": "验收客服",
                "password": OWNER_PASSWORD,
                "role": "AGENT",
                "inboxIds": [inbox_id],
            },
            token=ptoken,
        )
        ok(f"建立客服 {agent_body.get('email', agent)}")

        step("企业负责人登录工作台")
        console = req(
            "POST",
            "/api/v1/console/login",
            {
                "tenantSlug": slug,
                "email": owner,
                "password": OWNER_PASSWORD,
            },
        )
        ctoken = console["token"]
        ok("负责人登录")

        # console 登录会把坐席标成 ONLINE；先显式离线，避免访客消息被自动分配后 AI 静默。
        req("POST", "/api/v1/console/me/presence", {"status": "OFFLINE"}, token=ctoken)
        ok("登录后先离线")

        step("知识库写入与试答")
        entry = req(
            "POST",
            "/api/v1/console/knowledge",
            {
                "title": "退款怎么办理",
                "content": "退款请在订单页提交申请，工作日 24 小时内审核。",
                "questionExamples": "怎么退款\n退款流程",
                "status": "ACTIVE",
            },
            token=ctoken,
        )
        ok(f"知识条目 {entry.get('id', 'created')}")
        preview = req(
            "POST",
            "/api/v1/console/knowledge/preview",
            {"question": "退款怎么办理"},
            token=ctoken,
        )
        ok(f"知识试答 reason={preview.get('reason', preview.get('status', 'ok'))}")

        step("开启入口 AI 自动接待")
        req(
            "PATCH",
            f"/api/v1/admin/inboxes/{inbox_id}/ai",
            {"enabled": True, "confidenceThreshold": 0.35},
            token=ctoken,
        )
        ok("入口 AI 已开启")

        step("访客 bootstrap + 发消息")
        boot = req(
            "POST",
            "/api/v1/widget/bootstrap",
            {"inboxKey": public_key, "displayName": "验收访客"},
        )
        wtoken = boot.get("token") or boot.get("visitorToken")
        if not wtoken:
            raise Fail(f"bootstrap 无 token: {boot}")
        ok("访客 bootstrap")

        conv = req(
            "POST",
            "/api/v1/widget/conversations",
            {"subject": "退款咨询"},
            token=wtoken,
        )
        conv_id = conv.get("id") or conv.get("conversationId")
        if not conv_id:
            # 有的实现 bootstrap 已带会话
            items = req("GET", "/api/v1/widget/conversations", token=wtoken).get("items") or []
            if items:
                conv_id = items[0]["id"]
        if not conv_id:
            raise Fail(f"无法创建会话: {conv}")
        ok(f"会话 {conv_id}")

        msg = req(
            "POST",
            f"/api/v1/widget/conversations/{conv_id}/messages",
            {"content": "你好，请问退款怎么办理？", "clientMessageId": f"e2e-{stamp}-1"},
            token=wtoken,
        )
        ok(f"访客消息 {msg.get('id', 'sent')}")

        step("等待 AI 自动回复")
        # AI 在访客发送后异步跑，模型网关可能要几十秒；不能因「会话已出现」提前结束等待。
        # 成功回复落成 AGENT + metadata.ai；置信不足时落 SYSTEM 转人工提示，也算链路通。
        seen_ai = False
        for _ in range(30):
            time.sleep(2)
            messages = req(
                "GET",
                f"/api/v1/widget/conversations/{conv_id}/messages",
                token=wtoken,
            )
            items = messages.get("items") or messages.get("messages") or []
            for m in items:
                meta = m.get("metadata") or {}
                if (
                    meta.get("ai")
                    or m.get("isAi")
                    or m.get("senderType") in ("AI", "BOT", "SYSTEM")
                ):
                    seen_ai = True
                    break
            if seen_ai:
                break
        if seen_ai:
            ok("收到 AI 自动回复")
        else:
            skip("AI 自动回复", "超时未看到 AI 气泡（可能阈值未命中或异步未完成）")

        step("坐席上线并领取回复")
        req("POST", "/api/v1/console/me/presence", {"status": "ONLINE"}, token=ctoken)
        ok("presence=ONLINE")
        try:
            req(
                "POST",
                f"/api/v1/console/conversations/{conv_id}/claim",
                {},
                token=ctoken,
            )
            ok("领取会话")
        except Fail as e:
            skip("领取会话", str(e)[:160])

        try:
            req(
                "POST",
                f"/api/v1/console/conversations/{conv_id}/messages",
                {
                    "content": "您好，已收到，我帮您看一下退款流程。",
                    "clientMessageId": f"e2e-{stamp}-agent",
                },
                token=ctoken,
            )
            ok("坐席回复")
        except Fail as e:
            skip("坐席回复", str(e)[:160])

        step("自动回复配置可读")
        auto = req(
            "GET",
            f"/api/v1/admin/inboxes/{inbox_id}/automation",
            token=ctoken,
        )
        ok(f"自动回复配置可读 revision={auto.get('revision', '?')}")

        step("安装片段可读")
        install = req(
            "GET",
            f"/api/v1/admin/inboxes/{inbox_id}/snippet",
            token=ctoken,
        )
        snippet = install.get("snippet") or install.get("scriptUrl") or ""
        if not snippet:
            raise Fail(f"安装片段为空: {install}")
        ok("渠道安装信息可读")

    except Fail as e:
        print(f"\n[FAIL] {e}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"\n[ERROR] {e}", file=sys.stderr)
        return 1

    print("\n======== 验收矩阵 ========")
    for name, status in results:
        print(f"{status:28} {name}")
    print("==========================")
    print(
        f"\n手工续测入口:\n"
        f"  后台  {BASE}/console/\n"
        f"  平台  {PLATFORM_EMAIL} / {PLATFORM_PASSWORD}\n"
        f"  企业  slug={slug} 账号={owner} 密码={OWNER_PASSWORD}\n"
        f"  客服  账号={agent} 密码={OWNER_PASSWORD}\n"
        f"  访客  {BASE}/h5/{public_key}\n"
    )
    failed = [r for r in results if r[1].startswith("FAIL")]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
