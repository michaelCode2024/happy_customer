# -*- coding: utf-8 -*-
from pathlib import Path


def main() -> None:
    auto = Path("internal/server/automation.go")
    t = auto.read_text(encoding="utf-8")
    t2 = t.replace("聊桥助手", "通语助手")
    if t2 != t:
        auto.write_text(t2, encoding="utf-8")
        print("automation.go: 聊桥助手 -> 通语助手")
    else:
        print("automation.go: unchanged")

    demo = Path("internal/platform/database/demo.go")
    # 若上次写入损坏，从 git 恢复再替换
    raw = demo.read_bytes()
    text = None
    for enc in ("utf-8", "utf-8-sig", "gbk"):
        try:
            cand = raw.decode(enc)
        except UnicodeDecodeError:
            continue
        if "演示企业" in cand or "demo" in cand and "welcome:" in cand:
            text = cand
            print("demo.go decoded as", enc)
            break
    if text is None:
        raise SystemExit("demo.go unreadable")

    # 统一品牌
    for old in ("连语", "聊桥"):
        text = text.replace(old, "通语")
    demo.write_text(text, encoding="utf-8")
    print("demo.go 通语 count", text.count("通语"))


if __name__ == "__main__":
    main()
