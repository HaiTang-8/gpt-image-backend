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

	env := newRealImageTestEnv(t)
	result := generateRealImageResponse(t, env, prompt, "")
	outputPath, size, err := saveGeneratedImage(result.B64JSON, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("saved generated image to %s (%d bytes), response_id=%s image_generation_call_id=%s", outputPath, size, result.ResponseID, result.ImageGenerationCallID)

	row := queryLog(t, env.cfg.DatabasePath)
	if row.RequestSummary != prompt {
		t.Fatalf("logged prompt = %q, want %q", row.RequestSummary, prompt)
	}
	if row.Model != env.cfg.DefaultChatModel {
		t.Fatalf("logged model = %q, want %q", row.Model, env.cfg.DefaultChatModel)
	}
	if row.StatusCode < http.StatusOK || row.StatusCode >= http.StatusMultipleChoices {
		t.Fatalf("logged status = %d", row.StatusCode)
	}
}

func TestRealImagesConversationEditing(t *testing.T) {
	env := newRealImageTestEnv(t)
	turns := []struct {
		prompt   string
		filename string
	}{
		{"生成一张中国90年代团圆饭的聚餐照片", "conversation-01-original.png"},
		{"把人物的数量减少", "conversation-02-fewer-people.png"},
		{"人物只要男性", "conversation-03-men-only.png"},
	}

	previousB64JSON := ""
	for _, turn := range turns {
		result := generateRealImageResponse(t, env, turn.prompt, previousB64JSON)
		outputPath, size, err := saveGeneratedImageAs(result.B64JSON, "", turn.filename)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("saved %q to %s (%d bytes), response_id=%s image_generation_call_id=%s", turn.prompt, outputPath, size, result.ResponseID, result.ImageGenerationCallID)
		previousB64JSON = result.B64JSON
	}

	row := queryLog(t, env.cfg.DatabasePath)
	if row.RequestSummary != turns[len(turns)-1].prompt {
		t.Fatalf("logged prompt = %q, want %q", row.RequestSummary, turns[len(turns)-1].prompt)
	}
	if row.StatusCode < http.StatusOK || row.StatusCode >= http.StatusMultipleChoices {
		t.Fatalf("logged status = %d", row.StatusCode)
	}
}

type realImageTestEnv struct {
	cfg     *config.Config
	handler http.Handler
}

type realImageResponse struct {
	ResponseID            string
	ImageGenerationCallID string
	B64JSON               string
}

func newRealImageTestEnv(t *testing.T) realImageTestEnv {
	t.Helper()

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
	return realImageTestEnv{cfg: cfg, handler: handler}
}

func generateRealImageResponse(t *testing.T, env realImageTestEnv, prompt, previousB64JSON string) realImageResponse {
	t.Helper()
	action := "generate"
	input := any(prompt)
	if previousB64JSON != "" {
		action = "edit"
		input = []map[string]any{
			{
				"role": "user",
				"content": []map[string]any{
					{
						"type": "input_text",
						"text": prompt,
					},
					{
						"type":      "input_image",
						"image_url": "data:image/png;base64," + previousB64JSON,
					},
				},
			},
		}
	}
	payload := map[string]any{
		"input": input,
		"store": true,
		"tools": []map[string]any{{
			"type":   "image_generation",
			"model":  env.cfg.DefaultImageModel,
			"size":   "1024x1024",
			"action": action,
		}},
		"tool_choice": map[string]any{"type": "image_generation"},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+env.cfg.APIKeys[0].Key)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	env.handler.ServeHTTP(rec, req)

	if rec.Code < http.StatusOK || rec.Code >= http.StatusMultipleChoices {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}

	var responsePayload struct {
		ID     string `json:"id"`
		Output []struct {
			ID     string `json:"id"`
			Type   string `json:"type"`
			Result string `json:"result"`
		} `json:"output"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &responsePayload); err != nil {
		t.Fatalf("decode response: %v, body = %s", err, rec.Body.String())
	}
	if responsePayload.ID == "" {
		t.Fatalf("response has no id: %s", rec.Body.String())
	}
	var b64JSON string
	var imageGenerationCallID string
	for _, output := range responsePayload.Output {
		if output.Type == "image_generation_call" {
			b64JSON = output.Result
			imageGenerationCallID = output.ID
			break
		}
	}
	if b64JSON == "" {
		t.Fatalf("response has no image_generation_call.result: %s", rec.Body.String())
	}
	return realImageResponse{
		ResponseID:            responsePayload.ID,
		ImageGenerationCallID: imageGenerationCallID,
		B64JSON:               b64JSON,
	}
}

func saveGeneratedImage(b64JSON, imageURL string) (string, int, error) {
	return saveGeneratedImageAs(b64JSON, imageURL, "real-image-generation.png")
}

func saveGeneratedImageAs(b64JSON, imageURL, filename string) (string, int, error) {
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

	outputPath := filepath.Join("..", "..", "data", "generated", filename)
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
