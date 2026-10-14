package ai

import (
	"context"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/relaydesk/relaydesk/internal/platform/database"
)

// Retrieval ranking is only meaningful as a distribution: a formula that puts
// the right article first for one hand-picked question but scores everything the
// same is exactly the defect being fixed. These tests need the real tokenizer
// and the real knowledge base, so they run against the database and skip when
// there is none. Set RELAYDESK_TEST_DATABASE to the application's DATABASE_URL.
//
// The demo tenant's knowledge base is the fixture: nine English-free articles
// covering a support team's recurring questions, which is the shape of a real
// tenant's base and therefore the honest thing to calibrate on.
var demoKnowledgeTenant = database.DemoTenantID().String()

func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("RELAYDESK_TEST_DATABASE")
	if url == "" {
		t.Skip("RELAYDESK_TEST_DATABASE is not set; skipping database-backed retrieval tests")
	}
	pool, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	if err = database.Migrate(context.Background(), pool); err != nil {
		t.Fatal(err)
	}
	if err = database.EnsureDemoData(context.Background(), pool); err != nil {
		t.Fatal(err)
	}
	return pool
}

// TestGoTermsMatchDatabaseTokenizer checks the Go mirror against the SQL
// function rather than against a transcription of it. If the two ever disagree,
// the array-overlap tests elsewhere and this one fail together, which is the
// signal that the tokenizer changed and both sides need updating.
func TestGoTermsMatchDatabaseTokenizer(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()
	inputs := []string{
		"补充一下，是加急件",
		"How do I get a Refund?",
		"订单号 A20261008",
		"!@# $%",
		"好",
		"a",
		"订单订单",
		"客服中心为您服务。加急件会在当天优先处理。",
	}
	for _, input := range inputs {
		var fromDatabase []string
		if err := pool.QueryRow(ctx, `select relaydesk_terms($1)::text[]`, input).Scan(&fromDatabase); err != nil {
			t.Fatalf("relaydesk_terms(%q): %v", input, err)
		}
		got := terms(input)
		if len(got) != len(fromDatabase) {
			t.Errorf("terms(%q) returned %d terms, the database returned %d\n got %v\nwant %v",
				input, len(got), len(fromDatabase), got, fromDatabase)
			continue
		}
		for index := range got {
			if got[index] != fromDatabase[index] {
				t.Errorf("terms(%q)[%d] = %q, the database says %q", input, index, got[index], fromDatabase[index])
				break
			}
		}
	}
}

// TestRetrievalSeparatesAnswerableFromUnrelated is the calibration that justifies
// the confidence threshold. Ask each article about itself and every score must
// clear the cut; ask questions the knowledge base was never written to answer and
// none may.
func TestRetrievalSeparatesAnswerableFromUnrelated(t *testing.T) {
	pool := testPool(t)
	service := NewService(pool, nil, 0.35)
	ctx := context.Background()
	tenant := uuid.MustParse(demoKnowledgeTenant)

	var titles []string
	rows, err := pool.Query(ctx,
		`select title from knowledge_entry where tenant_id = $1 and status = 'ACTIVE' order by title`, tenant)
	if err != nil {
		t.Fatalf("list articles: %v", err)
	}
	for rows.Next() {
		var title string
		if err := rows.Scan(&title); err != nil {
			t.Fatalf("scan title: %v", err)
		}
		titles = append(titles, title)
	}
	rows.Close()
	if len(titles) == 0 {
		t.Skip("no active knowledge entries for the demo tenant")
	}

	for _, title := range titles {
		hits, err := service.Retrieve(ctx, tenant, title)
		if err != nil {
			t.Fatalf("retrieve %q: %v", title, err)
		}
		if len(hits) == 0 {
			t.Errorf("asking about %q retrieved nothing at all", title)
			continue
		}
		if hits[0].Title != title {
			t.Errorf("asking about %q retrieved %q first (score %.3f)", title, hits[0].Title, hits[0].Score)
		}
		if hits[0].Score < 0.35 {
			t.Errorf("asking about %q scored only %.3f, below the confidence threshold, so the bot would stay silent", title, hits[0].Score)
		}
	}

	unanswerable := []string{"退款怎么处理", "火锅底料怎么吃", "订单发货了没有", "今天天气怎么样", "发票怎么开", "我要投诉", "在吗"}
	for _, question := range unanswerable {
		hits, err := service.Retrieve(ctx, tenant, question)
		if err != nil {
			t.Fatalf("retrieve %q: %v", question, err)
		}
		if len(hits) > 0 && hits[0].Score >= 0.35 {
			t.Errorf("%q scored %.3f against %q, above the threshold, so the bot would answer from an article that does not address it",
				question, hits[0].Score, hits[0].Title)
		}
	}
}

// TestUnanswerableQuestionStillRetrievesSomething guards the console preview.
// An operator asking "what would the bot see for this?" needs to see the near
// misses too — that is how a missing article is identified — so retrieval keeps
// its low-scoring hits and only the answer gate applies the threshold.
func TestUnanswerableQuestionStillRetrievesSomething(t *testing.T) {
	pool := testPool(t)
	service := NewService(pool, nil, 0.35)
	hits, err := service.Retrieve(context.Background(), uuid.MustParse(demoKnowledgeTenant), "发票怎么开")
	if err != nil {
		t.Fatalf("retrieve: %v", err)
	}
	if len(hits) == 0 {
		t.Fatal("an off-topic question retrieved nothing, so an operator cannot see why the bot declined")
	}
	for _, hit := range hits {
		if hit.Score < 0 || hit.Score > 1 {
			t.Errorf("coverage score %v for %q is outside 0..1", hit.Score, hit.Title)
		}
	}
}
