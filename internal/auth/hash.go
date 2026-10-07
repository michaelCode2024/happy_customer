package auth

import "crypto/sha256"

func hashSHA256(value string) []byte {
	sum := sha256.Sum256([]byte(value))
	return sum[:]
}
