package admin

import (
	"embed"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"gpt-image-backend/internal/config"
	"gpt-image-backend/internal/store"
)

//go:embed assets/index.html
var assets embed.FS

type Handler struct {
	cfg   *config.Config
	store *store.Store
}

func New(cfg *config.Config, st *store.Store) http.Handler {
	return &Handler{cfg: cfg, store: st}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/admin":
		http.Redirect(w, r, "/admin/", http.StatusFound)
	case "/admin/":
		h.index(w, r)
	case "/admin/api/logs":
		h.logs(w, r)
	case "/admin/api/stats":
		h.stats(w, r)
	default:
		http.NotFound(w, r)
	}
}

func (h *Handler) index(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	data, err := assets.ReadFile("assets/index.html")
	if err != nil {
		http.Error(w, "admin asset not found", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(data)
}

func (h *Handler) logs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !h.authorized(r) {
		unauthorized(w)
		return
	}
	query, err := parseLogQuery(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	result, err := h.store.ListRequestLogs(r.Context(), query)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "list logs")
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (h *Handler) stats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !h.authorized(r) {
		unauthorized(w)
		return
	}
	query, err := parseLogQuery(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	result, err := h.store.RequestLogStats(r.Context(), query)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "load stats")
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (h *Handler) authorized(r *http.Request) bool {
	token := ""
	auth := r.Header.Get("Authorization")
	if strings.HasPrefix(strings.ToLower(auth), "bearer ") {
		token = strings.TrimSpace(auth[len("bearer "):])
	}
	if token == "" {
		token = strings.TrimSpace(r.Header.Get("X-API-Key"))
	}
	if token == "" {
		return false
	}
	_, ok := h.cfg.UserByAPIKey(token)
	return ok
}

func parseLogQuery(r *http.Request) (store.LogQuery, error) {
	values := r.URL.Query()
	query := store.LogQuery{
		Limit:      intParam(values.Get("limit"), 50),
		Offset:     intParam(values.Get("offset"), 0),
		UserID:     strings.TrimSpace(values.Get("user_id")),
		Endpoint:   strings.TrimSpace(values.Get("endpoint")),
		Model:      strings.TrimSpace(values.Get("model")),
		UpstreamID: strings.TrimSpace(values.Get("upstream_id")),
		StatusCode: intParam(values.Get("status"), 0),
		Search:     strings.TrimSpace(values.Get("q")),
	}

	var err error
	query.From, err = timeParam(values.Get("from"), false)
	if err != nil {
		return store.LogQuery{}, err
	}
	query.To, err = timeParam(values.Get("to"), true)
	if err != nil {
		return store.LogQuery{}, err
	}
	return query, nil
}

func intParam(raw string, fallback int) int {
	if strings.TrimSpace(raw) == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return value
}

func timeParam(raw string, endOfDay bool) (time.Time, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return time.Time{}, nil
	}
	if parsed, err := time.Parse(time.RFC3339Nano, raw); err == nil {
		return parsed, nil
	}
	parsed, err := time.ParseInLocation("2006-01-02", raw, time.Local)
	if err != nil {
		return time.Time{}, err
	}
	if endOfDay {
		return parsed.Add(24*time.Hour - time.Nanosecond), nil
	}
	return parsed, nil
}

func unauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	writeError(w, http.StatusUnauthorized, "unauthorized")
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
