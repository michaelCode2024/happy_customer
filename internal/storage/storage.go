package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/tongyu/tongyu/internal/config"
)

var ErrNotFound = errors.New("object not found")

// Store persists chat attachments. The local driver is the development default;
// production deployments switch to S3-compatible object storage (S3, R2, MinIO)
// by setting STORAGE_DRIVER=s3.
type Store interface {
	Save(ctx context.Context, key string, reader io.Reader, contentType string) error
	Open(ctx context.Context, key string) (io.ReadCloser, string, error)
	Delete(ctx context.Context, key string) error
}

func New(ctx context.Context, cfg config.Storage) (Store, error) {
	if cfg.Driver == "s3" {
		return newS3Store(ctx, cfg)
	}
	if err := os.MkdirAll(cfg.LocalDir, 0o750); err != nil {
		return nil, fmt.Errorf("create local storage directory: %w", err)
	}
	return &localStore{dir: cfg.LocalDir}, nil
}

type localStore struct{ dir string }

// resolve keeps every write inside the configured directory even if a caller
// passes a malicious key.
func (s *localStore) resolve(key string) (string, error) {
	clean := filepath.Clean("/" + strings.ReplaceAll(key, "\\", "/"))
	target := filepath.Join(s.dir, filepath.FromSlash(clean))
	root, err := filepath.Abs(s.dir)
	if err != nil {
		return "", err
	}
	absolute, err := filepath.Abs(target)
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(absolute, root+string(os.PathSeparator)) {
		return "", errors.New("storage key escapes the storage root")
	}
	return absolute, nil
}

func (s *localStore) Save(_ context.Context, key string, reader io.Reader, _ string) error {
	target, err := s.resolve(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o750); err != nil {
		return err
	}
	file, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = io.Copy(file, reader)
	return err
}

func (s *localStore) Open(_ context.Context, key string) (io.ReadCloser, string, error) {
	target, err := s.resolve(key)
	if err != nil {
		return nil, "", err
	}
	file, err := os.Open(target)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, "", ErrNotFound
		}
		return nil, "", err
	}
	return file, "", nil
}

func (s *localStore) Delete(_ context.Context, key string) error {
	target, err := s.resolve(key)
	if err != nil {
		return err
	}
	if err := os.Remove(target); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

type s3Store struct {
	client *s3.Client
	bucket string
}

func newS3Store(ctx context.Context, cfg config.Storage) (*s3Store, error) {
	options := []func(*awsconfig.LoadOptions) error{
		awsconfig.WithRegion(cfg.S3Region),
		awsconfig.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(
			cfg.S3AccessKeyID, cfg.S3SecretAccessKey, "")),
	}
	loaded, err := awsconfig.LoadDefaultConfig(ctx, options...)
	if err != nil {
		return nil, err
	}
	client := s3.NewFromConfig(loaded, func(o *s3.Options) {
		o.UsePathStyle = cfg.S3PathStyle
		if cfg.S3Endpoint != "" {
			o.BaseEndpoint = aws.String(cfg.S3Endpoint)
		}
	})
	return &s3Store{client: client, bucket: cfg.S3Bucket}, nil
}

func (s *s3Store) Save(ctx context.Context, key string, reader io.Reader, contentType string) error {
	_, err := s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.bucket),
		Key:         aws.String(key),
		Body:        reader,
		ContentType: aws.String(contentType),
	})
	return err
}

func (s *s3Store) Open(ctx context.Context, key string) (io.ReadCloser, string, error) {
	output, err := s.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return nil, "", err
	}
	contentType := "application/octet-stream"
	if output.ContentType != nil {
		contentType = *output.ContentType
	}
	return output.Body, contentType, nil
}

func (s *s3Store) Delete(ctx context.Context, key string) error {
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	return err
}

// BuildKey produces a tenant-scoped, collision-free object key. The original
// file name is kept only as a suffix for operator convenience.
func BuildKey(tenantID, conversationID, attachmentID, fileName string) string {
	extension := strings.ToLower(path.Ext(fileName))
	if len(extension) > 12 {
		extension = ""
	}
	return fmt.Sprintf("%s/%s/%s%s", tenantID, conversationID, attachmentID, extension)
}

const PresignTTL = 15 * time.Minute
