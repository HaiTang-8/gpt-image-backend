package proxy

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"gpt-image-backend/internal/admin"
	"gpt-image-backend/internal/config"
	"gpt-image-backend/internal/store"
)

type Handler struct {
	cfg    *config.Config
	store  *store.Store
	client *http.Client
	admin  http.Handler
}

type requestInfo struct {
	Model        string
	Stream       bool
	Summary      string
	RequestJSON  string
	ResponseJSON string
	UsageJSON    string
	Files        []store.FileMeta
	ResponseSize int64
}

func New(cfg *config.Config, st *store.Store, transport http.RoundTripper) http.Handler {
	if transport == nil {
		transport = http.DefaultTransport
	}
	return &Handler{
		cfg:   cfg,
		store: st,
		admin: admin.New(cfg, st),
		client: &http.Client{
			Timeout:   cfg.RequestTimeout.Std(),
			Transport: transport,
		},
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/healthz" {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
		return
	}
	if r.URL.Path == "/admin" || strings.HasPrefix(r.URL.Path, "/admin/") {
		h.admin.ServeHTTP(w, r)
		return
	}
	switch r.URL.Path {
	case "/v1/chat/completions", "/v1/images/generations", "/v1/images/edits":
		h.proxy(w, r)
	default:
		http.NotFound(w, r)
	}
}

func (h *Handler) proxy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	user, ok := h.authenticate(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	start := time.Now()
	requestID := newRequestID()
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read request body", http.StatusBadRequest)
		return
	}
	_ = r.Body.Close()
	body = h.withRequestDefaults(r, body)

	info, err := h.inspectRequest(r, body, requestID)
	if err != nil {
		h.saveLog(requestID, user.UserID, r, requestInfo{
			RequestJSON: h.loggedBody(body),
		}, "", http.StatusBadRequest, time.Since(start).Milliseconds(), err)
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	upstream, ok := h.cfg.RouteUpstream(info.Model)
	if !ok {
		err := errors.New("no upstream configured")
		h.saveLog(requestID, user.UserID, r, info, "", http.StatusBadGateway, time.Since(start).Milliseconds(), err)
		http.Error(w, "no upstream configured", http.StatusBadGateway)
		return
	}

	statusCode, proxyErr := h.forward(w, r, body, upstream, requestID, &info)
	h.saveLog(requestID, user.UserID, r, info, upstream.ID, statusCode, time.Since(start).Milliseconds(), proxyErr)
}

func (h *Handler) withRequestDefaults(r *http.Request, body []byte) []byte {
	switch r.URL.Path {
	case "/v1/chat/completions":
		return jsonWithDefaultModel(body, h.cfg.DefaultChatModel)
	case "/v1/images/generations":
		return jsonWithDefaultModel(body, h.cfg.DefaultImageModel)
	case "/v1/images/edits":
		return multipartWithDefaultModel(r, body, h.cfg.DefaultImageModel)
	default:
		return body
	}
}

func jsonWithDefaultModel(body []byte, model string) []byte {
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		return body
	}
	if strings.TrimSpace(stringValue(payload["model"])) != "" {
		return body
	}
	payload["model"] = model
	data, err := json.Marshal(payload)
	if err != nil {
		return body
	}
	return data
}

type multipartPayloadPart struct {
	header textproto.MIMEHeader
	data   []byte
}

func multipartWithDefaultModel(r *http.Request, body []byte, model string) []byte {
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
		return body
	}
	_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil {
		return body
	}
	boundary := params["boundary"]
	if boundary == "" {
		return body
	}

	reader := multipart.NewReader(bytes.NewReader(body), boundary)
	var parts []multipartPayloadPart
	hasModel := false
	for {
		part, err := reader.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return body
		}
		data, err := io.ReadAll(part)
		if err != nil {
			_ = part.Close()
			return body
		}
		name := part.FormName()
		header := cloneMIMEHeader(part.Header)
		_ = part.Close()
		if name == "model" && strings.TrimSpace(string(data)) != "" {
			hasModel = true
		}
		parts = append(parts, multipartPayloadPart{header: header, data: data})
	}
	if hasModel {
		return body
	}

	var rewritten bytes.Buffer
	writer := multipart.NewWriter(&rewritten)
	for _, part := range parts {
		dst, err := writer.CreatePart(part.header)
		if err != nil {
			return body
		}
		if _, err := dst.Write(part.data); err != nil {
			return body
		}
	}
	if err := writer.WriteField("model", model); err != nil {
		return body
	}
	if err := writer.Close(); err != nil {
		return body
	}
	r.Header.Set("Content-Type", writer.FormDataContentType())
	return rewritten.Bytes()
}

