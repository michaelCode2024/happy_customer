# SDK 与代码生成

版本 **v1** · 更新日期 **2026-11-02** · 适用服务端 **TongYu 主线**

通语**不发布手写的多语言 SDK**。接口仍在演进，手写实现一旦落后于文档，读者拿到的是过时的调用方式。取而代之：用 `/docs/openapi.json` 生成客户端，官方只维护一份可直接复制的 Go 最小客户端（见下文），覆盖鉴权、错误解析、退避重试与幂等。

## 从 OpenAPI 生成客户端

规范随服务端发布，与本文同源，不需要另找地址。

```bash
# 1. 下载规范
curl -o openapi.json https://chat.example.com/docs/openapi.json

# 2. 生成客户端，换语言只换 -g
npx @openapitools/openapi-generator-cli generate \
  -i openapi.json -g go -o ./tongyu-client

# 3. 只要 TypeScript 类型，不要运行时
npx openapi-typescript openapi.json -o tongyu.d.ts
```

`-g` 可选的常用值：`go`、`typescript-fetch`、`python`、`java`、`csharp-netcore`、`php`。生成物是普通代码，纳入你自己的仓库，按自己的规范改。

## 注入鉴权

生成的客户端都留了默认 header 的入口。把 `X-TongYu-Key` 放在这一层，不要逐个接口传，也不要写进前端代码。

```go
cfg := client.NewConfiguration()
cfg.Servers = client.ServerConfigurations{{URL: "https://chat.example.com"}}
cfg.AddDefaultHeader("X-TongYu-Key", os.Getenv("TONGYU_KEY"))
api := client.NewAPIClient(cfg)
```

```ts
// 以 openapi-generator -g typescript-fetch 的生成为例
import { Configuration, DefaultApi } from './tongyu-client';

const api = new DefaultApi(new Configuration({
  basePath: 'https://chat.example.com',
  headers: { 'X-TongYu-Key': process.env.TONGYU_KEY! }
}));
```

```python
# 以 openapi-generator -g python -p packageName=tongyu 的生成为例
import os, tongyu

configuration = tongyu.Configuration(host="https://chat.example.com")
configuration.api_key["X-TongYu-Key"] = os.environ["TONGYU_KEY"]

with tongyu.ApiClient(configuration) as api:
    me = tongyu.DefaultApi(api).me()
```

生成的类名由生成器和 `-p` 参数决定，上面的 `DefaultApi`、`tongyu` 是默认值；改了包名或标签就换成自己的。

## 手写最小 Go 客户端

不需要生成器时，这份代码足够开始联调。它做了四件事：统一鉴权、把失败响应解析成 `*Error`、对 `429` 与 `5xx` 按 `Retry-After` 退避、每次重试都重建请求体。

```go
package tongyu

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

// Error 是失败响应的公共结构。code 只在鉴权、限流、套餐和业务冲突类错误中出现，
// 参数校验与资源不存在只回 status 与 message，所以判断时两种结构都要兼容。
type Error struct {
	Status  int    `json:"status"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("tongyu: %d %s: %s", e.Status, e.Code, e.Message)
	}
	return fmt.Sprintf("tongyu: %d %s", e.Status, e.Message)
}

type Client struct {
	BaseURL string
	Key     string
	HTTP    *http.Client
}

func New(baseURL, key string) *Client {
	return &Client{BaseURL: baseURL, Key: key, HTTP: &http.Client{Timeout: 15 * time.Second}}
}

type Me struct {
	TenantID          string   `json:"tenantId"`
	Tenant            string   `json:"tenant"`
	KeyName           string   `json:"keyName"`
	Scopes            []string `json:"scopes"`
	OpenConversations int      `json:"openConversations"`
}

func (c *Client) Me(ctx context.Context) (Me, error) {
	var out Me
	err := c.do(ctx, http.MethodGet, "/api/v1/open/me", nil, &out)
	return out, err
}

func (c *Client) do(ctx context.Context, method, path string, in, out any) error {
	var payload []byte
	if in != nil {
		var err error
		if payload, err = json.Marshal(in); err != nil {
			return err
		}
	}
	for attempt := 0; ; attempt++ {
		var body io.Reader
		if payload != nil {
			// 每次重试都要新的 reader，否则第二次请求体为空。
			body = bytes.NewReader(payload)
		}
		req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, body)
		if err != nil {
			return err
		}
		req.Header.Set("X-TongYu-Key", c.Key)
		if payload != nil {
			req.Header.Set("Content-Type", "application/json")
		}

		resp, err := c.HTTP.Do(req)
		if err != nil {
			return err
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		if resp.StatusCode < 300 {
			if out == nil || len(raw) == 0 {
				return nil
			}
			return json.Unmarshal(raw, out)
		}

		apiErr := &Error{Status: resp.StatusCode}
		_ = json.Unmarshal(raw, apiErr)
		if apiErr.Message == "" {
			apiErr.Message = http.StatusText(resp.StatusCode)
		}
		// 只有限流与服务端错误值得退避；400、401、403、404、409 重试也不会变好。
		retryable := resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500
		if !retryable || attempt >= 2 {
			return apiErr
		}
		wait := time.Duration(1<<attempt) * time.Second
		if ra := resp.Header.Get("Retry-After"); ra != "" {
			if secs, err := strconv.Atoi(ra); err == nil {
				wait = time.Duration(secs) * time.Second
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
}
```

调用侧只关心业务错误码：

```go
c := tongyu.New("https://chat.example.com", os.Getenv("TONGYU_KEY"))

me, err := c.Me(ctx)
var apiErr *tongyu.Error
switch {
case err == nil:
	log.Printf("已连接 %s，未结束会话 %d", me.Tenant, me.OpenConversations)
case errors.As(err, &apiErr) && apiErr.Code == "SCOPE_REQUIRED":
	log.Fatal("密钥缺少 write 权限，请到控制台补权限")
case errors.As(err, &apiErr) && apiErr.Code == "API_KEY_INVALID":
	log.Fatal("密钥无效，检查是否混入了 Webhook 签名密钥")
default:
	log.Fatal(err)
}
```

## 重试与幂等

重试能不能用，取决于接口本身，不是取决于客户端。

| 操作 | 能否直接重试 | 依据 |
| --- | --- | --- |
| 查询类（`GET`） | 可以 | 无副作用 |
| 代发消息 | 可以，但**必须复用同一个 `clientMessageId`** | 同键同内容返回首次那条消息；同键不同内容返回 `403 MESSAGE_ID_CONFLICT` |
| 新建会话 | **不可以** | 每次调用都产生新会话，重试会多出一个 |
| 更新会话状态、标签 | 可以 | 目标状态幂等 |
| 创建群、加成员 | 不可以 | 重复调用会因成员已存在而失败，先查询再决定 |

新建会话要重试时，先查该访客的未结束会话，命中就复用，没有再建。不要用 `clientMessageId` 去兜新建会话——它只在单个会话内唯一。

## 升级时怎么办

1. 重新下载 `openapi.json`，与仓库里的旧版做 diff，只看自己实际调用的 `paths`。
2. 重新生成客户端，编译一遍；生成物的字段名变化会直接暴露出来。
3. 主版本升级至少并行 90 天，节奏见[变更记录](changelog.md)。
4. 客户端必须忽略未知响应字段——新增字段属于允许的变更。
