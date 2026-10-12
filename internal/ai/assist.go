package ai

import (
	"context"
	"strconv"
	"strings"

	"github.com/google/uuid"
)

// AI 助手：会话摘要、回复建议、语气改写与翻译。
//
// These run on demand from the console and never write to a conversation on
// their own. The distinction matters: an automatic answer is a commitment made
// to a customer, while a suggestion is a draft an agent chooses to send. Keeping
// the two apart is why Assist has no side effects and cannot reach the write
// path.

// Task names one assistant operation. They are a closed set because each one has
// a hand-written prompt and a hand-checked output contract; a free-form
// instruction field would turn the assistant into a general-purpose model proxy
// billed to the tenant.
type Task string

const (
	TaskSuggest    Task = "SUGGEST"
	TaskSummarize  Task = "SUMMARIZE"
	TaskSentiment  Task = "SENTIMENT"
	TaskTranslate  Task = "TRANSLATE"
	TaskPolish     Task = "POLISH"
	TaskNextAction Task = "NEXT_ACTION"
)

// AssistRequest is one assistant call.
type AssistRequest struct {
	TenantID uuid.UUID
	Task     Task
	// Question is the visitor's latest message for SUGGEST, the material to
	// compress for SUMMARIZE, and the source text for TRANSLATE and POLISH.
	Question string
	// History is the conversation so far, oldest first.
	History []Turn
	// Language is the target language for TRANSLATE. Empty means Chinese.
	Language string
	// Tone steers POLISH and SUGGEST. Empty means the platform default voice.
	Tone string
}

// AssistResult is what the console renders. Text is always present on success;
// the remaining fields are task-specific and empty when the task does not
// produce them.
type AssistResult struct {
	Task     Task     `json:"task"`
	Text     string   `json:"text"`
	Label    string   `json:"label,omitempty"`
	Score    float64  `json:"score,omitempty"`
	Sources  []string `json:"sources,omitempty"`
	Provider string   `json:"provider"`
	Usage    Usage    `json:"usage"`
}

// Assist runs one assistant task. SUGGEST is grounded in the knowledge base — a
// suggestion that ignores what the tenant documented is worse than no
// suggestion, because the agent has to fact-check it before sending. The
// remaining tasks work on text the agent already has and consult no knowledge.
func (s *Service) Assist(ctx context.Context, request AssistRequest) (AssistResult, error) {
	result := AssistResult{Task: request.Task, Provider: s.ProviderName()}
	if !s.Available() {
		return result, nil
	}
	input := strings.TrimSpace(request.Question)
	if input == "" && len(request.History) == 0 {
		return result, nil
	}

	messages := make([]Message, 0, len(request.History)+3)
	messages = append(messages, Message{Role: "system", Content: assistPrompt(request.Task, request.Tone, request.Language)})
	if request.Task == TaskSuggest {
		entries, err := s.search(ctx, request.TenantID, input, true)
		if err != nil {
			return result, err
		}
		if len(entries) > 0 {
			messages = append(messages, Message{Role: "user", Content: buildPrompt(entries)})
			result.Sources = titles(entries)
			for _, entry := range entries {
				if entry.score > result.Score {
					result.Score = entry.score
				}
			}
		}
	}
	if request.Task == TaskSummarize {
		// The transcript is passed as one block rather than as alternating
		// turns: the model is being asked to compress, not to continue, and a
		// chat-shaped prompt made it answer the last question instead.
		messages = append(messages, Message{Role: "user", Content: "对话记录：\n" + transcript(request.History)})
		if input != "" {
			messages = append(messages, Message{Role: "user", Content: "请重点说明：" + input})
		}
	} else {
		for _, turn := range request.History {
			messages = append(messages, Message{Role: turn.Role, Content: turn.Content})
		}
		if input != "" {
			messages = append(messages, Message{Role: "user", Content: input})
		}
	}

	answer, usage, err := s.provider.Generate(ctx, messages)
	result.Usage = usage
	if err != nil {
		return result, err
	}
	result.Text = strings.TrimSpace(answer)
	if request.Task == TaskSentiment {
		result.Label, result.Score = parseSentiment(result.Text)
	}
	return result, nil
}

