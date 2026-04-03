#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# telemt-auto-install.sh
# Debian / Ubuntu / Debian-based
# =========================================================

CANDIDATE_PORTS=(1443 2443 3443 4443 5443 6443 7443 8443 9443)

TELEMT_USER="${TELEMT_USER:-telemt}"
TELEMT_GROUP="${TELEMT_GROUP:-telemt}"
TELEMT_WORKDIR="${TELEMT_WORKDIR:-/opt/telemt}"
TELEMT_CONFIG_DIR="${TELEMT_CONFIG_DIR:-/etc/telemt}"
TELEMT_CONFIG_FILE="${TELEMT_CONFIG_FILE:-/etc/telemt/telemt.toml}"
TELEMT_BIN="${TELEMT_BIN:-/bin/telemt}"
TELEMT_SERVICE="${TELEMT_SERVICE:-/etc/systemd/system/telemt.service}"
API_LISTEN="${API_LISTEN:-127.0.0.1:9091}"

# Формат:
# TELEMT_USERS="user1:0123456789abcdef0123456789abcdef,user2:abcdefabcdefabcdefabcdefabcdefab"
TELEMT_USERS="${TELEMT_USERS:-}"

# Опционально, 32 hex chars
AD_TAG="${AD_TAG:-}"

# Если нужен свой порт вручную:
# TELEMT_PORT=8443 ./telemt-auto-install.sh
TELEMT_PORT="${TELEMT_PORT:-}"

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[-]\033[0m $*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запусти скрипт от root"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

backup_file_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "${f}.bak.${ts}"
    log "Создан бэкап: ${f}.bak.${ts}"
  fi
}

random_hex_32chars() {
  if command_exists openssl; then
    openssl rand -hex 16
  else
    python3 - <<'PY'
import os
print(os.urandom(16).hex())
PY
  fi
}

is_valid_hex32() {
  [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]
}

detect_arch() {
  uname -m
}

detect_libc() {
  if ldd --version 2>&1 | grep -iq musl; then
    echo "musl"
  else
    echo "gnu"
  fi
}

