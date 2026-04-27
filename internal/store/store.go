package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"

	"gpt-image-backend/internal/config"

	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

type FileMeta struct {
	FieldName   string `json:"field_name"`
	Filename    string `json:"filename"`
	ContentType string `json:"content_type"`
	SizeBytes   int64  `json:"size_bytes"`
	SHA256      string `json:"sha256"`
	StoragePath string `json:"storage_path"`
}

type RequestLog struct {
	ID             string
	UserID         string
	Endpoint       string
	Method         string
	Model          string
	UpstreamID     string
	Stream         bool
	RequestSummary string
	RequestJSON    string
	StatusCode     int
	Error          string
	DurationMS     int64
	UsageJSON      string
	ResponseSize   int64
	ResponseJSON   string
	Files          []FileMeta
}

type LogQuery struct {
	Limit      int
	Offset     int
	UserID     string
	Endpoint   string
	Model      string
	UpstreamID string
	StatusCode int
	Search     string
	From       time.Time
	To         time.Time
}

type RequestLogRecord struct {
	ID             string     `json:"id"`
	UserID         string     `json:"user_id"`
	Endpoint       string     `json:"endpoint"`
	Method         string     `json:"method"`
	Model          string     `json:"model"`
	UpstreamID     string     `json:"upstream_id"`
	Stream         bool       `json:"stream"`
	RequestSummary string     `json:"request_summary"`
	RequestJSON    string     `json:"request_json"`
	StatusCode     int        `json:"status_code"`
	Error          string     `json:"error"`
	DurationMS     int64      `json:"duration_ms"`
	UsageJSON      string     `json:"usage_json"`
	ResponseSize   int64      `json:"response_size"`
	ResponseJSON   string     `json:"response_json"`
	CreatedAt      string     `json:"created_at"`
	Files          []FileMeta `json:"files"`
}

type RequestLogList struct {
	Items  []RequestLogRecord `json:"items"`
	Total  int64              `json:"total"`
	Limit  int                `json:"limit"`
	Offset int                `json:"offset"`
}

type LogStats struct {
	TotalRequests     int64         `json:"total_requests"`
	SuccessRequests   int64         `json:"success_requests"`
	ErrorRequests     int64         `json:"error_requests"`
	AverageDurationMS float64       `json:"average_duration_ms"`
	ResponseBytes     int64         `json:"response_bytes"`
	FileCount         int64         `json:"file_count"`
	FileBytes         int64         `json:"file_bytes"`
	Usage             UsageStats    `json:"usage"`
	ByStatus          []CountBucket `json:"by_status"`
	ByEndpoint        []CountBucket `json:"by_endpoint"`
	ByModel           []CountBucket `json:"by_model"`
	ByUser            []CountBucket `json:"by_user"`
	ByUpstream        []CountBucket `json:"by_upstream"`
	Timeline          []CountBucket `json:"timeline"`
}

type UsageStats struct {
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	TotalTokens      int64 `json:"total_tokens"`
}

type CountBucket struct {
	Key               string  `json:"key"`
	Count             int64   `json:"count"`
	ErrorCount        int64   `json:"error_count"`
	AverageDurationMS float64 `json:"average_duration_ms"`
}

