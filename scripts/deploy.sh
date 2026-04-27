#!/usr/bin/env bash
# gpt-image-backend Linux 一键部署脚本
#
# 默认安装到 ./gpt-image-backend ，生成 docker-compose.yml 与 config.yaml ，
# 拉取镜像并以 docker compose 启动。
#
# 用法:
#   bash deploy.sh                # 首次安装并启动
#   bash deploy.sh start|stop|restart|logs|status|update|uninstall
#
# 可用环境变量:
#   INSTALL_DIR   安装目录,默认 ./gpt-image-backend
#   IMAGE         镜像名,默认 zhaohaitang/gpt-image-backend:latest
#   HOST_PORT     宿主机端口,默认 8083
#   PROXY_KEY     客户端访问代理时使用的 Bearer Token,留空则随机生成
#   UPSTREAM_KEY  上游 OpenAI 兼容服务的 api_key,留空则保留占位符
#   UPSTREAM_URL  上游 base_url,默认 https://api.openai.com/v1
#   NONINTERACTIVE 设为 1 时跳过交互输入

set -euo pipefail

IMAGE="${IMAGE:-zhaohaitang/gpt-image-backend:latest}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/gpt-image-backend}"
HOST_PORT="${HOST_PORT:-8083}"
UPSTREAM_URL="${UPSTREAM_URL:-https://api.openai.com/v1}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info()  { color '1;36' "[INFO]  $*"; }
warn()  { color '1;33' "[WARN]  $*"; }
err()   { color '1;31' "[ERROR] $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "需要命令: $1"; exit 1; }
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    err "未找到 docker compose,请先安装 Docker Engine 与 Compose 插件"
    err "参考: https://docs.docker.com/engine/install/"
    exit 1
  fi
}

random_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

prompt() {
  local var="$1" tip="$2" default="${3:-}" answer
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$tip [$default]: " answer || true
    answer="${answer:-$default}"
  else
    read -r -p "$tip: " answer || true
  fi
  printf -v "$var" '%s' "$answer"
}

write_compose() {
  local file="$INSTALL_DIR/docker-compose.yml"
  cat > "$file" <<EOF
services:
  gpt-image-backend:
    image: $IMAGE
    container_name: gpt-image-backend
    restart: unless-stopped
    ports:
      - "${HOST_PORT}:8083"
    volumes:
      - ./config.yaml:/app/config.yaml:ro
      - ./data:/app/data
EOF
  info "已生成 $file"
}

write_config() {
  local file="$INSTALL_DIR/config.yaml"
  local proxy_key="$1" upstream_key="$2" upstream_url="$3"
  cat > "$file" <<EOF
addr: ":8083"
database_path: data/proxy.db
request_timeout: 5m
default_upstream: openai
default_chat_model: gpt-5.5
default_image_model: gpt-image-2

log:
  store_request_body: true
  store_response_body: false
  store_files: false
  file_storage_dir: data/uploads
  max_body_bytes: 1048576

api_keys:
  - user_id: default
    name: Default User
    key: ${proxy_key}

upstreams:
  - id: openai
    base_url: ${upstream_url}
    api_key: ${upstream_key}
    models:
      - gpt-*
      - chatgpt-*

  - id: images
    base_url: ${upstream_url}
    api_key: ${upstream_key}
    models:
      - dall-e*
      - gpt-image*
EOF
  chmod 600 "$file"
  info "已生成 $file"
}

# 容器内服务以 nonroot (UID 65532) 运行,需要让其能读 config.yaml 与读写 data/
fix_perms() {
  local cfg="$INSTALL_DIR/config.yaml"
  local data_dir="$INSTALL_DIR/data"
  if [[ $EUID -eq 0 ]]; then
    chown 65532:65532 "$cfg" "$data_dir"
    chmod 600 "$cfg"
    chmod 700 "$data_dir"
  else
    warn "当前未以 root 运行,改用宽松权限以便容器内 nonroot 用户访问"
    chmod 644 "$cfg"
    chmod 777 "$data_dir"
  fi
}

cmd_install() {
  require_cmd docker
  detect_compose

  mkdir -p "$INSTALL_DIR/data"
  cd "$INSTALL_DIR"

  if [[ -f config.yaml ]]; then
    warn "config.yaml 已存在,跳过生成。如需重置请手动删除后重跑。"
  else
    local proxy_key="${PROXY_KEY:-}"
    local upstream_key="${UPSTREAM_KEY:-}"
    local upstream_url="$UPSTREAM_URL"

    if [[ -z "$proxy_key" ]]; then
      if [[ "$NONINTERACTIVE" == "1" ]]; then
        proxy_key="$(random_key)"
      else
        prompt proxy_key "代理访问 Key (回车则随机生成)" ""
        [[ -z "$proxy_key" ]] && proxy_key="$(random_key)"
      fi
    fi

    if [[ -z "$upstream_key" ]]; then
      prompt upstream_key "上游 OpenAI 兼容服务的 api_key" "replace-with-upstream-key"
    fi

    prompt upstream_url "上游 base_url" "$upstream_url"

    write_config "$proxy_key" "$upstream_key" "$upstream_url"
  fi

  if [[ -f docker-compose.yml ]]; then
    info "docker-compose.yml 已存在,覆盖更新"
  fi
  write_compose

  fix_perms

  info "拉取镜像 $IMAGE"
  "${COMPOSE[@]}" pull
  info "启动服务"
  "${COMPOSE[@]}" up -d

  echo
  info "部署完成"
  info "  目录:        $INSTALL_DIR"
  info "  健康检查:    curl http://127.0.0.1:${HOST_PORT}/healthz"
  info "  Admin 控制台: http://<server-ip>:${HOST_PORT}/admin/"
  if grep -q '^api_keys:' config.yaml; then
    local key
    key="$(awk '/^api_keys:/{f=1;next} f && /key:/{print $2; exit}' config.yaml)"
    info "  Proxy Key:   $key"
  fi
}

cmd_compose() {
  detect_compose
  cd "$INSTALL_DIR"
  "${COMPOSE[@]}" "$@"
}

cmd_update() {
  detect_compose
  cd "$INSTALL_DIR"
  info "拉取最新镜像并重建容器"
  "${COMPOSE[@]}" pull
  "${COMPOSE[@]}" up -d
}

cmd_uninstall() {
  detect_compose
  cd "$INSTALL_DIR"
  warn "即将停止并删除容器,data/ 与 config.yaml 不会被删除"
  "${COMPOSE[@]}" down
}

main() {
  local action="${1:-install}"
  case "$action" in
    install|"")     cmd_install ;;
    start)          cmd_compose up -d ;;
    stop)           cmd_compose stop ;;
    restart)        cmd_compose restart ;;
    logs)           shift || true; cmd_compose logs -f --tail=200 "$@" ;;
    status|ps)      cmd_compose ps ;;
    update|upgrade) cmd_update ;;
    uninstall|down) cmd_uninstall ;;
    -h|--help|help)
      sed -n '2,18p' "$0"
      ;;
    *)
      err "未知命令: $action"
      sed -n '2,18p' "$0"
      exit 1
      ;;
  esac
}

main "$@"