// AssistWithTools is like Assist but uses GenerateWithTools so the model may
// call registered tools (order lookup, logistics, etc.) before producing its
// final answer. Used for SUGGEST when tools are registered.
func (s *Service) AssistWithTools(ctx context.Context, request AssistRequest) (AssistResult, error) {
	result := AssistResult{Task: request.Task, Provider: s.ProviderName()}
	if !s.Available() {
		return result, nil
	}
	input := strings.TrimSpace(request.Question)
	if input == "" && len(request.History) == 0 {
		return result, nil
	}
	if len(s.tools) == 0 {
		return s.Assist(ctx, request)
	}

	messages := make([]Message, 0, len(request.History)+3)
	messages = append(messages, Message{Role: "system", Content: assistPrompt(request.Task, request.Tone, request.Language)})
	if request.Task == TaskSuggest {
		entries, err := s.SearchHybrid(ctx, request.TenantID, input, true)
		if err != nil {
			return result, err
		}
		if len(entries) > 0 {
			messages = append(messages, Message{Role: "user", Content: buildPrompt(entries)})
			result.Sources = titles(entries)
			for _, entry := range entries {
				if entry.score > result.Score {
					result.Score = entry.score
				}
			}
		}
	}
	for _, turn := range request.History {
		messages = append(messages, Message{Role: turn.Role, Content: turn.Content})
	}
	if input != "" {
		messages = append(messages, Message{Role: "user", Content: input})
	}

	answer, usage, err := s.provider.GenerateWithTools(ctx, messages, s.tools, 3)
	result.Usage = usage
	if err != nil {
		return result, err
	}
	result.Text = strings.TrimSpace(answer)
	if request.Task == TaskSentiment {
		result.Label, result.Score = parseSentiment(result.Text)
	}
	return result, nil
}

// StreamSuggest streams a reply suggestion token by token. An agent watching the
// draft appear can start reading at the first sentence instead of waiting for
// the whole block, which is the difference between the feature being used and
// being ignored.
func (s *Service) StreamSuggest(ctx context.Context, request AssistRequest) (<-chan string, error) {
	if !s.Available() {
		return nil, nil
	}
	input := strings.TrimSpace(request.Question)
	if input == "" {
		return nil, nil
	}
	messages := []Message{{Role: "system", Content: assistPrompt(TaskSuggest, request.Tone, "")}}
	entries, err := s.SearchHybrid(ctx, request.TenantID, input, true)
	if err != nil {
		return nil, err
	}
	if len(entries) > 0 {
		messages = append(messages, Message{Role: "user", Content: buildPrompt(entries)})
	}
	for _, turn := range request.History {
		messages = append(messages, Message{Role: turn.Role, Content: turn.Content})
	}
	messages = append(messages, Message{Role: "user", Content: input})
	return s.provider.Stream(ctx, messages)
}

// transcript renders history as a labelled block. The cap is four times the
// prompt history limit because the summary is the one task where the whole
// conversation is the input, and a summariser that only saw the last four turns
// would describe the tail of an argument as the whole of it.
func transcript(history []Turn) string {
	if len(history) > maxHistoryTurns*4 {
		history = history[len(history)-maxHistoryTurns*4:]
	}
	var builder strings.Builder
	for _, turn := range history {
		if turn.Role == "user" {
			builder.WriteString("访客：")
		} else {
			builder.WriteString("客服：")
		}
		builder.WriteString(strings.TrimSpace(turn.Content))
		builder.WriteString("\n")
	}
	return builder.String()
}

