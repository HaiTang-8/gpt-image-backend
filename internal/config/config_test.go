package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadYAMLConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	data := []byte(`
# 中文注释应该被 YAML 解析器忽略
addr: ":8081"
database_path: data/test.db
request_timeout: 120s
default_upstream: openai
default_chat_model: gpt-5.5
default_image_model: gpt-image-2
log:
  store_request_body: true
  store_response_body: false
  store_files: false
  file_storage_dir: data/uploads
  max_body_bytes: 2048
api_keys:
  - user_id: default
    name: Default User
    key: proxy-key
upstreams:
  - id: openai
    base_url: https://api.openai.com/v1
    api_key: upstream-key
    models:
      - gpt-*
`)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Addr != ":8081" {
		t.Fatalf("addr = %q, want :8081", cfg.Addr)
	}
	if cfg.RequestTimeout.Std() != 120*time.Second {
		t.Fatalf("request timeout = %s, want 120s", cfg.RequestTimeout.Std())
	}
	if cfg.DefaultChatModel != "gpt-5.5" {
		t.Fatalf("default chat model = %q, want gpt-5.5", cfg.DefaultChatModel)
	}
	if cfg.DefaultImageModel != "gpt-image-2" {
		t.Fatalf("default image model = %q, want gpt-image-2", cfg.DefaultImageModel)
	}
	if cfg.Log.MaxBodyBytes != 2048 {
		t.Fatalf("max body bytes = %d, want 2048", cfg.Log.MaxBodyBytes)
	}
	if got := cfg.APIKeys[0].Key; got != "proxy-key" {
		t.Fatalf("api key = %q, want proxy-key", got)
	}
}

func TestConfigAppliesDefaultModels(t *testing.T) {
	cfg := &Config{}
	cfg.applyDefaults()

	if cfg.DefaultChatModel != "gpt-5.5" {
		t.Fatalf("default chat model = %q, want gpt-5.5", cfg.DefaultChatModel)
	}
	if cfg.DefaultImageModel != "gpt-image-2" {
		t.Fatalf("default image model = %q, want gpt-image-2", cfg.DefaultImageModel)
	}
}

func TestRouteUpstreamByModel(t *testing.T) {
	cfg := &Config{
		DefaultUpstream: "fallback",
		Upstreams: []UpstreamConfig{
			{ID: "chat", Models: []string{"gpt-*"}},
			{ID: "image", Models: []string{"dall-e*", "gpt-image*"}},
			{ID: "fallback", Models: []string{"*"}},
		},
	}

	tests := []struct {
		name  string
		model string
		want  string
	}{
		{name: "chat prefix", model: "gpt-4o-mini", want: "chat"},
		{name: "image prefix", model: "gpt-image-1", want: "image"},
		{name: "fallback wildcard", model: "unknown", want: "fallback"},
		{name: "empty model", model: "", want: "fallback"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := cfg.RouteUpstream(tt.model)
			if !ok {
				t.Fatal("expected upstream")
			}
			if got.ID != tt.want {
				t.Fatalf("upstream = %q, want %q", got.ID, tt.want)
			}
		})
	}
}

func TestUserByAPIKey(t *testing.T) {
	cfg := &Config{
		APIKeys: []APIKeyConfig{{UserID: "u1", Key: "secret"}},
	}

	user, ok := cfg.UserByAPIKey("secret")
	if !ok {
		t.Fatal("expected api key match")
	}
	if user.UserID != "u1" {
		t.Fatalf("user = %q, want u1", user.UserID)
	}
	if _, ok := cfg.UserByAPIKey("bad"); ok {
		t.Fatal("unexpected api key match")
	}
}
