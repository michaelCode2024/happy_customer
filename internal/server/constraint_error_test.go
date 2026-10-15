package server

import (
	"errors"
	"testing"
)

func TestUniqueViolationAllowsSuccessfulUpdate(t *testing.T) {
	if isUniqueViolation(nil) {
		t.Fatal("成功更新不能识别为唯一键冲突")
	}
	if !isUniqueViolation(errors.New("duplicate key")) {
		t.Fatal("重复键必须识别为冲突")
	}
	if isUniqueViolation(errors.New("connection closed")) {
		t.Fatal("连接错误不是唯一键冲突")
	}
}
