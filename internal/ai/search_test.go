package ai

import (
	"reflect"
	"testing"
)

// The Go mirror of relaydesk_terms has to agree with the SQL function exactly:
// the overlap test on question_examples is only meaningful if both sides cut the
// text the same way. The expected values below are the real output of
// relaydesk_terms in PostgreSQL 18, transcribed rather than derived, so this
// test fails if either implementation drifts.
func TestTermsMatchTheDatabaseTokenizer(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  []string
	}{
		{
			name:  "chinese sentence yields characters and bigrams",
			input: "补充一下，是加急件",
			// Ordered by position, then the shorter term first, then text —
			// the full order the SQL aggregate produces.
			want: []string{
				"补", "补充", "充", "充一", "一", "一下", "下",
				"是", "是加", "加", "加急", "急", "急件", "件",
			},
		},
		{
			name:  "latin words stay whole and lowercase",
			input: "How do I get a Refund?",
			want:  []string{"do", "get", "how", "refund"},
		},
		{
			name:  "mixed script keeps both",
			input: "订单号 A20261008",
			want:  []string{"a20261008", "订", "订单", "单", "单号", "号"},
		},
		{
			name:  "punctuation alone has nothing to search for",
			input: "!@# $%",
			want:  nil,
		},
		{
			name:  "single ideograph is searchable on its own",
			input: "好",
			want:  []string{"好"},
		},
		{
			name:  "single latin character is dropped",
			input: "a",
			want:  nil,
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			got := terms(testCase.input)
			if !reflect.DeepEqual(got, testCase.want) {
				t.Errorf("terms(%q)\n got %v\nwant %v", testCase.input, got, testCase.want)
			}
		})
	}
}

func TestTermsAreDeduplicated(t *testing.T) {
	// "订单订单" contains the distinct terms 订(1), 订单(1), 单(2), 单订(2). The
	// repeat of 订单 must not appear twice: a repeated word does not deserve a
	// second slot in the vector, and duplicates would eat into the 4000-term cap.
	want := []string{"订", "订单", "单", "单订"}
	if got := terms("订单订单"); !reflect.DeepEqual(got, want) {
		t.Errorf("terms(\"订单订单\") = %v, want %v", got, want)
	}
}

func TestTermsAreBounded(t *testing.T) {
	// A 6000-character run of one ideograph has only two distinct terms, so the
	// cap does not bite. What must hold is that neither the count nor the memory
	// grows with the input.
	long := make([]rune, 0, 6000)
	for index := 0; index < 6000; index++ {
		long = append(long, '客')
	}
	if got := terms(string(long)); len(got) != 2 {
		t.Errorf("terms of a 6000-character run returned %d terms (%v), want 2", len(got), got)
	}

	// Distinct characters, one per position, is where the cap applies: 5000
	// different ideographs yield 5000 characters plus 4999 bigrams.
	var varied []rune
	for r := rune(0x4E00); r < 0x4E00+5000; r++ {
		varied = append(varied, r)
	}
	if got := terms(string(varied)); len(got) != 4000 {
		t.Errorf("terms of 5000 distinct characters returned %d terms, want the 4000 cap", len(got))
	}
}

func TestBlankQuestionRetrievesNothing(t *testing.T) {
	// A question with no searchable terms must not reach the database at all:
	// an empty tsquery matches nothing, and running it would be a wasted scan.
	if got := terms("   "); len(got) != 0 {
		t.Fatalf("terms of blank input = %v, want empty", got)
	}
}
