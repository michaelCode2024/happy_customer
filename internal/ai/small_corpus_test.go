package ai

import (
	"context"
	"github.com/google/uuid"
	"testing"
)

func TestSingleKnowledgeEntryRemainsSearchable(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()
	tenant := uuid.New()
	entry := uuid.New()
	_, err := pool.Exec(ctx, `insert into tenant(id,name,slug,status) values($1,'检索回归测试',$2,'ACTIVE')`, tenant, "search-test-"+tenant.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pool.Exec(context.Background(), `delete from tenant where id=$1`, tenant) })
	_, err = pool.Exec(ctx, `insert into knowledge_entry(id,tenant_id,title,content,question_examples,status) values($1,$2,'平台接入方式','网站可以嵌入客服组件，API Key 只放在客户后端。','如何接入客服平台？','ACTIVE')`, entry, tenant)
	if err != nil {
		t.Fatal(err)
	}
	service := NewService(pool, nil, 0.35)
	hits, err := service.Retrieve(ctx, tenant, "如何接入客服平台？")
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 || hits[0].ID != entry || hits[0].Score < 0.99 {
		t.Fatalf("single article exact example must match: %+v", hits)
	}
	other, err := service.Retrieve(ctx, uuid.New(), "如何接入客服平台？")
	if err != nil || len(other) != 0 {
		t.Fatalf("cross-tenant retrieval: %+v %v", other, err)
	}
	unrelated, err := service.Retrieve(ctx, tenant, "火星天气预报")
	if err != nil {
		t.Fatal(err)
	}
	if len(unrelated) > 0 && unrelated[0].Score >= 0.35 {
		t.Fatalf("unrelated question scored too high: %+v", unrelated)
	}
}