// parseSentiment turns the model's one-word answer into a label and a signed
// score. Models drift into "客户情绪偏负面" or "NEGATIVE (0.8)", so the parser looks
// for the label anywhere in the line and pulls the first number it finds rather
// than insisting on an exact format it will not reliably follow.
func parseSentiment(answer string) (string, float64) {
	lowered := strings.ToLower(answer)
	label := ""
	switch {
	case strings.Contains(lowered, "negative") || strings.Contains(answer, "负面") || strings.Contains(answer, "消极"):
		label = "NEGATIVE"
	case strings.Contains(lowered, "positive") || strings.Contains(answer, "正面") || strings.Contains(answer, "积极"):
		label = "POSITIVE"
	case strings.Contains(lowered, "neutral") || strings.Contains(answer, "中性"):
		label = "NEUTRAL"
	}
	score := 0.0
	if digits := firstNumber(answer); digits != "" {
		if parsed, err := strconv.ParseFloat(digits, 64); err == nil {
			// A model that answers "80" means eighty percent, not eighty.
			if parsed > 1 {
				parsed /= 100
			}
			if parsed > 1 {
				parsed = 1
			}
			if label == "NEGATIVE" {
				parsed = -parsed
			}
			score = parsed
		}
	}
	if label == "" {
		label = "UNKNOWN"
	}
	return label, score
}

// firstNumber returns the leading numeric run of the answer. Scanning for the
// first digit rather than the first number after the label keeps this working
// for "NEGATIVE 0.8" and "情绪：负面（0.8）" alike.
func firstNumber(value string) string {
	var builder strings.Builder
	seenDigit := false
	for _, char := range value {
		if char >= '0' && char <= '9' {
			builder.WriteRune(char)
			seenDigit = true
			continue
		}
		if char == '.' && seenDigit && !strings.Contains(builder.String(), ".") {
			builder.WriteRune(char)
			continue
		}
		if seenDigit {
			break
		}
	}
	return strings.TrimSuffix(builder.String(), ".")
}

// assistPrompt is the per-task instruction. Each prompt names its output shape,
// because the alternative — asking for "a summary" — returns a summary of
// whatever number of sentences the model felt like writing.
func assistPrompt(task Task, tone, language string) string {
	voice := "简洁、专业、友好"
	if strings.TrimSpace(tone) != "" {
		voice = strings.TrimSpace(tone)
	}
	switch task {
	case TaskSuggest:
		return `你是 RelayDesk 的坐席助手。根据知识库资料和对话记录，为坐席起草一条回复。
规则：
1. 只能依据知识库资料，不要编造价格、承诺、政策或时间。
2. 语气` + voice + `，与访客使用同一种语言。
3. 直接输出可以发送的回复正文，不要写“建议回复：”之类的开头，不要使用 Markdown 标题。
4. 控制在 200 字以内，需要分点时最多 3 条。
5. 知识库资料不足以回答时，只输出：需要人工确认后回复。`
	case TaskSummarize:
		return `你是 RelayDesk 的会话摘要助手。阅读对话记录，输出摘要。
规则：
1. 先一句话说明访客的核心诉求。
2. 再列出已确认的事实、待办事项和未解决的问题，每条一行，以“- ”开头。
3. 不要评价坐席表现，不要编造对话中没有的信息。
4. 全部使用中文，控制在 200 字以内。`
	case TaskSentiment:
		return `你是情绪分析器。判断最后一条访客消息的情绪。
只输出一行，格式为：POSITIVE / NEUTRAL / NEGATIVE 加一个 0 到 1 的置信度数字。
不要输出解释、不要输出标点以外的其他内容。`
	case TaskTranslate:
		target := strings.TrimSpace(language)
		if target == "" {
			target = "中文"
		}
		return `你是翻译器。把用户提供的客服对话内容翻译成` + target + `。
规则：
1. 只输出译文，不要输出原文、注释或语言名称。
2. 保留数字、订单号、邮箱和链接原样。
3. 保持客服场景应有的礼貌用语，不要直译出冒犯性的表达。`
	case TaskPolish:
		return `你是文案润色助手。把坐席草拟的回复改写得更` + voice + `。
规则：
1. 不改变原意，不新增承诺、金额或时间。
2. 保持原文语言。
3. 只输出润色后的正文，不要解释改动。`
	case TaskNextAction:
		return `你是客服流程助手。阅读对话记录，给出坐席下一步应该做的事。
规则：
1. 只输出一条最关键的下一步动作，一句话。
2. 需要补充信息时，写成“向访客确认：……”的形式。
3. 不要重复访客已经说过的内容，不要输出多条。`
	default:
		return systemPrompt
	}
}