is_port_free() {
  local port="$1"
  ! ss -ltnup 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

choose_port() {
  if [[ -n "${TELEMT_PORT}" ]]; then
    if is_port_free "${TELEMT_PORT}"; then
      log "Использую порт из TELEMT_PORT: ${TELEMT_PORT}"
      return 0
    else
      err "Порт ${TELEMT_PORT} занят"
      ss -ltnup | grep -E "[:.]${TELEMT_PORT}[[:space:]]" || true
      exit 1
    fi
  fi

  local p
  for p in "${CANDIDATE_PORTS[@]}"; do
    if is_port_free "$p"; then
      TELEMT_PORT="$p"
      log "Найден свободный порт: ${TELEMT_PORT}"
      return 0
    fi
  done

  err "Свободных портов не найдено в списке: ${CANDIDATE_PORTS[*]}"
  exit 1
}

ask_tls_domain() {
  local input=""
  while true; do
    read -r -p "Введи сайт для маскировки (например cloudflare.com): " input
    input="$(trim "$input")"

    if [[ -z "$input" ]]; then
      warn "Домен не может быть пустым"
      continue
    fi

    # Очень базовая проверка
    if [[ "$input" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
      TLS_DOMAIN="$input"
      log "Использую tls_domain: ${TLS_DOMAIN}"
      return 0
    fi

    warn "Похоже на кривой домен. Попробуй ещё раз."
  done
}

install_packages() {
  log "Ставлю зависимости"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget tar jq ca-certificates coreutils procps iproute2 lsof python3 openssl
}

download_telemt() {
  local arch libc url tmpdir http_code
  arch="$(detect_arch)"
  libc="$(detect_libc)"
  url="https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz"
  tmpdir="$(mktemp -d)"

  log "Скачиваю telemt: ${url}"

  http_code="$(curl -L -s -o /dev/null -w '%{http_code}' "$url" || true)"
  if [[ "$http_code" != "200" && "$http_code" != "302" ]]; then
    err "Не удалось найти релиз для arch=${arch}, libc=${libc}. HTTP=${http_code}"
    rm -rf "$tmpdir"
    exit 1
  fi

  curl -fsSL "${url}" -o "${tmpdir}/telemt.tar.gz"
  tar -xzf "${tmpdir}/telemt.tar.gz" -C "${tmpdir}"

  if [[ ! -f "${tmpdir}/telemt" ]]; then
    err "Файл telemt не найден внутри архива"
    ls -la "${tmpdir}" || true
    rm -rf "${tmpdir}"
    exit 1
  fi

  install -m 0755 "${tmpdir}/telemt" "${TELEMT_BIN}"
  rm -rf "${tmpdir}"

  log "Бинарь установлен: ${TELEMT_BIN}"
}

ensure_user() {
  if ! getent group "${TELEMT_GROUP}" >/dev/null; then
    groupadd --system "${TELEMT_GROUP}"
  fi

  if ! id -u "${TELEMT_USER}" >/dev/null 2>&1; then
    useradd -d "${TELEMT_WORKDIR}" -m -r -g "${TELEMT_GROUP}" -s /usr/sbin/nologin "${TELEMT_USER}"
  fi

  mkdir -p "${TELEMT_WORKDIR}"
  chown -R "${TELEMT_USER}:${TELEMT_GROUP}" "${TELEMT_WORKDIR}"
}

build_users_toml() {
  local users_raw="$1"
  local output=""
  local generated_secret=""
  local pair username secret
  local -a pairs=()

  if [[ -z "${users_raw}" ]]; then
    generated_secret="$(random_hex_32chars)"
    output+="hello = \"${generated_secret}\""$'\n'
    echo "${output}"
    return 0
  fi

  IFS=',' read -r -a pairs <<< "${users_raw}"

  for pair in "${pairs[@]}"; do
    pair="$(trim "$pair")"
    [[ -z "$pair" ]] && continue

    username="${pair%%:*}"
    secret="${pair#*:}"

    username="$(trim "$username")"
    secret="$(trim "$secret")"

    if [[ -z "${username}" || -z "${secret}" || "${pair}" != *:* ]]; then
      err "Неверный формат TELEMT_USERS. Нужно: user1:hex32,user2:hex32"
      exit 1
    fi

    if ! is_valid_hex32 "${secret}"; then
      err "Секрет для пользователя '${username}' должен быть 32 hex chars"
      exit 1
    fi

    output+="\"${username}\" = \"${secret}\""$'\n'
  done

  if [[ -z "${output}" ]]; then
    err "После разбора TELEMT_USERS не осталось валидных пользователей"
    exit 1
  fi

  echo "${output}"
}

write_config() {
  local users_block
  mkdir -p "${TELEMT_CONFIG_DIR}"
  users_block="$(build_users_toml "${TELEMT_USERS}")"

  backup_file_if_exists "${TELEMT_CONFIG_FILE}"

  log "Пишу конфиг: ${TELEMT_CONFIG_FILE}"

  {
    echo "# Generated by telemt-auto-install.sh"
    echo "[general]"
    if [[ -n "${AD_TAG}" ]]; then
      if is_valid_hex32 "${AD_TAG}"; then
        echo "ad_tag = \"${AD_TAG}\""
      else
        warn "AD_TAG некорректный, пропускаю"
      fi
    fi
    echo "use_middle_proxy = false"
    echo
    echo "[general.modes]"
    echo "classic = false"
    echo "secure = false"
    echo "tls = true"
    echo
    echo "[server]"
    echo "port = ${TELEMT_PORT}"
    echo
    echo "[server.api]"
    echo "enabled = true"
    echo "listen = \"${API_LISTEN}\""
    echo
    echo "[censorship]"
    echo "tls_domain = \"${TLS_DOMAIN}\""
    echo
    echo "[access.users]"
    printf "%s" "${users_block}"
  } > "${TELEMT_CONFIG_FILE}"

  chown -R "${TELEMT_USER}:${TELEMT_GROUP}" "${TELEMT_CONFIG_DIR}"
  chmod 0750 "${TELEMT_CONFIG_DIR}"
  chmod 0640 "${TELEMT_CONFIG_FILE}"
}

write_service() {
  backup_file_if_exists "${TELEMT_SERVICE}"

  log "Пишу systemd unit: ${TELEMT_SERVICE}"

  cat > "${TELEMT_SERVICE}" <<EOF
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TELEMT_USER}
Group=${TELEMT_GROUP}
WorkingDirectory=${TELEMT_WORKDIR}
ExecStart=${TELEMT_BIN} ${TELEMT_CONFIG_FILE}
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "${TELEMT_SERVICE}"
  systemctl daemon-reload
}

open_firewall_port() {
  local port="$1"

  if command_exists ufw; then
    if ufw status 2>/dev/null | grep -qE "(^|[[:space:]])${port}(/tcp)?[[:space:]].*ALLOW"; then
      log "UFW: порт ${port} уже открыт"
    else
      log "UFW: открываю порт ${port}/tcp"
      ufw allow "${port}/tcp" >/dev/null 2>&1 || warn "Не удалось открыть порт через UFW"
    fi
    return 0
  fi

  if command_exists iptables; then
    if iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null; then
      log "iptables: правило для ${port}/tcp уже есть"
    else
      log "iptables: добавляю правило для ${port}/tcp"
      iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT || warn "Не удалось добавить правило iptables"
      if command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1 || true
      elif [[ -x /usr/sbin/service ]]; then
        service iptables save >/dev/null 2>&1 || true
      fi
    fi
    return 0
  fi

  warn "Не найден ufw или iptables. Открой порт ${port}/tcp вручную"
}

wait_for_api() {
  local i
  for i in $(seq 1 15); do
    if curl -fsS "http://${API_LISTEN}/v1/users" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_service() {
  log "Включаю и запускаю telemt"
  systemctl enable telemt >/dev/null 2>&1
  systemctl restart telemt

  sleep 1

  if ! systemctl is-active --quiet telemt; then
    err "Сервис не стартовал"
    systemctl status telemt --no-pager -l || true
    journalctl -u telemt -n 100 --no-pager || true
    exit 1
  fi

  systemctl status telemt --no-pager -l || true
}

show_links() {
  log "Получаю ссылки пользователей из API"

  if wait_for_api; then
    curl -fsS "http://${API_LISTEN}/v1/users" | jq .
  else
    warn "API не успел подняться"
    warn "Проверь позже командой:"
    echo "  curl -s http://${API_LISTEN}/v1/users | jq"
  fi
}

print_summary() {
  cat <<EOF

========================================
Telemt установлен
========================================
Бинарь:      ${TELEMT_BIN}
Конфиг:      ${TELEMT_CONFIG_FILE}
Сервис:      telemt
Порт:        ${TELEMT_PORT}
TLS domain:  ${TLS_DOMAIN}
API:         http://${API_LISTEN}/v1/users

Полезные команды:
  systemctl status telemt
  journalctl -u telemt -f
  curl -s http://${API_LISTEN}/v1/users | jq

Важно:
  - если TELEMT_USERS не был задан, создан пользователь hello
  - если меняешь tls_domain, старые ссылки перестанут подходить
  - после ручного редактирования конфига делай:
      systemctl restart telemt
========================================

EOF
}

main() {
  require_root
  choose_port
  ask_tls_domain
  install_packages
  download_telemt
  ensure_user
  write_config
  write_service
  open_firewall_port "${TELEMT_PORT}"
  start_service
  show_links
  print_summary
}

main "$@"