func cloneMIMEHeader(header textproto.MIMEHeader) textproto.MIMEHeader {
	cloned := make(textproto.MIMEHeader, len(header))
	for key, values := range header {
		cloned[key] = append([]string(nil), values...)
	}
	return cloned
}

func (h *Handler) saveLog(requestID, userID string, r *http.Request, info requestInfo, upstreamID string, statusCode int, durationMS int64, logErr error) {
	logEntry := store.RequestLog{
		ID:             requestID,
		UserID:         userID,
		Endpoint:       r.URL.Path,
		Method:         r.Method,
		Model:          info.Model,
		UpstreamID:     upstreamID,
		Stream:         info.Stream,
		RequestSummary: info.Summary,
		RequestJSON:    info.RequestJSON,
		ResponseJSON:   info.ResponseJSON,
		StatusCode:     statusCode,
		DurationMS:     durationMS,
		UsageJSON:      info.UsageJSON,
		ResponseSize:   info.ResponseSize,
		Files:          info.Files,
	}
	if logErr != nil {
		logEntry.Error = logErr.Error()
	}
	if err := h.store.SaveRequestLog(context.Background(), logEntry); err != nil {
		slog.Error("save request log", "error", err, "request_id", requestID)
		return
	}
	slog.Info("request completed",
		"request_id", requestID,
		"user_id", userID,
		"method", r.Method,
		"endpoint", r.URL.Path,
		"model", info.Model,
		"upstream_id", upstreamID,
		"status_code", statusCode,
		"duration_ms", durationMS,
		"response_size", info.ResponseSize,
		"error", logEntry.Error,
	)
}

func (h *Handler) authenticate(r *http.Request) (config.APIKeyConfig, bool) {
	token := ""
	auth := r.Header.Get("Authorization")
	if strings.HasPrefix(strings.ToLower(auth), "bearer ") {
		token = strings.TrimSpace(auth[len("bearer "):])
	}
	if token == "" {
		token = strings.TrimSpace(r.Header.Get("X-API-Key"))
	}
	if token == "" {
		return config.APIKeyConfig{}, false
	}
	return h.cfg.UserByAPIKey(token)
}

func (h *Handler) inspectRequest(r *http.Request, body []byte, requestID string) (requestInfo, error) {
	if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
		return h.inspectMultipart(r, body, requestID)
	}
	return h.inspectJSON(body)
}

func (h *Handler) inspectJSON(body []byte) (requestInfo, error) {
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		return requestInfo{}, errors.New("invalid json request")
	}
	info := requestInfo{
		Model:       stringValue(payload["model"]),
		Stream:      boolValue(payload["stream"]),
		Summary:     summarizeJSON(payload),
		RequestJSON: h.loggedBody(body),
		Files:       collectJSONFileRefs(payload),
	}
	return info, nil
}

