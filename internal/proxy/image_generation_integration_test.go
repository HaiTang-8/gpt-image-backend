//go:build integration

package proxy

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"gpt-image-backend/internal/config"
)

func TestRealImagesGeneration(t *testing.T) {
	const prompt = "生成一张中国90年代团圆饭的聚餐照片"

	configPath := os.Getenv("GPT_IMAGE_CONFIG")
	if configPath == "" {
		configPath = filepath.Join("..", "..", "config.yaml")
	}
	cfg, err := config.Load(configPath)
	if err != nil {
		t.Fatal(err)
	}
	cfg.DatabasePath = filepath.Join(t.TempDir(), "proxy.db")
	cfg.RequestTimeout = config.Duration(5 * time.Minute)

	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	body, err := json.Marshal(map[string]any{
		"prompt": prompt,
		"size":   "1024x1024",
		"n":      1,
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/images/generations", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+cfg.APIKeys[0].Key)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code < http.StatusOK || rec.Code >= http.StatusMultipleChoices {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}

	var payload struct {
		Data []struct {
			URL     string `json:"url"`
			B64JSON string `json:"b64_json"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v, body = %s", err, rec.Body.String())
	}
	if len(payload.Data) == 0 {
		t.Fatalf("response data is empty: %s", rec.Body.String())
	}
	if payload.Data[0].URL == "" && payload.Data[0].B64JSON == "" {
		t.Fatalf("first image has neither url nor b64_json: %s", rec.Body.String())
	}
	outputPath, size, err := saveGeneratedImage(payload.Data[0].B64JSON, payload.Data[0].URL)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("saved generated image to %s (%d bytes)", outputPath, size)

	row := queryLog(t, cfg.DatabasePath)
	if row.RequestSummary != prompt {
		t.Fatalf("logged prompt = %q, want %q", row.RequestSummary, prompt)
	}
	if row.Model != cfg.DefaultImageModel {
		t.Fatalf("logged model = %q, want %q", row.Model, cfg.DefaultImageModel)
	}
	if row.StatusCode < http.StatusOK || row.StatusCode >= http.StatusMultipleChoices {
		t.Fatalf("logged status = %d", row.StatusCode)
	}
}

func saveGeneratedImage(b64JSON, imageURL string) (string, int, error) {
	var data []byte
	var err error
	if b64JSON != "" {
		data, err = base64.StdEncoding.DecodeString(b64JSON)
	} else {
		data, err = downloadGeneratedImage(imageURL)
	}
	if err != nil {
		return "", 0, err
	}

	outputPath := filepath.Join("..", "..", "data", "generated", "real-image-generation.png")
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return "", 0, err
	}
	if err := os.WriteFile(outputPath, data, 0o600); err != nil {
		return "", 0, err
	}
	absolutePath, err := filepath.Abs(outputPath)
	if err != nil {
		return outputPath, len(data), nil
	}
	return absolutePath, len(data), nil
}

func downloadGeneratedImage(imageURL string) ([]byte, error) {
	resp, err := http.Get(imageURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return nil, &urlStatusError{status: resp.Status}
	}
	return io.ReadAll(resp.Body)
}

type urlStatusError struct {
	status string
}

func (e *urlStatusError) Error() string {
	return "download generated image: " + e.status
}
