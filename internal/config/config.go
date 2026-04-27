package config

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Addr              string           `yaml:"addr"`
	DatabasePath      string           `yaml:"database_path"`
	RequestTimeout    Duration         `yaml:"request_timeout"`
	DefaultUpstream   string           `yaml:"default_upstream"`
	DefaultChatModel  string           `yaml:"default_chat_model"`
	DefaultImageModel string           `yaml:"default_image_model"`
	Log               LogConfig        `yaml:"log"`
	APIKeys           []APIKeyConfig   `yaml:"api_keys"`
	Upstreams         []UpstreamConfig `yaml:"upstreams"`
}

type Duration time.Duration

func (d *Duration) UnmarshalYAML(value *yaml.Node) error {
	raw := value.Value
	if raw == "" {
		*d = Duration(0)
		return nil
	}
	parsed, err := time.ParseDuration(raw)
	if err != nil {
		return err
	}
	*d = Duration(parsed)
	return nil
}

func (d Duration) Std() time.Duration {
	return time.Duration(d)
}

type LogConfig struct {
	StoreRequestBody  bool   `yaml:"store_request_body"`
	StoreResponseBody bool   `yaml:"store_response_body"`
	StoreFiles        bool   `yaml:"store_files"`
	FileStorageDir    string `yaml:"file_storage_dir"`
	MaxBodyBytes      int64  `yaml:"max_body_bytes"`
}

type APIKeyConfig struct {
	UserID string `yaml:"user_id"`
	Name   string `yaml:"name"`
	Key    string `yaml:"key"`
}

type UpstreamConfig struct {
	ID      string   `yaml:"id"`
	BaseURL string   `yaml:"base_url"`
	APIKey  string   `yaml:"api_key"`
	Models  []string `yaml:"models"`
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	cfg.applyDefaults()
	return &cfg, cfg.Validate()
}

func (c *Config) applyDefaults() {
	if c.Addr == "" {
		c.Addr = ":8080"
	}
	if c.DatabasePath == "" {
		c.DatabasePath = "data/proxy.db"
	}
	if c.RequestTimeout.Std() == 0 {
		c.RequestTimeout = Duration(2 * time.Minute)
	}
	if c.DefaultChatModel == "" {
		c.DefaultChatModel = "gpt-5.5"
	}
	if c.DefaultImageModel == "" {
		c.DefaultImageModel = "gpt-image-2"
	}
	if c.Log.MaxBodyBytes == 0 {
		c.Log.MaxBodyBytes = 1 << 20
	}
}

func (c *Config) Validate() error {
	if len(c.APIKeys) == 0 {
		return errors.New("at least one api key is required")
	}
	if len(c.Upstreams) == 0 {
		return errors.New("at least one upstream is required")
	}
	seenUsers := map[string]struct{}{}
	for i, key := range c.APIKeys {
		if key.UserID == "" {
			return fmt.Errorf("api_keys[%d].user_id is required", i)
		}
		if key.Key == "" {
			return fmt.Errorf("api_keys[%d].key is required", i)
		}
		if _, ok := seenUsers[key.UserID]; ok {
			return fmt.Errorf("duplicate user_id %q", key.UserID)
		}
		seenUsers[key.UserID] = struct{}{}
	}
	seenUpstreams := map[string]struct{}{}
	for i, upstream := range c.Upstreams {
		if upstream.ID == "" {
			return fmt.Errorf("upstreams[%d].id is required", i)
		}
		if _, ok := seenUpstreams[upstream.ID]; ok {
			return fmt.Errorf("duplicate upstream id %q", upstream.ID)
		}
		seenUpstreams[upstream.ID] = struct{}{}
		if upstream.BaseURL == "" {
			return fmt.Errorf("upstreams[%d].base_url is required", i)
		}
		parsed, err := url.Parse(upstream.BaseURL)
		if err != nil || parsed.Scheme == "" || parsed.Host == "" {
			return fmt.Errorf("upstreams[%d].base_url must be absolute", i)
		}
		if upstream.APIKey == "" {
			return fmt.Errorf("upstreams[%d].api_key is required", i)
		}
	}
	if c.DefaultUpstream != "" {
		if _, ok := seenUpstreams[c.DefaultUpstream]; !ok {
			return fmt.Errorf("default_upstream %q not found", c.DefaultUpstream)
		}
	}
	if c.Log.StoreFiles && c.Log.FileStorageDir == "" {
		return errors.New("log.file_storage_dir is required when log.store_files is true")
	}
	return nil
}

func (c *Config) HashAPIKey(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func (c *Config) UserByAPIKey(raw string) (APIKeyConfig, bool) {
	hash := c.HashAPIKey(raw)
	for _, key := range c.APIKeys {
		if c.HashAPIKey(key.Key) == hash {
			return key, true
		}
	}
	return APIKeyConfig{}, false
}

func (c *Config) RouteUpstream(model string) (UpstreamConfig, bool) {
	if model != "" {
		var best UpstreamConfig
		bestLen := -1
		for _, upstream := range c.Upstreams {
			for _, pattern := range upstream.Models {
				score, matched := modelMatchScore(pattern, model)
				if matched && score > bestLen {
					best = upstream
					bestLen = score
				}
				if matched && score == exactMatchScore {
					return upstream, true
				}
			}
		}
		if bestLen >= 0 {
			return best, true
		}
	}
	if c.DefaultUpstream != "" {
		for _, upstream := range c.Upstreams {
			if upstream.ID == c.DefaultUpstream {
				return upstream, true
			}
		}
	}
	if len(c.Upstreams) > 0 {
		return c.Upstreams[0], true
	}
	return UpstreamConfig{}, false
}

const exactMatchScore = 1 << 30

func modelMatchScore(pattern, model string) (int, bool) {
	if pattern == "*" {
		return 0, true
	}
	if strings.HasSuffix(pattern, "*") {
		prefix := strings.TrimSuffix(pattern, "*")
		return len(prefix), strings.HasPrefix(model, prefix)
	}
	if pattern == model {
		return exactMatchScore, true
	}
	return 0, false
}