func (h *Handler) inspectMultipart(r *http.Request, body []byte, requestID string) (requestInfo, error) {
	_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil {
		return requestInfo{}, errors.New("invalid multipart content type")
	}
	boundary := params["boundary"]
	if boundary == "" {
		return requestInfo{}, errors.New("missing multipart boundary")
	}
	reader := multipart.NewReader(bytes.NewReader(body), boundary)
	values := map[string][]string{}
	var files []store.FileMeta

	for {
		part, err := reader.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return requestInfo{}, errors.New("invalid multipart body")
		}
		data, err := io.ReadAll(part)
		if err != nil {
			_ = part.Close()
			return requestInfo{}, errors.New("read multipart part")
		}
		_ = part.Close()

		if part.FileName() == "" {
			values[part.FormName()] = append(values[part.FormName()], string(data))
			continue
		}
		sum := sha256.Sum256(data)
		meta := store.FileMeta{
			FieldName:   part.FormName(),
			Filename:    part.FileName(),
			ContentType: part.Header.Get("Content-Type"),
			SizeBytes:   int64(len(data)),
			SHA256:      hex.EncodeToString(sum[:]),
		}
		if h.cfg.Log.StoreFiles {
			path, err := h.saveUploadedFile(requestID, meta, data)
			if err != nil {
				return requestInfo{}, err
			}
			meta.StoragePath = path
		}
		files = append(files, meta)
	}

	model := first(values["model"])
	summary := first(values["prompt"])
	requestJSON := ""
	if h.cfg.Log.StoreRequestBody {
		requestJSON = marshalStringMap(values)
	}
	return requestInfo{
		Model:       model,
		Summary:     summary,
		RequestJSON: requestJSON,
		Files:       files,
	}, nil
}

func (h *Handler) saveUploadedFile(requestID string, meta store.FileMeta, data []byte) (string, error) {
	if err := os.MkdirAll(h.cfg.Log.FileStorageDir, 0o755); err != nil {
		return "", err
	}
	name := strings.NewReplacer("/", "_", "\\", "_").Replace(meta.Filename)
	path := filepath.Join(h.cfg.Log.FileStorageDir, requestID+"-"+name)
	return path, os.WriteFile(path, data, 0o600)
}

func (h *Handler) forward(w http.ResponseWriter, r *http.Request, body []byte, upstream config.UpstreamConfig, requestID string, info *requestInfo) (int, error) {
	target, err := upstreamURL(upstream.BaseURL, r.URL)
	if err != nil {
		http.Error(w, "invalid upstream url", http.StatusBadGateway)
		return http.StatusBadGateway, err
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, target, bytes.NewReader(body))
	if err != nil {
		http.Error(w, "create upstream request", http.StatusBadGateway)
		return http.StatusBadGateway, err
	}
	copyHeaders(req.Header, r.Header)
	req.Header.Set("Authorization", "Bearer "+upstream.APIKey)
	req.Header.Set("X-Request-Id", infoHeader(r.Header.Get("X-Request-Id"), requestID))
	removeHopHeaders(req.Header)

	resp, err := h.client.Do(req)
	if err != nil {
		http.Error(w, "upstream request failed", http.StatusBadGateway)
		return http.StatusBadGateway, err
	}
	defer resp.Body.Close()

	copyHeaders(w.Header(), resp.Header)
	removeHopHeaders(w.Header())
	w.WriteHeader(resp.StatusCode)

	if !info.Stream {
		respBody, err := io.ReadAll(resp.Body)
		if err != nil {
			return resp.StatusCode, err
		}
		info.ResponseSize = int64(len(respBody))
		info.ResponseJSON = h.loggedResponseBody(respBody)
		info.UsageJSON = extractUsage(respBody)
		_, err = w.Write(respBody)
		return resp.StatusCode, err
	}

	counter := countingWriter{w: w}
	if _, err := io.Copy(&counter, resp.Body); err != nil {
		return resp.StatusCode, err
	}
	info.ResponseSize = counter.n
	return resp.StatusCode, nil
}

func copyHeaders(dst, src http.Header) {
	for key, values := range src {
		dst.Del(key)
		for _, value := range values {
			dst.Add(key, value)
		}
	}
}

func removeHopHeaders(header http.Header) {
	for _, key := range []string{
		"Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
		"Te", "Trailer", "Transfer-Encoding", "Upgrade",
	} {
		header.Del(key)
	}
}

