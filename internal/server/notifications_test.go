package server

import (
	"strings"
	"testing"
)

func TestPushEndpointRejectsInternalAndLookalikeHosts(t *testing.T) {
	for _, endpoint := range []string{"http://fcm.googleapis.com/send/x", "https://127.0.0.1/x", "https://localhost/x", "https://fcm.googleapis.com.attacker.example/x", "https://user@fcm.googleapis.com/x", "https://fcm.googleapis.com:8443/x", "https://fcm.googleapis.com/x#bad"} {
		if validPushEndpoint(endpoint) {
			t.Errorf("accepted unsafe endpoint %q", endpoint)
		}
	}
	for _, endpoint := range []string{"https://fcm.googleapis.com/fcm/send/x", "https://updates.push.services.mozilla.com/wpush/v2/x", "https://web.push.apple.com/x", "https://wns2.notify.windows.com/x"} {
		if !validPushEndpoint(endpoint) {
			t.Errorf("rejected supported endpoint %q", endpoint)
		}
	}
}

func TestPushNoticeShowsSenderAndMessage(t *testing.T) {
	title, body := pushNotice("MESSAGE", "张先生 发来了新消息", "张先生", "TEXT", "你好，订单到了", false)
	if title != "张先生" || body != "你好，订单到了" {
		t.Fatalf("text notice = %q / %q", title, body)
	}
	title, body = pushNotice("MESSAGE", "", "  ", "IMAGE", "现场.jpg", false)
	if title != "客户" || body != "[图片] 现场.jpg" {
		t.Fatalf("image notice = %q / %q", title, body)
	}
	title, body = pushNotice("MESSAGE", "", "李女士", "FILE", "", false)
	if title != "李女士" || body != "[文件]" {
		t.Fatalf("file notice = %q / %q", title, body)
	}
	title, body = pushNotice("MESSAGE", "", "李女士", "TEXT", "原话", true)
	if title != "李女士" || body != "消息已撤回" {
		t.Fatalf("recalled notice = %q / %q", title, body)
	}
	long := strings.Repeat("啊", 90)
	_, body = pushNotice("MESSAGE", "", "王先生", "TEXT", long, false)
	if len([]rune(body)) != 81 || !strings.HasSuffix(body, "…") {
		t.Fatalf("truncated body length=%d %q", len([]rune(body)), body)
	}
	title, body = pushNotice("ASSIGNED", "有新会话分配给你，请及时接待", "赵女士\u202e伪装", "", "", false)
	if title != "赵女士 伪装" || body != "有新会话分配给你，请及时接待" {
		t.Fatalf("assignment notice = %q / %q", title, body)
	}
}