func Open(path string) (*Store, error) {
	if dir := filepath.Dir(path); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	store := &Store{db: db}
	if err := store.migrate(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) migrate(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS users (
	id TEXT PRIMARY KEY,
	name TEXT NOT NULL,
	api_key_hash TEXT NOT NULL UNIQUE,
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS upstreams (
	id TEXT PRIMARY KEY,
	base_url TEXT NOT NULL,
	models_json TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS request_logs (
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
	response_json TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS request_files (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	request_id TEXT NOT NULL,
	field_name TEXT NOT NULL,
	filename TEXT NOT NULL,
	content_type TEXT NOT NULL,
	size_bytes INTEGER NOT NULL,
	sha256 TEXT NOT NULL,
	storage_path TEXT NOT NULL,
	created_at TEXT NOT NULL,
	FOREIGN KEY(request_id) REFERENCES request_logs(id)
);
CREATE INDEX IF NOT EXISTS idx_request_logs_user_created ON request_logs(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_request_logs_created ON request_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_request_logs_status_created ON request_logs(status_code, created_at);
CREATE INDEX IF NOT EXISTS idx_request_files_request ON request_files(request_id);
`)
	if err != nil {
		return err
	}
	return s.ensureRequestLogColumns(ctx)
}

func (s *Store) ensureRequestLogColumns(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(request_logs)`)
	if err != nil {
		return err
	}
	defer rows.Close()

	columns := map[string]struct{}{}
	for rows.Next() {
		var cid int
		var name, columnType string
		var notNull, pk int
		var defaultValue sql.NullString
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		columns[name] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if _, ok := columns["response_json"]; ok {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `ALTER TABLE request_logs ADD COLUMN response_json TEXT NOT NULL DEFAULT ''`)
	return err
}

func (s *Store) SyncConfig(ctx context.Context, cfg *config.Config) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	for _, key := range cfg.APIKeys {
		name := key.Name
		if name == "" {
			name = key.UserID
		}
		if _, err := tx.ExecContext(ctx, `
INSERT INTO users (id, name, api_key_hash, created_at)
VALUES (?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET name = excluded.name, api_key_hash = excluded.api_key_hash
`, key.UserID, name, cfg.HashAPIKey(key.Key), now); err != nil {
			return err
		}
	}

	for _, upstream := range cfg.Upstreams {
		models, err := json.Marshal(upstream.Models)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `
INSERT INTO upstreams (id, base_url, models_json, created_at)
VALUES (?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET base_url = excluded.base_url, models_json = excluded.models_json
`, upstream.ID, upstream.BaseURL, string(models), now); err != nil {
			return err
		}
	}

	return tx.Commit()
}

func (s *Store) ListRequestLogs(ctx context.Context, query LogQuery) (RequestLogList, error) {
	query = normalizeLogQuery(query)
	where, args := buildLogWhere(query, "")

	var total int64
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM request_logs WHERE "+where, args...).Scan(&total); err != nil {
		return RequestLogList{}, err
	}

	rows, err := s.db.QueryContext(ctx, `
SELECT id, user_id, endpoint, method, model, upstream_id, stream, request_summary, request_json,
	status_code, error, duration_ms, usage_json, response_size, response_json, created_at
FROM request_logs
WHERE `+where+`
ORDER BY created_at DESC, id DESC
LIMIT ? OFFSET ?
`, append(args, query.Limit, query.Offset)...)
	if err != nil {
		return RequestLogList{}, err
	}
	defer rows.Close()

	var items []RequestLogRecord
	var ids []string
	for rows.Next() {
		var item RequestLogRecord
		var stream int
		if err := rows.Scan(
			&item.ID,
			&item.UserID,
			&item.Endpoint,
			&item.Method,
			&item.Model,
			&item.UpstreamID,
			&stream,
			&item.RequestSummary,
			&item.RequestJSON,
			&item.StatusCode,
			&item.Error,
			&item.DurationMS,
			&item.UsageJSON,
			&item.ResponseSize,
			&item.ResponseJSON,
			&item.CreatedAt,
		); err != nil {
			return RequestLogList{}, err
		}
		item.Stream = stream == 1
		items = append(items, item)
		ids = append(ids, item.ID)
	}
	if err := rows.Err(); err != nil {
		return RequestLogList{}, err
	}

	files, err := s.filesByRequestID(ctx, ids)
	if err != nil {
		return RequestLogList{}, err
	}
	for i := range items {
		items[i].Files = files[items[i].ID]
		if items[i].Files == nil {
			items[i].Files = []FileMeta{}
		}
	}
	if items == nil {
		items = []RequestLogRecord{}
	}

	return RequestLogList{Items: items, Total: total, Limit: query.Limit, Offset: query.Offset}, nil
}

func (s *Store) RequestLogStats(ctx context.Context, query LogQuery) (LogStats, error) {
	query.Limit = 0
	query.Offset = 0
	where, args := buildLogWhere(query, "")

	var stats LogStats
	err := s.db.QueryRowContext(ctx, `
SELECT
	COUNT(*),
	COALESCE(SUM(CASE WHEN status_code >= 200 AND status_code < 400 AND error = '' THEN 1 ELSE 0 END), 0),
	COALESCE(SUM(CASE WHEN status_code >= 400 OR error <> '' THEN 1 ELSE 0 END), 0),
	COALESCE(AVG(duration_ms), 0),
	COALESCE(SUM(response_size), 0)
FROM request_logs
WHERE `+where, args...).Scan(
		&stats.TotalRequests,
		&stats.SuccessRequests,
		&stats.ErrorRequests,
		&stats.AverageDurationMS,
		&stats.ResponseBytes,
	)
	if err != nil {
		return LogStats{}, err
	}

	fileWhere, fileArgs := buildLogWhere(query, "l")
	err = s.db.QueryRowContext(ctx, `
SELECT COUNT(f.id), COALESCE(SUM(f.size_bytes), 0)
FROM request_files f
JOIN request_logs l ON l.id = f.request_id
WHERE `+fileWhere, fileArgs...).Scan(&stats.FileCount, &stats.FileBytes)
	if err != nil {
		return LogStats{}, err
	}

	stats.Usage, err = s.usageStats(ctx, where, args)
	if err != nil {
		return LogStats{}, err
	}
	if stats.ByStatus, err = s.countBuckets(ctx, where, args, "CAST(status_code AS TEXT)", 8); err != nil {
		return LogStats{}, err
	}
	if stats.ByEndpoint, err = s.countBuckets(ctx, where, args, "endpoint", 8); err != nil {
		return LogStats{}, err
	}
	if stats.ByModel, err = s.countBuckets(ctx, where, args, "model", 10); err != nil {
		return LogStats{}, err
	}
	if stats.ByUser, err = s.countBuckets(ctx, where, args, "user_id", 10); err != nil {
		return LogStats{}, err
	}
	if stats.ByUpstream, err = s.countBuckets(ctx, where, args, "upstream_id", 10); err != nil {
		return LogStats{}, err
	}
	stats.Timeline, err = s.timelineBuckets(ctx, where, args)
	if err != nil {
		return LogStats{}, err
	}

	return stats, nil
}

func normalizeLogQuery(query LogQuery) LogQuery {
	if query.Limit <= 0 {
		query.Limit = 50
	}
	if query.Limit > 200 {
		query.Limit = 200
	}
	if query.Offset < 0 {
		query.Offset = 0
	}
	return query
}

func buildLogWhere(query LogQuery, alias string) (string, []any) {
	var clauses []string
	var args []any
	col := func(name string) string {
		if alias == "" {
			return name
		}
		return alias + "." + name
	}
	addLike := func(name, value string) {
		if strings.TrimSpace(value) == "" {
			return
		}
		clauses = append(clauses, col(name)+" LIKE ?")
		args = append(args, "%"+strings.TrimSpace(value)+"%")
	}

	clauses = append(clauses, "1 = 1")
	if strings.TrimSpace(query.UserID) != "" {
		clauses = append(clauses, col("user_id")+" = ?")
		args = append(args, strings.TrimSpace(query.UserID))
	}
	addLike("endpoint", query.Endpoint)
	addLike("model", query.Model)
	if strings.TrimSpace(query.UpstreamID) != "" {
		clauses = append(clauses, col("upstream_id")+" = ?")
		args = append(args, strings.TrimSpace(query.UpstreamID))
	}
	if query.StatusCode > 0 {
		clauses = append(clauses, col("status_code")+" = ?")
		args = append(args, query.StatusCode)
	}
	if strings.TrimSpace(query.Search) != "" {
		clauses = append(clauses, "("+col("id")+" LIKE ? OR "+col("request_summary")+" LIKE ? OR "+col("request_json")+" LIKE ? OR "+col("response_json")+" LIKE ? OR "+col("error")+" LIKE ?)")
		value := "%" + strings.TrimSpace(query.Search) + "%"
		args = append(args, value, value, value, value, value)
	}
	if !query.From.IsZero() {
		clauses = append(clauses, col("created_at")+" >= ?")
		args = append(args, query.From.UTC().Format(time.RFC3339Nano))
	}
	if !query.To.IsZero() {
		clauses = append(clauses, col("created_at")+" <= ?")
		args = append(args, query.To.UTC().Format(time.RFC3339Nano))
	}

	return strings.Join(clauses, " AND "), args
}

func (s *Store) filesByRequestID(ctx context.Context, requestIDs []string) (map[string][]FileMeta, error) {
	result := make(map[string][]FileMeta, len(requestIDs))
	if len(requestIDs) == 0 {
		return result, nil
	}
	args := make([]any, 0, len(requestIDs))
	for _, id := range requestIDs {
		args = append(args, id)
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT request_id, field_name, filename, content_type, size_bytes, sha256, storage_path
FROM request_files
WHERE request_id IN (`+placeholders(len(requestIDs))+`)
ORDER BY id
`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var requestID string
		var file FileMeta
		if err := rows.Scan(&requestID, &file.FieldName, &file.Filename, &file.ContentType, &file.SizeBytes, &file.SHA256, &file.StoragePath); err != nil {
			return nil, err
		}
		result[requestID] = append(result[requestID], file)
	}
	return result, rows.Err()
}

func (s *Store) usageStats(ctx context.Context, where string, args []any) (UsageStats, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT usage_json FROM request_logs WHERE "+where+" AND usage_json <> ''", args...)
	if err != nil {
		return UsageStats{}, err
	}
	defer rows.Close()

	var stats UsageStats
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return UsageStats{}, err
		}
		var usage map[string]any
		if err := json.Unmarshal([]byte(raw), &usage); err != nil {
			continue
		}
		stats.PromptTokens += int64Number(usage["prompt_tokens"])
		stats.CompletionTokens += int64Number(usage["completion_tokens"])
		stats.TotalTokens += int64Number(usage["total_tokens"])
	}
	return stats, rows.Err()
}

func (s *Store) countBuckets(ctx context.Context, where string, args []any, expression string, limit int) ([]CountBucket, error) {
	queryArgs := append(append([]any{}, args...), limit)
	rows, err := s.db.QueryContext(ctx, `
SELECT COALESCE(NULLIF(`+expression+`, ''), '(empty)') AS bucket,
	COUNT(*),
	COALESCE(SUM(CASE WHEN status_code >= 400 OR error <> '' THEN 1 ELSE 0 END), 0),
	COALESCE(AVG(duration_ms), 0)
FROM request_logs
WHERE `+where+`
GROUP BY bucket
ORDER BY COUNT(*) DESC, bucket ASC
LIMIT ?
`, queryArgs...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanCountBuckets(rows)
}

func (s *Store) timelineBuckets(ctx context.Context, where string, args []any) ([]CountBucket, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT bucket, count, error_count, average_duration_ms
FROM (
	SELECT substr(created_at, 1, 10) AS bucket,
		COUNT(*) AS count,
		COALESCE(SUM(CASE WHEN status_code >= 400 OR error <> '' THEN 1 ELSE 0 END), 0) AS error_count,
		COALESCE(AVG(duration_ms), 0) AS average_duration_ms
	FROM request_logs
	WHERE `+where+`
	GROUP BY bucket
	ORDER BY bucket DESC
	LIMIT 30
)
ORDER BY bucket ASC
`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanCountBuckets(rows)
}

func scanCountBuckets(rows *sql.Rows) ([]CountBucket, error) {
	var buckets []CountBucket
	for rows.Next() {
		var bucket CountBucket
		if err := rows.Scan(&bucket.Key, &bucket.Count, &bucket.ErrorCount, &bucket.AverageDurationMS); err != nil {
			return nil, err
		}
		buckets = append(buckets, bucket)
	}
	return buckets, rows.Err()
}

func placeholders(count int) string {
	if count <= 0 {
		return ""
	}
	return strings.TrimRight(strings.Repeat("?,", count), ",")
}

func int64Number(value any) int64 {
	switch v := value.(type) {
	case float64:
		return int64(v)
	case int64:
		return v
	case int:
		return int64(v)
	case json.Number:
		n, _ := v.Int64()
		return n
	default:
		return 0
	}
}

func (s *Store) SaveRequestLog(ctx context.Context, log RequestLog) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	stream := 0
	if log.Stream {
		stream = 1
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `
INSERT INTO request_logs (
	id, user_id, endpoint, method, model, upstream_id, stream, request_summary, request_json,
		status_code, error, duration_ms, usage_json, response_size, response_json, created_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, log.ID, log.UserID, log.Endpoint, log.Method, log.Model, log.UpstreamID, stream, log.RequestSummary, log.RequestJSON, log.StatusCode, log.Error, log.DurationMS, log.UsageJSON, log.ResponseSize, log.ResponseJSON, now); err != nil {
		return err
	}

	for _, file := range log.Files {
		if _, err := tx.ExecContext(ctx, `
INSERT INTO request_files (
	request_id, field_name, filename, content_type, size_bytes, sha256, storage_path, created_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
`, log.ID, file.FieldName, file.Filename, file.ContentType, file.SizeBytes, file.SHA256, file.StoragePath, now); err != nil {
			return err
		}
	}

	return tx.Commit()
}