func upstreamURL(base string, original *url.URL) (string, error) {
	parsed, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	path := original.Path
	if strings.HasSuffix(parsed.Path, "/v1") && strings.HasPrefix(path, "/v1/") {
		path = strings.TrimPrefix(path, "/v1")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/") + "/" + strings.TrimLeft(path, "/")
	parsed.RawQuery = original.RawQuery
	return parsed.String(), nil
}

func newRequestID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return hex.EncodeToString(b[:])
}

func summarizeJSON(payload map[string]any) string {
	if prompt := stringValue(payload["prompt"]); prompt != "" {
		return prompt
	}
	messages, ok := payload["messages"].([]any)
	if !ok {
		return ""
	}
	var parts []string
	for _, item := range messages {
		msg, ok := item.(map[string]any)
		if !ok {
			continue
		}
		switch content := msg["content"].(type) {
		case string:
			parts = append(parts, content)
		case []any:
			for _, block := range content {
				blockMap, ok := block.(map[string]any)
				if !ok {
					continue
				}
				if text := stringValue(blockMap["text"]); text != "" {
					parts = append(parts, text)
				}
			}
		}
	}
	return strings.Join(parts, "\n")
}

func collectJSONFileRefs(payload map[string]any) []store.FileMeta {
	var files []store.FileMeta
	var walk func(any)
	walk = func(v any) {
		switch typed := v.(type) {
		case map[string]any:
			if urlValue := stringValue(typed["url"]); urlValue != "" && looksLikeFileRef(urlValue) {
				files = append(files, store.FileMeta{FieldName: "url", Filename: urlValue})
			}
			if imageURL, ok := typed["image_url"].(map[string]any); ok {
				if urlValue := stringValue(imageURL["url"]); urlValue != "" {
					files = append(files, store.FileMeta{FieldName: "image_url", Filename: urlValue, SizeBytes: int64(len(urlValue))})
				}
			}
			if file, ok := typed["file"].(map[string]any); ok {
				name := stringValue(file["filename"])
				if name == "" {
					name = stringValue(file["file_id"])
				}
				files = append(files, store.FileMeta{FieldName: "file", Filename: name, SizeBytes: int64(len(stringValue(file["file_data"])))})
			}
			for _, value := range typed {
				walk(value)
			}
		case []any:
			for _, item := range typed {
				walk(item)
			}
		}
	}
	walk(payload)
	return files
}

func looksLikeFileRef(value string) bool {
	return strings.HasPrefix(value, "data:") || strings.HasPrefix(value, "file-") || strings.HasPrefix(value, "http://") || strings.HasPrefix(value, "https://")
}

func (h *Handler) loggedBody(body []byte) string {
	if !h.cfg.Log.StoreRequestBody {
		return ""
	}
	return h.truncatedBody(body)
}

func (h *Handler) loggedResponseBody(body []byte) string {
	if !h.cfg.Log.StoreResponseBody {
		return ""
	}
	return h.truncatedBody(body)
}

func (h *Handler) truncatedBody(body []byte) string {
	maxBytes := h.cfg.Log.MaxBodyBytes
	if maxBytes <= 0 || int64(len(body)) <= maxBytes {
		return string(body)
	}
	return string(body[:maxBytes])
}

func extractUsage(body []byte) string {
	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		return ""
	}
	usage, ok := payload["usage"]
	if !ok {
		return ""
	}
	data, err := json.Marshal(usage)
	if err != nil {
		return ""
	}
	return string(data)
}

func marshalStringMap(values map[string][]string) string {
	data, err := json.Marshal(values)
	if err != nil {
		return ""
	}
	return string(data)
}

func stringValue(value any) string {
	v, _ := value.(string)
	return v
}

func boolValue(value any) bool {
	v, _ := value.(bool)
	return v
}

func first(values []string) string {
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

func infoHeader(value, fallback string) string {
	if value != "" {
		return value
	}
	return fallback
}

type countingWriter struct {
	w http.ResponseWriter
	n int64
}

func (w *countingWriter) Write(p []byte) (int, error) {
	n, err := w.w.Write(p)
	w.n += int64(n)
	return n, err
}
