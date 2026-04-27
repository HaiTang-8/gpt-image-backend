package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func TestOpenMigratesResponseJSONColumn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "proxy.db")
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`
CREATE TABLE request_logs (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	endpoint TEXT NOT NULL,
	method TEXT NOT NULL,
	model TEXT NOT NULL,
	upstream_id TEXT NOT NULL,
	stream INTEGER NOT NULL,
	request_summary TEXT NOT NULL,
	request_json TEXT NOT NULL,
	status_code INTEGER NOT NULL,
	error TEXT NOT NULL,
	duration_ms INTEGER NOT NULL,
	usage_json TEXT NOT NULL,
	response_size INTEGER NOT NULL,
	created_at TEXT NOT NULL
);
`); err != nil {
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if err := st.SaveRequestLog(context.Background(), RequestLog{
		ID:           "req-migrated",
		UserID:       "u1",
		Endpoint:     "/v1/chat/completions",
		Method:       "POST",
		Model:        "gpt-5.5",
		UpstreamID:   "openai",
		StatusCode:   200,
		ResponseJSON: `{"id":"resp"}`,
	}); err != nil {
		t.Fatal(err)
	}

	logs, err := st.ListRequestLogs(context.Background(), LogQuery{Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	if len(logs.Items) != 1 {
		t.Fatalf("items = %d, want 1", len(logs.Items))
	}
	if logs.Items[0].ResponseJSON != `{"id":"resp"}` {
		t.Fatalf("response_json = %q", logs.Items[0].ResponseJSON)
	}
}
