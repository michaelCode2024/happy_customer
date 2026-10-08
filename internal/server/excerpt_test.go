package server

import (
	"strings"
	"testing"
)

// The excerpt replaced ts_headline because that function cannot segment Chinese.
// These cases pin the behaviour it has to get right: the window lands on the
// match, the markers are balanced, and a term that overlaps another is marked
// once rather than nested.
func TestExcerptAround(t *testing.T) {
	long := "您好，这里是客服中心。我们已经收到您的反馈，正在为您查询相关信息，请您稍等片刻。" +
		"另外提醒您，加急件会在当天优先处理，无需重复提交申请，感谢您的理解与支持。"

	cases := []struct {
		name        string
		content     string
		query       string
		wantContain string
	}{
		{
			name:        "short message is returned whole with the match marked",
			content:     "补充一下，是加急件",
			query:       "加急",
			wantContain: "<<加急>>",
		},
		{
			name:        "long message is cut to a window around the match",
			content:     long,
			query:       "加急",
			wantContain: "<<加急>>",
		},
		{
			name:        "overlapping terms merge into one marked run",
			content:     "加急件已经优先安排发出了",
			query:       "加急 急件",
			wantContain: "<<加急件>>",
		},
		{
			name:        "latin query highlights the word",
			content:     "Your order A20261008 has been shipped and you can track it on the carrier site.",
			query:       "shipped",
			wantContain: "<<shipped>>",
		},
		{
			name:        "a query with no match returns a plain head",
			content:     long,
			query:       "火锅底料",
			wantContain: "您好，这里是客服中心",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			got := excerptAround(testCase.content, testCase.query)
			if !strings.Contains(got, testCase.wantContain) {
				t.Errorf("excerptAround(%q, %q)\n got %q\nwant it to contain %q", testCase.content, testCase.query, got, testCase.wantContain)
			}
		})
	}
}

// Markers must always come in pairs: an unbalanced marker renders as literal
// angle brackets in the console, which looks like corrupted data.
func TestExcerptMarkersAreBalanced(t *testing.T) {
	cases := []struct {
		content string
		query   string
	}{
		{"补充一下，是加急件", "加急"},
		{"加急件已经优先安排发出了，请放心", "加急"},
		{"aaaa bbbb cccc", "bb"},
		{"订单号 A20261008 已发出", "订单号 A20261008"},
		{"加急加急加急加急加急加急加急加急加急加急加急加急加急加急加急加急加急加急加急加急", "加急"},
		{"", "加急"},
		{"内容", ""},
		{"a", "ab"},
	}
	for _, testCase := range cases {
		got := excerptAround(testCase.content, testCase.query)
		if strings.Count(got, "<<") != strings.Count(got, ">>") {
			t.Errorf("unbalanced markers for (%q, %q): %q", testCase.content, testCase.query, got)
		}
	}
}

// An excerpt must never be longer than the content it summarises, and a long
// message must be genuinely shortened — the whole point of the window. The bound
// is measured on the text with markers stripped, since each marked run adds four
// characters of markup that say nothing about the message length.
func TestExcerptShrinksLongMessages(t *testing.T) {
	content := strings.Repeat("客服中心为您服务。", 40)
	got := excerptAround(content, "客服")
	plain := strings.NewReplacer("<<", "", ">>", "", "…", "").Replace(got)
	if len([]rune(plain)) > len([]rune(content)) {
		t.Fatalf("excerpt is longer than the content: %d runes vs %d", len([]rune(plain)), len([]rune(content)))
	}
	// One mark plus the lead and trail padding, plus the query itself.
	bound := excerptLead + excerptTrail + len([]rune("客服"))
	if len([]rune(plain)) > bound {
		t.Errorf("excerpt of a %d-rune message carried %d runes of text, want at most %d",
			len([]rune(content)), len([]rune(plain)), bound)
	}
	// A window that was actually cut has to say so.
	if !strings.Contains(got, "…") {
		t.Errorf("excerpt of a long message is not marked as truncated: %q", got)
	}
}

// A window cut through the middle of a highlighted term would show half a word
// inside markers, reading as though the message said something it did not.
func TestExcerptDoesNotCutHighlightedTerms(t *testing.T) {
	content := strings.Repeat("好", 40) + "加急件" + strings.Repeat("好", 40)
	got := excerptAround(content, "加急件")
	if !strings.Contains(got, "<<加急件>>") {
		t.Errorf("excerpt cut the highlighted term: %q", got)
	}
}

func TestExcerptTerms(t *testing.T) {
	if got := excerptTerms("加急"); len(got) != 1 || got[0] != "加急" {
		t.Errorf("excerptTerms(\"加急\") = %v, want just the query", got)
	}
	// A single character is not worth highlighting on its own; it would mark
	// almost every character of a Chinese message.
	if got := excerptTerms("的"); len(got) != 0 {
		t.Errorf("excerptTerms(\"的\") = %v, want empty", got)
	}
	if got := excerptTerms("   "); len(got) != 0 {
		t.Errorf("excerptTerms of blank input = %v, want empty", got)
	}
	// Longer windows come first, so the caller's marker pass prefers them.
	got := excerptTerms("退款流程")
	if len(got) < 3 {
		t.Fatalf("excerptTerms(\"退款流程\") = %v, want the query plus its windows", got)
	}
	if got[0] != "退款流程" {
		t.Errorf("excerptTerms put %q first, want the whole query", got[0])
	}
}
