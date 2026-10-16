package database

import (
	"context"
	"fmt"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"strings"
)

// 首次启动创建运营账号；重启不覆盖密码，已有账号不会被部署环境变量重置。
func EnsurePlatformAdmin(ctx context.Context, pool *pgxpool.Pool, email, password string) error {
	var exists bool
	if err := pool.QueryRow(ctx, `select exists(select 1 from platform_admin)`).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return nil
	}
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" || len(password) < 8 {
		return fmt.Errorf("首次启动必须配置 PLATFORM_ADMIN_EMAIL 和至少 8 位的 PLATFORM_ADMIN_PASSWORD")
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		return err
	}
	_, err = pool.Exec(ctx, `insert into platform_admin(id,email,display_name,password_hash,role) values($1,$2,'超级管理员',$3,'SUPER_ADMIN') on conflict do nothing`, uuid.New(), email, hash)
	return err
}
