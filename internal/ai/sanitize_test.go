package ai

import "testing"

func TestSanitizeText(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{"empty stays empty", "", ""},
		{"clean cjk and latin unchanged", "如您希望联系人工客服，可继续在输入框中描述您的诉求。Hi 123 !?，。", "如您希望联系人工客服，可继续在输入框中描述您的诉求。Hi 123 !?，。"},
		{"emoji kept", "好的，已为您处理 \U0001F60A 谢谢", "好的，已为您处理 \U0001F60A 谢谢"},
		{"replacement char dropped", "情\ufffd绪", "情绪"},
		{"pua dropped", "在\uE000\uE001中描述", "在中描述"},
		{"supplementary pua dropped", "x\U000F0000y", "xy"},
		{"c0 control dropped, keepers kept", "a\x00b\x01c\td\ne\rf", "abc\td\ne\rf"},
		{"c1 control dropped", "q\x7f\x80\x9fr", "qr"},
		{"mixed mess cleaned", "在\ufffd\uE005描述\x01情\uE005绪 \U0001F60A", "在描述情绪 \U0001F60A"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := SanitizeText(tc.in); got != tc.want {
				t.Fatalf("SanitizeText(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestSanitizeTextNoOpOnCleanString(t *testing.T) {
	s := "正常内容 normal 123 😀"
	if got := SanitizeText(s); got != s {
		t.Fatalf("clean string mutated: %q", got)
	}
}
