# gpt-image-backend

OpenAI-compatible logging proxy written in Go.

## Run

```bash
cp config.example.yaml config.yaml
go run ./cmd/gpt-image-backend
```

Clients call this service with the proxy key:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H 'Authorization: Bearer replace-with-proxy-key' \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'
```

## Logged endpoints

- `POST /v1/chat/completions`
- `POST /v1/responses`
- `POST /v1/images/generations`
- `POST /v1/images/edits`
- `GET /healthz`

Image generation in the Flutter client uses the Responses API with the
`image_generation` tool. The older Images API endpoints are still proxied for
external compatibility.

## Admin console

Open `http://localhost:8080/admin/` after the service starts. The console uses
the same proxy API key for `/admin/api/logs` and `/admin/api/stats`, and shows
request logs, stored request bodies, file metadata, usage totals, latency, error
rates, and traffic breakdowns. Response bodies are shown when
`log.store_response_body` is enabled.

## Real image generation test

This test calls the configured upstream API and may incur cost. It is excluded
from the default test suite. The test uses a 5 minute request timeout.

```bash
go test -tags=integration ./internal/proxy -run TestRealImagesGeneration -count=1
```

To test a three-image conversation that edits with `previous_response_id`:

```bash
go test -tags=integration ./internal/proxy -run TestRealImagesConversationEditing -count=1
```

By default it reads `config.yaml`. To use another config file:

```bash
GPT_IMAGE_CONFIG=/path/to/config.yaml go test -tags=integration ./internal/proxy -run TestRealImagesGeneration -count=1
```
