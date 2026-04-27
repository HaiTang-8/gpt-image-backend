package proxy

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"gpt-image-backend/internal/config"
	"gpt-image-backend/internal/store"
)

func TestChatCompletionsProxyAndLog(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer upstream-key" {
			t.Fatalf("authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"resp","usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}`))
	}))
	defer upstream.Close()

	cfg := testConfig(t, upstream.URL+"/v1")
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	body := `{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer proxy-key")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}

	row := queryLog(t, cfg.DatabasePath)
	if row.UserID != "u1" {
		t.Fatalf("user_id = %q", row.UserID)
	}
	if row.Model != "gpt-4o-mini" {
		t.Fatalf("model = %q", row.Model)
	}
	if row.UpstreamID != "openai" {
		t.Fatalf("upstream = %q", row.UpstreamID)
	}
	if row.RequestSummary != "hello" {
		t.Fatalf("summary = %q", row.RequestSummary)
	}
	if row.StatusCode != http.StatusOK {
		t.Fatalf("logged status = %d", row.StatusCode)
	}
	if !strings.Contains(row.UsageJSON, `"total_tokens":5`) {
		t.Fatalf("usage_json = %q", row.UsageJSON)
	}
}

func TestChatCompletionsAddsDefaultModel(t *testing.T) {
	wantModel := "gpt-5.5"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if got := payload["model"]; got != wantModel {
			t.Fatalf("model = %q, want %q", got, wantModel)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"resp"}`))
	}))
	defer upstream.Close()

	cfg := testConfig(t, upstream.URL+"/v1")
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	body := `{"messages":[{"role":"user","content":"hello"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer proxy-key")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	row := queryLog(t, cfg.DatabasePath)
	if row.Model != wantModel {
		t.Fatalf("logged model = %q, want %q", row.Model, wantModel)
	}
}

func TestResponsesAddsDefaultModelAndLogsInput(t *testing.T) {
	wantModel := "gpt-5.5"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/responses" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if got := payload["model"]; got != wantModel {
			t.Fatalf("model = %q, want %q", got, wantModel)
		}
		tools, ok := payload["tools"].([]any)
		if !ok || len(tools) != 1 {
			t.Fatalf("tools = %#v", payload["tools"])
		}
		tool, ok := tools[0].(map[string]any)
		if !ok {
			t.Fatalf("tool = %#v", tools[0])
		}
		if got := tool["model"]; got != "gpt-image-2" {
			t.Fatalf("tool model = %q, want gpt-image-2", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"resp","output":[],"usage":{"total_tokens":1}}`))
	}))
	defer upstream.Close()

	cfg := testConfig(t, upstream.URL+"/v1")
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	body := `{"input":"paint","tools":[{"type":"image_generation","model":"gpt-image-2","size":"1024x1024"}],"tool_choice":{"type":"image_generation"}}`
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer proxy-key")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	row := queryLog(t, cfg.DatabasePath)
	if row.Model != wantModel {
		t.Fatalf("logged model = %q, want %q", row.Model, wantModel)
	}
	if row.UpstreamID != "openai" {
		t.Fatalf("upstream = %q", row.UpstreamID)
	}
	if row.RequestSummary != "paint" {
		t.Fatalf("summary = %q", row.RequestSummary)
	}
	if !strings.Contains(row.UsageJSON, `"total_tokens":1`) {
		t.Fatalf("usage_json = %q", row.UsageJSON)
	}
}

func TestChatCompletionsStoresResponseBodyWhenEnabled(t *testing.T) {
	responseBody := `{"id":"resp","choices":[{"message":{"content":"hello"}}]}`
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(responseBody))
	}))
	defer upstream.Close()

	cfg := testConfig(t, upstream.URL+"/v1")
	cfg.Log.StoreResponseBody = true
	cfg.Log.MaxBodyBytes = 24
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	body := `{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer proxy-key")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	row := queryLog(t, cfg.DatabasePath)
	if row.ResponseJSON != responseBody[:24] {
		t.Fatalf("response_json = %q, want %q", row.ResponseJSON, responseBody[:24])
	}
}

func TestImagesGenerationAddsDefaultModel(t *testing.T) {
	wantModel := "gpt-image-2"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/images/generations" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		var payload map[string]any
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if got := payload["model"]; got != wantModel {
			t.Fatalf("model = %q, want %q", got, wantModel)
		}
		if got := payload["size"]; got != "1024x1536" {
			t.Fatalf("size = %q, want 1024x1536", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"created":1,"data":[]}`))
	}))
	defer upstream.Close()

	cfg := testConfig(t, upstream.URL+"/v1")
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	body := `{"prompt":"paint","size":"1024x1536"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/images/generations", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer proxy-key")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	row := queryLog(t, cfg.DatabasePath)
	if row.Model != wantModel {
		t.Fatalf("logged model = %q, want %q", row.Model, wantModel)
	}
	if row.UpstreamID != "images" {
		t.Fatalf("upstream = %q", row.UpstreamID)
	}
}

func TestImagesEditMultipartLogsFile(t *testing.T) {
	wantModel := "gpt-image-2"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/images/edits" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Fatal(err)
		}
		if got := r.FormValue("model"); got != wantModel {
			t.Fatalf("model = %q, want %q", got, wantModel)
		}
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"created":1,"data":[]}`))
	}))
	defer upstream.Close()

	cfg := testConfig(t, upstream.URL+"/v1")
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("prompt", "make it brighter")
	part, err := writer.CreateFormFile("image", "input.png")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write([]byte("fake-image"))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/images/edits", &body)
	req.Header.Set("Authorization", "Bearer proxy-key")
	req.Header.Set("Content-Type", writer.FormDataContentType())
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}

	logRow := queryLog(t, cfg.DatabasePath)
	if logRow.RequestSummary != "make it brighter" {
		t.Fatalf("summary = %q", logRow.RequestSummary)
	}
	files := queryFiles(t, cfg.DatabasePath)
	if len(files) != 1 {
		t.Fatalf("files = %d, want 1", len(files))
	}
	if files[0].Filename != "input.png" {
		t.Fatalf("filename = %q", files[0].Filename)
	}
	if files[0].SizeBytes != int64(len("fake-image")) {
		t.Fatalf("size = %d", files[0].SizeBytes)
	}
}

func TestInvalidAuthenticatedJSONIsLogged(t *testing.T) {
	upstream := httptest.NewServer(http.NotFoundHandler())
	defer upstream.Close()

	cfg := testConfig(t, upstream.URL+"/v1")
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{bad`))
	req.Header.Set("Authorization", "Bearer proxy-key")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	row := queryLog(t, cfg.DatabasePath)
	if row.StatusCode != http.StatusBadRequest {
		t.Fatalf("logged status = %d", row.StatusCode)
	}
	if row.Error != "invalid json request" {
		t.Fatalf("logged error = %q", row.Error)
	}
}

func TestAuthTestRequiresValidAPIKey(t *testing.T) {
	cfg := testConfig(t, "http://example.com/v1")
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	tests := []struct {
		name       string
		headerName string
		header     string
		want       int
		body       string
	}{
		{name: "missing", want: http.StatusUnauthorized, body: "unauthorized\n"},
		{name: "invalid", headerName: "Authorization", header: "Bearer wrong-key", want: http.StatusUnauthorized, body: "unauthorized\n"},
		{name: "bearer", headerName: "Authorization", header: "Bearer proxy-key", want: http.StatusOK, body: "ok"},
		{name: "api key", headerName: "X-API-Key", header: "proxy-key", want: http.StatusOK, body: "ok"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/v1/auth/test", nil)
			if tt.headerName != "" {
				req.Header.Set(tt.headerName, tt.header)
			}
			rec := httptest.NewRecorder()

			handler.ServeHTTP(rec, req)

			if rec.Code != tt.want {
				t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
			}
			if rec.Body.String() != tt.body {
				t.Fatalf("body = %q, want %q", rec.Body.String(), tt.body)
			}
		})
	}
}

func TestAdminIndexServed(t *testing.T) {
	cfg := testConfig(t, "http://example.com/v1")
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	req := httptest.NewRequest(http.MethodGet, "/admin/", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "Proxy 日志控制台") {
		t.Fatalf("admin page missing title")
	}
}

func TestAdminLogsRequireAuth(t *testing.T) {
	cfg := testConfig(t, "http://example.com/v1")
	db := testStore(t, cfg)
	handler := New(cfg, db, http.DefaultTransport)

	req := httptest.NewRequest(http.MethodGet, "/admin/api/logs", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
}

func TestAdminLogsAuthorized(t *testing.T) {
	cfg := testConfig(t, "http://example.com/v1")
	db := testStore(t, cfg)
	if err := db.SaveRequestLog(context.Background(), store.RequestLog{
		ID:             "req-admin-1",
		UserID:         "u1",
		Endpoint:       "/v1/chat/completions",
		Method:         http.MethodPost,
		Model:          "gpt-5.5",
		UpstreamID:     "openai",
		RequestSummary: "hello admin",
		RequestJSON:    `{"model":"gpt-5.5"}`,
		StatusCode:     http.StatusOK,
		DurationMS:     123,
		UsageJSON:      `{"total_tokens":7}`,
		ResponseSize:   42,
		Files: []store.FileMeta{{
			FieldName:   "image",
			Filename:    "input.png",
			ContentType: "image/png",
			SizeBytes:   9,
			SHA256:      "abc",
		}},
	}); err != nil {
		t.Fatal(err)
	}
	handler := New(cfg, db, http.DefaultTransport)

	req := httptest.NewRequest(http.MethodGet, "/admin/api/logs?q=hello", nil)
	req.Header.Set("Authorization", "Bearer proxy-key")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var result store.RequestLogList
	if err := json.NewDecoder(rec.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if result.Total != 1 || len(result.Items) != 1 {
		t.Fatalf("logs total = %d, items = %d", result.Total, len(result.Items))
	}
	if result.Items[0].ID != "req-admin-1" {
		t.Fatalf("id = %q", result.Items[0].ID)
	}
	if len(result.Items[0].Files) != 1 {
		t.Fatalf("files = %d, want 1", len(result.Items[0].Files))
	}
}

func TestAdminStatsAuthorized(t *testing.T) {
	cfg := testConfig(t, "http://example.com/v1")
	db := testStore(t, cfg)
	logs := []store.RequestLog{
		{
			ID:             "req-stats-1",
			UserID:         "u1",
			Endpoint:       "/v1/chat/completions",
			Method:         http.MethodPost,
			Model:          "gpt-5.5",
			UpstreamID:     "openai",
			RequestSummary: "ok",
			StatusCode:     http.StatusOK,
			DurationMS:     100,
			UsageJSON:      `{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}`,
			ResponseSize:   10,
		},
		{
			ID:             "req-stats-2",
			UserID:         "u1",
			Endpoint:       "/v1/images/generations",
			Method:         http.MethodPost,
			Model:          "gpt-image-2",
			UpstreamID:     "images",
			RequestSummary: "failed",
			StatusCode:     http.StatusBadGateway,
			Error:          "upstream request failed",
			DurationMS:     300,
			ResponseSize:   20,
		},
	}
	for _, item := range logs {
		if err := db.SaveRequestLog(context.Background(), item); err != nil {
			t.Fatal(err)
		}
	}
	handler := New(cfg, db, http.DefaultTransport)

	req := httptest.NewRequest(http.MethodGet, "/admin/api/stats", nil)
	req.Header.Set("X-API-Key", "proxy-key")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var stats store.LogStats
	if err := json.NewDecoder(rec.Body).Decode(&stats); err != nil {
		t.Fatal(err)
	}
	if stats.TotalRequests != 2 {
		t.Fatalf("total = %d, want 2", stats.TotalRequests)
	}
	if stats.ErrorRequests != 1 {
		t.Fatalf("errors = %d, want 1", stats.ErrorRequests)
	}
	if stats.Usage.TotalTokens != 5 {
		t.Fatalf("tokens = %d, want 5", stats.Usage.TotalTokens)
	}
	if len(stats.ByStatus) == 0 || len(stats.Timeline) == 0 {
		t.Fatalf("missing bucket stats: status=%d timeline=%d", len(stats.ByStatus), len(stats.Timeline))
	}
}

func testConfig(t *testing.T, upstreamURL string) *config.Config {
	t.Helper()
	return &config.Config{
		Addr:              ":0",
		DatabasePath:      filepath.Join(t.TempDir(), "proxy.db"),
		DefaultChatModel:  "gpt-5.5",
		DefaultImageModel: "gpt-image-2",
		Log: config.LogConfig{
			StoreRequestBody: true,
			MaxBodyBytes:     1 << 20,
		},
		APIKeys: []config.APIKeyConfig{{UserID: "u1", Name: "User 1", Key: "proxy-key"}},
		Upstreams: []config.UpstreamConfig{
			{ID: "openai", BaseURL: upstreamURL, APIKey: "upstream-key", Models: []string{"gpt-*"}},
			{ID: "images", BaseURL: upstreamURL, APIKey: "upstream-key", Models: []string{"gpt-image*"}},
		},
	}
}

func testStore(t *testing.T, cfg *config.Config) *store.Store {
	t.Helper()
	db, err := store.Open(cfg.DatabasePath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.SyncConfig(context.Background(), cfg); err != nil {
		t.Fatal(err)
	}
	return db
}

type logRow struct {
	UserID         string
	Model          string
	UpstreamID     string
	RequestSummary string
	StatusCode     int
	Error          string
	UsageJSON      string
	ResponseJSON   string
}

func queryLog(t *testing.T, path string) logRow {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var row logRow
	err = db.QueryRow(`
SELECT user_id, model, upstream_id, request_summary, status_code, error, usage_json, response_json
FROM request_logs
ORDER BY created_at DESC
LIMIT 1
`).Scan(&row.UserID, &row.Model, &row.UpstreamID, &row.RequestSummary, &row.StatusCode, &row.Error, &row.UsageJSON, &row.ResponseJSON)
	if err != nil {
		t.Fatal(err)
	}
	return row
}

func queryFiles(t *testing.T, path string) []store.FileMeta {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT field_name, filename, content_type, size_bytes, sha256, storage_path
FROM request_files
ORDER BY id
`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()

	var files []store.FileMeta
	for rows.Next() {
		var file store.FileMeta
		if err := rows.Scan(&file.FieldName, &file.Filename, &file.ContentType, &file.SizeBytes, &file.SHA256, &file.StoragePath); err != nil {
			t.Fatal(err)
		}
		files = append(files, file)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(files)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) == 0 {
		t.Fatal("marshal files")
	}
	return files
}
