package ai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"
)

func TestSummaryWithRegisteredToolsUsesTranscript(t *testing.T) {
	called := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		var body struct {
			Messages []Message `json:"messages"`
			Tools    []any     `json:"tools"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if len(body.Tools) != 0 {
			t.Error("摘要不应携带业务工具")
		}
		if len(body.Messages) < 2 || !strings.Contains(body.Messages[1].Content, "对话记录：") || !strings.Contains(body.Messages[1].Content, "手机访问") {
			t.Errorf("摘要必须收到完整转录文本: %+v", body.Messages)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"客户咨询网站嵌入和手机访问。"}}]}`))
	}))
	defer upstream.Close()
	service := NewService(nil, New(Config{Provider: "compatible", BaseURL: upstream.URL, APIKey: "test", Model: "test"}), 0.35).
		WithTools(Tool{Name: "lookup", Parameters: json.RawMessage(`{"type":"object"}`)})
	result, err := service.AssistWithTools(context.Background(), AssistRequest{Task: TaskSummarize, History: []Turn{{Role: "user", Content: "手机访问"}}})
	if err != nil || !called || result.Text == "" {
		t.Fatalf("摘要失败: %+v %v", result, err)
	}
}

func TestAssistSourcesPreserveIdentityForDuplicateTitles(t *testing.T) {
	a, b := uuid.New(), uuid.New()
	got := assistSources([]knowledgeEntry{{id: a, title: "接入说明", content: "网站正文", score: 0.8}, {id: b, title: "接入说明", content: "手机正文", score: 0.6}})
	if len(got) != 2 || got[0].ID != a.String() || got[1].ID != b.String() || got[1].Content != "手机正文" {
		t.Fatalf("来源不能按同名标题合并: %+v", got)
	}
}

func TestWritingTasksUseOnlySelectedText(t *testing.T) {
	for _, task := range []Task{TaskPolish, TaskTranslate} {
		t.Run(string(task), func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body struct {
					Messages []Message `json:"messages"`
				}
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				if len(body.Messages) != 2 || body.Messages[1].Content != "我帮您核实一下" {
					t.Errorf("写作任务只能处理指定原文: %+v", body.Messages)
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"好的，我帮您核实。"}}]}`))
			}))
			defer upstream.Close()
			service := NewService(nil, New(Config{Provider: "compatible", BaseURL: upstream.URL, APIKey: "test", Model: "test"}), 0.35)
			_, err := service.Assist(context.Background(), AssistRequest{Task: task, Question: "我帮您核实一下", History: []Turn{{Role: "user", Content: "退款问题"}}})
			if err != nil {
				t.Fatal(err)
			}
		})
	}
}
