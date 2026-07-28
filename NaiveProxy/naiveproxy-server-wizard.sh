#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
ORIGINAL_PATH=$PATH
if [[ "${NAIVE_WIZARD_TEST_MODE:-0}" == '1' || "${NAIVE_WIZARD_SOURCE_ONLY:-0}" == '1' ]]; then
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${ORIGINAL_PATH}"
else
  PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
fi
export PATH

readonly APP_NAME='NaiveProxy Server Wizard'
readonly APP_ID='naiveproxy-server-wizard'
readonly APP_VERSION='0.1.0'

# Reproducible upstream server build published by klzgrad/forwardproxy.
readonly CADDY_RELEASE_TAG='v2.11.2-naive'
readonly CADDY_ARCHIVE_NAME='caddy-forwardproxy-naive.tar.xz'
readonly CADDY_ARCHIVE_SHA256='19eccb7321dd877a5fb4a3dba6ef1b745185188b616c96cc6201f1a1fc0380a8'
readonly CADDY_ARCHIVE_URL="https://github.com/klzgrad/forwardproxy/releases/download/${CADDY_RELEASE_TAG}/${CADDY_ARCHIVE_NAME}"
readonly FORWARDPROXY_COMMIT='d62c80d3dd2c706b6b87579844d2397bddd18317'
readonly NAIVE_CLIENT_RELEASE='v150.0.7871.63-1'

# Default secure build: current patched Caddy with the pinned naïve plugin commit.
readonly CADDY_CORE_VERSION='v2.11.4'
readonly GO_VERSION='1.26.5'
readonly GO_AMD64_SHA256='5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053'
readonly GO_ARM64_SHA256='fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49'
readonly XCADDY_VERSION='0.4.5'
readonly XCADDY_AMD64_SHA256='2f96dde11b8ecbb7d652c20e05fddbfd2f58c622b464104309eae512406193cf'
readonly XCADDY_ARM64_SHA256='6ecb9665a2d654697fe79c379bff5d90a9e8aa9165d4b63f8cb21614c5e5e323'

readonly SERVICE_NAME='naiveproxy-caddy.service'
readonly SERVICE_USER='naiveproxy'
readonly SERVICE_GROUP='naiveproxy'

CONFIG_DIR="${NAIVE_WIZARD_CONFIG_DIR:-/etc/naiveproxy-wizard}"
STATE_DIR="${NAIVE_WIZARD_STATE_DIR:-/var/lib/naiveproxy-wizard}"
BACKUP_ROOT="${NAIVE_WIZARD_BACKUP_ROOT:-/var/lib/naiveproxy-wizard/backups}"
WEB_ROOT="${NAIVE_WIZARD_WEB_ROOT:-/var/www/naiveproxy-wizard}"
LOG_DIR="${NAIVE_WIZARD_LOG_DIR:-/var/log/naiveproxy-wizard}"
OUTPUT_DIR="${NAIVE_WIZARD_OUTPUT_DIR:-/root/naiveproxy-clients}"
CADDY_BIN="${NAIVE_WIZARD_CADDY_BIN:-/usr/local/bin/caddy-naive}"
SELF_INSTALL_PATH="${NAIVE_WIZARD_SELF_PATH:-/usr/local/sbin/naiveproxy-wizard}"
SERVICE_FILE="${NAIVE_WIZARD_SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}}"
LOCK_FILE="${NAIVE_WIZARD_LOCK_FILE:-/run/lock/naiveproxy-server-wizard.lock}"
RUNTIME_DIR="${NAIVE_WIZARD_RUNTIME_DIR:-/run/naiveproxy-server-wizard}"
BUILD_ROOT="${NAIVE_WIZARD_BUILD_ROOT:-/var/tmp/naiveproxy-server-wizard}"

SETTINGS_FILE="${CONFIG_DIR}/settings.json"
USERS_FILE="${CONFIG_DIR}/users.tsv"
CADDY_CONFIG="${CONFIG_DIR}/Caddyfile"
MANIFEST_FILE="${CONFIG_DIR}/manifest.json"
MANAGED_CERT="${CONFIG_DIR}/tls/fullchain.pem"
MANAGED_KEY="${CONFIG_DIR}/tls/privkey.pem"
TRANSACTION_FILE="${STATE_DIR}/transaction.json"
CADDY_DATA_DIR="${STATE_DIR}/caddy"

SOURCE_ONLY="${NAIVE_WIZARD_SOURCE_ONLY:-0}"
TEST_MODE="${NAIVE_WIZARD_TEST_MODE:-0}"
FAILPOINT="${NAIVE_WIZARD_FAILPOINT:-}"

DOMAIN=''
LISTEN_PORT='443'
TLS_MODE='acme'
ACME_EMAIL=''
SOURCE_CERT_PATH=''
SOURCE_KEY_PATH=''
HTTP3_ENABLED='true'
AUTO_HTTPS_REDIRECTS='true'
DECOY_MODE='static'
DECOY_UPSTREAM=''
DECOY_REDIRECT=''
DECOY_TITLE='Welcome'
PROBE_MODE='fallthrough'
PROBE_SECRET=''
PAC_ENABLED='false'
PAC_PATH=''
HIDE_IP='true'
HIDE_VIA='true'
TARGET_PORTS_MODE='web'
TARGET_PORTS='80 443'
ACL_MODE='hardened'
ACL_CUSTOM=''
UPSTREAM_URL=''
DIAL_TIMEOUT='30s'
MAX_IDLE_CONNS='256'
MAX_IDLE_CONNS_PER_HOST='8'
MANAGE_UFW='true'
OPEN_HTTP_PORT='true'
INSTALL_MODE='quick'
SERVER_BUILD_MODE='source_patched'

declare -a USERNAMES=()
declare -a PASSWORDS=()
declare -a FIREWALL_RULES_ADDED=()
declare -a FIREWALL_RULES_REMOVED=()

TRANSACTION_ARMED=0
TRANSACTION_COMMITTED=0
ROLLBACK_IN_PROGRESS=0
CURRENT_BACKUP=''
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0
BUILD_SWAP_FILE=''
PREPARED_CANDIDATE=''
LOCK_ACQUIRED=0
RUNTIME_CLAIMED=0
BUILD_CLAIMED=0

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_BLUE=$'\033[1;34m'
  readonly C_GREEN=$'\033[1;32m'
  readonly C_YELLOW=$'\033[1;33m'
  readonly C_RED=$'\033[1;31m'
else
  readonly C_RESET=''
  readonly C_BLUE=''
  readonly C_GREEN=''
  readonly C_YELLOW=''
  readonly C_RED=''
fi

info() {
  printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2
}

success() {
  printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2
}

warn() {
  printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

error() {
  printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

die() {
  error "$*"
  return 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

caddy_has_forwardproxy() {
  local binary=$1
  local modules
  modules=$("$binary" list-modules --versions 2>/dev/null) || return 1
  grep -Fq 'http.handlers.forward_proxy' <<<"$modules"
}

find_python() {
  if have python3; then
    printf '%s' 'python3'
  elif have python; then
    printf '%s' 'python'
  else
    return 1
  fi
}

is_test_mode() {
  [[ "$TEST_MODE" == '1' ]]
}

require_root() {
  if (( EUID != 0 )); then
    die 'Запустите мастер от root или через sudo.'
  fi
}

require_tty() {
  [[ -r /dev/tty && -w /dev/tty ]] || die 'Для интерактивного режима нужен доступный TTY.'
}

is_safe_absolute_path() {
  local value=$1
  [[ "$value" == /* ]] || return 1
  # Bash variables cannot contain NUL; explicitly reject the representable line separators.
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  [[ "$value" != '/' && "$value" != '/etc' && "$value" != '/var' && "$value" != '/usr' ]] || return 1
}

assert_sensitive_file_security() {
  local path=$1
  local label=$2
  [[ -f "$path" && ! -L "$path" ]] || die "Не найден безопасный ${label}: ${path}"
  [[ "$TEST_MODE" == '1' || "$SOURCE_ONLY" == '1' || "$EUID" -ne 0 ]] && return 0

  local uid mode group
  uid=$(stat -c '%u' -- "$path")
  mode=$(stat -c '%a' -- "$path")
  group=$(stat -c '%G' -- "$path")
  [[ "$uid" == '0' ]] || die "${label} должен принадлежать root."
  case "$mode" in
    600) ;;
    640)
      [[ "$group" == 'root' || "$group" == "$SERVICE_GROUP" ]] ||
        die "${label} с правами 0640 должен принадлежать группе root или ${SERVICE_GROUP}."
      ;;
    *) die "${label} должен иметь права 0600 или контролируемые 0640." ;;
  esac
}

assert_runtime_paths() {
  local path
  for path in \
    "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_ROOT" "$WEB_ROOT" "$LOG_DIR" \
    "$OUTPUT_DIR" "$CADDY_BIN" "$SELF_INSTALL_PATH" "$SERVICE_FILE" \
    "$LOCK_FILE" "$RUNTIME_DIR" "$BUILD_ROOT"; do
    is_safe_absolute_path "$path" || die "Небезопасный служебный путь: ${path}"
  done
}

acquire_lock() {
  if is_test_mode; then
    LOCK_ACQUIRED=1
    return 0
  fi
  have flock || die 'Не найдена команда flock.'
  install -d -m 0755 -- "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die 'Другой экземпляр мастера уже выполняется.'
  LOCK_ACQUIRED=1
}

menu() {
  local title=$1
  shift
  local -a options=("$@")
  local answer index

  printf '\n%s\n' "$title" >&2
  for index in "${!options[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${options[$index]}" >&2
  done

  while true; do
    printf '> ' >&2
    IFS= read -r answer </dev/tty || die 'Ввод прерван.'
    if [[ "$answer" =~ ^[0-9]+$ ]] &&
       (( 10#$answer >= 1 && 10#$answer <= ${#options[@]} )); then
      printf '%s' "$((10#$answer))"
      return 0
    fi
    warn "Введите число от 1 до ${#options[@]}."
  done
}

prompt_value() {
  local label=$1
  local default_value=${2:-}
  local answer
  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  IFS= read -r answer </dev/tty || die 'Ввод прерван.'
  [[ -n "$answer" ]] || answer=$default_value
  printf '%s' "$answer"
}

prompt_secret() {
  local label=$1
  local first second
  while true; do
    printf '%s: ' "$label" >&2
    IFS= read -rs first </dev/tty || die 'Ввод прерван.'
    printf '\nПовторите значение: ' >&2
    IFS= read -rs second </dev/tty || die 'Ввод прерван.'
    printf '\n' >&2
    [[ "$first" == "$second" ]] || {
      warn 'Значения не совпадают.'
      continue
    }
    [[ -n "$first" ]] || {
      warn 'Пустое значение запрещено.'
      continue
    }
    printf '%s' "$first"
    return 0
  done
}

confirm() {
  local label=$1
  local default_answer=${2:-no}
  local suffix answer
  if [[ "$default_answer" == 'yes' ]]; then
    suffix='[Y/n]'
  else
    suffix='[y/N]'
  fi
  printf '%s %s: ' "$label" "$suffix" >&2
  IFS= read -r answer </dev/tty || die 'Ввод прерван.'
  answer=${answer,,}
  [[ -n "$answer" ]] || answer=$default_answer
  [[ "$answer" == 'y' || "$answer" == 'yes' || "$answer" == 'д' || "$answer" == 'да' ]]
}

is_valid_domain() {
  local value=${1,,}
  (( ${#value} >= 4 && ${#value} <= 253 )) || return 1
  [[ "$value" == *.* ]] || return 1
  [[ "$value" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
  [[ "$value" != *..* ]] || return 1
  local label
  local old_ifs=$IFS
  IFS='.'
  read -r -a labels <<<"$value"
  IFS=$old_ifs
  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

is_valid_email_or_empty() {
  local value=$1
  [[ -z "$value" ]] && return 0
  [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

is_valid_port() {
  local value=$1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}

is_valid_count() {
  local value=$1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 500 ))
}

is_valid_positive_int() {
  local value=$1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 1000000 ))
}

is_valid_duration() {
  [[ "$1" =~ ^[1-9][0-9]*(ms|s|m|h)$ ]]
}

is_valid_username() {
  local value=$1
  (( ${#value} >= 1 && ${#value} <= 64 )) || return 1
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
}

is_valid_password() {
  local value=$1
  (( ${#value} >= 12 && ${#value} <= 128 )) || return 1
  [[ "$value" =~ ^[A-Za-z0-9._~!$()*+,=@%/-]+$ ]]
}

is_valid_url_token() {
  local value=$1
  (( ${#value} >= 8 && ${#value} <= 2048 )) || return 1
  [[ "$value" != *[[:space:]]* && "$value" != *\"* && "$value" != *\\* ]]
}

is_valid_upstream_url() {
  local value=$1
  is_valid_url_token "$value" || return 1
  [[ "$value" =~ ^https:// || "$value" =~ ^http://127\.0\.0\.1: || "$value" =~ ^socks5://127\.0\.0\.1: ]]
}

is_valid_decoy_url() {
  local value=$1
  is_valid_url_token "$value" || return 1
  [[ "$value" != *'@'* ]] || return 1
  [[ "$value" =~ ^https:// ]]
}

is_valid_acl_token() {
  [[ "$1" =~ ^[A-Za-z0-9.*:/_-]+$ ]]
}

normalize_space_list() {
  local value=$1
  local item
  local -a result=()
  value=${value//,/ }
  local old_ifs=$IFS
  IFS=' '
  read -r -a raw_items <<<"$value"
  IFS=$old_ifs
  for item in "${raw_items[@]}"; do
    [[ -n "$item" ]] || continue
    result+=("$item")
  done
  (
    IFS=' '
    printf '%s' "${result[*]}"
  )
}

validate_port_list() {
  local value
  value=$(normalize_space_list "$1")
  [[ -n "$value" ]] || return 1
  local item
  local old_ifs=$IFS
  IFS=' '
  read -r -a items <<<"$value"
  IFS=$old_ifs
  for item in "${items[@]}"; do
    is_valid_port "$item" || return 1
  done
}

validate_acl_list() {
  local value
  value=$(normalize_space_list "$1")
  [[ -n "$value" ]] || return 1
  local item
  local old_ifs=$IFS
  IFS=' '
  read -r -a items <<<"$value"
  IFS=$old_ifs
  for item in "${items[@]}"; do
    is_valid_acl_token "$item" || return 1
  done
}

generate_password() {
  local value
  while true; do
    value=$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9_-' | head -c 32)
    (( ${#value} == 32 )) && {
      printf '%s' "$value"
      return 0
    }
  done
}

generate_secret_label() {
  openssl rand -hex 12
}

username_exists() {
  local needle=$1
  local item
  for item in "${USERNAMES[@]}"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

validate_user_arrays() {
  (( ${#USERNAMES[@]} >= 1 && ${#USERNAMES[@]} <= 500 )) || return 1
  (( ${#USERNAMES[@]} == ${#PASSWORDS[@]} )) || return 1
  local index other
  for index in "${!USERNAMES[@]}"; do
    is_valid_username "${USERNAMES[$index]}" || return 1
    is_valid_password "${PASSWORDS[$index]}" || return 1
    for other in "${!USERNAMES[@]}"; do
      (( other <= index )) && continue
      [[ "${USERNAMES[$index]}" != "${USERNAMES[$other]}" ]] || return 1
    done
  done
}

create_generated_users() {
  local count=$1
  local prefix=${2:-user}
  is_valid_count "$count" || die 'Количество пользователей должно быть от 1 до 500.'
  is_valid_username "$prefix" || die 'Недопустимый префикс имени.'
  USERNAMES=()
  PASSWORDS=()
  local width=3 index username
  (( count >= 1000 )) && width=4
  for ((index = 1; index <= count; index++)); do
    printf -v username '%s-%0*d' "$prefix" "$width" "$index"
    is_valid_username "$username" || die "Сгенерировано недопустимое имя: ${username}"
    USERNAMES+=("$username")
    PASSWORDS+=("$(generate_password)")
  done
}

validate_settings() {
  is_valid_domain "$DOMAIN" || die 'Некорректный домен.'
  DOMAIN=${DOMAIN,,}
  is_valid_port "$LISTEN_PORT" || die 'Некорректный порт сервера.'
  [[ "$LISTEN_PORT" == '443' ]] ||
    die 'Naïve forwardproxy должен слушать TCP/443: нестандартный серверный порт не поддерживается upstream-контрактом.'
  [[ "$TLS_MODE" == 'acme' || "$TLS_MODE" == 'existing' ]] || die 'Некорректный режим TLS.'
  is_valid_email_or_empty "$ACME_EMAIL" || die 'Некорректный email ACME.'
  [[ "$HTTP3_ENABLED" == 'true' || "$HTTP3_ENABLED" == 'false' ]] || die 'Некорректный режим HTTP/3.'
  [[ "$AUTO_HTTPS_REDIRECTS" == 'true' || "$AUTO_HTTPS_REDIRECTS" == 'false' ]] || die 'Некорректный режим HTTPS redirect.'
  [[ "$DECOY_MODE" == 'static' || "$DECOY_MODE" == 'reverse_proxy' ||
     "$DECOY_MODE" == 'redirect' || "$DECOY_MODE" == 'respond' ]] || die 'Некорректный режим сайта.'
  if [[ "$DECOY_MODE" == 'reverse_proxy' ]]; then
    is_valid_decoy_url "$DECOY_UPSTREAM" || die 'Некорректный HTTPS URL сайта-прокладки.'
  fi
  if [[ "$DECOY_MODE" == 'redirect' ]]; then
    is_valid_decoy_url "$DECOY_REDIRECT" || die 'Некорректный HTTPS URL перенаправления.'
  fi
  (( ${#DECOY_TITLE} >= 1 && ${#DECOY_TITLE} <= 80 )) || die 'Заголовок сайта должен содержать 1–80 символов.'
  [[ "$DECOY_TITLE" != *$'\n'* && "$DECOY_TITLE" != *$'\r'* ]] || die 'Недопустимый заголовок сайта.'
  [[ "$PROBE_MODE" == 'fallthrough' || "$PROBE_MODE" == 'secret_domain' ]] || die 'Некорректный режим probe resistance.'
  if [[ "$PROBE_MODE" == 'secret_domain' ]]; then
    is_valid_domain "$PROBE_SECRET" || die 'Некорректный secret-domain для probe resistance.'
  fi
  [[ "$PAC_ENABLED" == 'true' || "$PAC_ENABLED" == 'false' ]] || die 'Некорректный режим PAC.'
  if [[ "$PAC_ENABLED" == 'true' ]]; then
    [[ "$PAC_PATH" =~ ^/[A-Za-z0-9._/-]{8,128}\.pac$ && "$PAC_PATH" != *..* ]] ||
      die 'Некорректный секретный PAC path.'
  fi
  [[ "$HIDE_IP" == 'true' || "$HIDE_IP" == 'false' ]] || die 'Некорректный hide_ip.'
  [[ "$HIDE_VIA" == 'true' || "$HIDE_VIA" == 'false' ]] || die 'Некорректный hide_via.'
  [[ "$TARGET_PORTS_MODE" == 'web' || "$TARGET_PORTS_MODE" == 'common' ||
     "$TARGET_PORTS_MODE" == 'custom' || "$TARGET_PORTS_MODE" == 'unrestricted' ]] ||
    die 'Некорректный режим портов назначения.'
  if [[ "$TARGET_PORTS_MODE" != 'unrestricted' ]]; then
    validate_port_list "$TARGET_PORTS" || die 'Некорректный список портов назначения.'
    TARGET_PORTS=$(normalize_space_list "$TARGET_PORTS")
  fi
  [[ "$ACL_MODE" == 'plugin_default' || "$ACL_MODE" == 'hardened' ||
     "$ACL_MODE" == 'custom_deny' || "$ACL_MODE" == 'allowlist' ]] ||
    die 'Некорректный режим ACL.'
  if [[ "$ACL_MODE" == 'custom_deny' || "$ACL_MODE" == 'allowlist' ]]; then
    validate_acl_list "$ACL_CUSTOM" || die 'Некорректный список ACL.'
    ACL_CUSTOM=$(normalize_space_list "$ACL_CUSTOM")
  fi
  if [[ -n "$UPSTREAM_URL" ]]; then
    is_valid_upstream_url "$UPSTREAM_URL" || die 'Некорректный upstream URL.'
  fi
  is_valid_duration "$DIAL_TIMEOUT" || die 'Некорректный dial timeout.'
  is_valid_positive_int "$MAX_IDLE_CONNS" || die 'Некорректный max_idle_conns.'
  is_valid_positive_int "$MAX_IDLE_CONNS_PER_HOST" || die 'Некорректный max_idle_conns_per_host.'
  [[ "$MANAGE_UFW" == 'true' || "$MANAGE_UFW" == 'false' ]] || die 'Некорректный режим UFW.'
  [[ "$OPEN_HTTP_PORT" == 'true' || "$OPEN_HTTP_PORT" == 'false' ]] || die 'Некорректный режим TCP/80.'
  [[ "$SERVER_BUILD_MODE" == 'source_patched' || "$SERVER_BUILD_MODE" == 'upstream_prebuilt' ]] ||
    die 'Некорректный режим сборки Caddy.'
  [[ -z "$UPSTREAM_URL" || ( "$TARGET_PORTS_MODE" == 'unrestricted' && "$ACL_MODE" == 'plugin_default' ) ]] ||
    die 'Upstream несовместим с ports и ACL: выберите unrestricted + plugin default.'
  if [[ "$TLS_MODE" == 'existing' ]]; then
    is_safe_absolute_path "$SOURCE_CERT_PATH" || die 'Некорректный путь сертификата.'
    is_safe_absolute_path "$SOURCE_KEY_PATH" || die 'Некорректный путь ключа.'
  fi
}

maybe_fail() {
  local point=$1
  [[ -z "$FAILPOINT" || "$FAILPOINT" != "$point" ]] || die "Активирован тестовый failpoint: ${point}"
}

print_banner() {
  printf '\n%s %s\n' "$APP_NAME" "$APP_VERSION" >&2
  printf '%s\n' 'Отдельный мастер Caddy + naïve forwardproxy для Ubuntu.' >&2
  printf '%s\n\n' 'Внимание: upstream forwardproxy помечен авторами как experimental.' >&2
}

write_plan_json() {
  local target=$1
  local python_bin
  python_bin=$(find_python) || die 'Для сериализации настроек нужен Python 3.'

  printf '%s\0' \
    "$DOMAIN" "$LISTEN_PORT" "$TLS_MODE" "$ACME_EMAIL" \
    "$HTTP3_ENABLED" "$AUTO_HTTPS_REDIRECTS" \
    "$DECOY_MODE" "$DECOY_UPSTREAM" "$DECOY_REDIRECT" "$DECOY_TITLE" \
    "$PROBE_MODE" "$PROBE_SECRET" "$PAC_ENABLED" "$PAC_PATH" \
    "$HIDE_IP" "$HIDE_VIA" "$TARGET_PORTS_MODE" "$TARGET_PORTS" \
    "$ACL_MODE" "$ACL_CUSTOM" "$UPSTREAM_URL" "$DIAL_TIMEOUT" \
    "$MAX_IDLE_CONNS" "$MAX_IDLE_CONNS_PER_HOST" \
    "$MANAGE_UFW" "$OPEN_HTTP_PORT" "$INSTALL_MODE" "$SERVER_BUILD_MODE" |
    "$python_bin" -c '
import json
import sys

raw = sys.stdin.buffer.read().split(b"\0")
if raw and raw[-1] == b"":
    raw.pop()
values = [item.decode("utf-8") for item in raw]
keys = [
    "domain", "listen_port", "tls_mode", "acme_email",
    "http3_enabled", "auto_https_redirects",
    "decoy_mode", "decoy_upstream", "decoy_redirect", "decoy_title",
    "probe_mode", "probe_secret", "pac_enabled", "pac_path",
    "hide_ip", "hide_via", "target_ports_mode", "target_ports",
    "acl_mode", "acl_custom", "upstream_url", "dial_timeout",
    "max_idle_conns", "max_idle_conns_per_host",
    "manage_ufw", "open_http_port", "install_mode",
    "server_build_mode",
]
if len(values) != len(keys):
    raise SystemExit(f"expected {len(keys)} values, got {len(values)}")
v = dict(zip(keys, values))
as_bool = lambda name: v[name] == "true"
document = {
    "schema_version": 1,
    "wizard_version": "'"$APP_VERSION"'",
    "server": {
        "domain": v["domain"],
        "listen_port": int(v["listen_port"]),
        "http3": as_bool("http3_enabled"),
        "auto_https_redirects": as_bool("auto_https_redirects"),
    },
    "tls": {
        "mode": v["tls_mode"],
        "acme_email": v["acme_email"],
        "certificate": "'"$MANAGED_CERT"'" if v["tls_mode"] == "existing" else "",
        "private_key": "'"$MANAGED_KEY"'" if v["tls_mode"] == "existing" else "",
    },
    "decoy": {
        "mode": v["decoy_mode"],
        "upstream": v["decoy_upstream"],
        "redirect": v["decoy_redirect"],
        "title": v["decoy_title"],
        "root": "'"$WEB_ROOT"'",
    },
    "privacy": {
        "probe_mode": v["probe_mode"],
        "probe_secret": v["probe_secret"],
        "hide_ip": as_bool("hide_ip"),
        "hide_via": as_bool("hide_via"),
        "exclude_activity_error_log": True,
    },
    "pac": {
        "enabled": as_bool("pac_enabled"),
        "path": v["pac_path"],
    },
    "egress": {
        "target_ports_mode": v["target_ports_mode"],
        "target_ports": [int(item) for item in v["target_ports"].split()] if v["target_ports"] else [],
        "acl_mode": v["acl_mode"],
        "acl_custom": v["acl_custom"].split() if v["acl_custom"] else [],
        "upstream": v["upstream_url"],
        "dial_timeout": v["dial_timeout"],
        "max_idle_conns": int(v["max_idle_conns"]),
        "max_idle_conns_per_host": int(v["max_idle_conns_per_host"]),
    },
    "firewall": {
        "manage_ufw": as_bool("manage_ufw"),
        "open_http_port": as_bool("open_http_port"),
    },
    "install_mode": v["install_mode"],
    "server_build_mode": v["server_build_mode"],
    "upstream_versions": {
        "caddy_core": "'"$CADDY_CORE_VERSION"'",
        "server_release": "'"$CADDY_RELEASE_TAG"'",
        "forwardproxy_commit": "'"$FORWARDPROXY_COMMIT"'",
        "recommended_client_release": "'"$NAIVE_CLIENT_RELEASE"'",
    },
}
json.dump(document, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
sys.stdout.write("\n")
' >"$target"
  chmod 0600 "$target"
}

load_settings() {
  local source=${1:-$SETTINGS_FILE}
  assert_sensitive_file_security "$source" 'settings.json'
  local python_bin
  python_bin=$(find_python) || die 'Для чтения настроек нужен Python 3.'
  local -a values=()
  mapfile -d '' -t values < <(
    "$python_bin" -c '
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    d = json.load(fh)
if d.get("schema_version") != 1:
    raise SystemExit("unsupported settings schema")

def boolean(path, value):
    if type(value) is not bool:
        raise SystemExit(f"{path} must be a JSON boolean")
    return "true" if value else "false"

fields = [
    d["server"]["domain"],
    str(d["server"]["listen_port"]),
    d["tls"]["mode"],
    d["tls"].get("acme_email", ""),
    d["tls"].get("certificate", ""),
    d["tls"].get("private_key", ""),
    boolean("server.http3", d["server"]["http3"]),
    boolean("server.auto_https_redirects", d["server"]["auto_https_redirects"]),
    d["decoy"]["mode"],
    d["decoy"].get("upstream", ""),
    d["decoy"].get("redirect", ""),
    d["decoy"].get("title", "Welcome"),
    d["privacy"]["probe_mode"],
    d["privacy"].get("probe_secret", ""),
    boolean("pac.enabled", d["pac"]["enabled"]),
    d["pac"].get("path", ""),
    boolean("privacy.hide_ip", d["privacy"]["hide_ip"]),
    boolean("privacy.hide_via", d["privacy"]["hide_via"]),
    d["egress"]["target_ports_mode"],
    " ".join(str(v) for v in d["egress"].get("target_ports", [])),
    d["egress"]["acl_mode"],
    " ".join(d["egress"].get("acl_custom", [])),
    d["egress"].get("upstream", ""),
    d["egress"]["dial_timeout"],
    str(d["egress"]["max_idle_conns"]),
    str(d["egress"]["max_idle_conns_per_host"]),
    boolean("firewall.manage_ufw", d["firewall"]["manage_ufw"]),
    boolean("firewall.open_http_port", d["firewall"]["open_http_port"]),
    d.get("install_mode", "guided"),
    d.get("server_build_mode", "source_patched"),
]
for field in fields:
    sys.stdout.buffer.write(str(field).encode("utf-8") + b"\0")
' "$source"
  )
  (( ${#values[@]} == 30 )) || die 'settings.json имеет неполный контракт.'
  DOMAIN=${values[0]}
  LISTEN_PORT=${values[1]}
  TLS_MODE=${values[2]}
  ACME_EMAIL=${values[3]}
  SOURCE_CERT_PATH=${values[4]}
  SOURCE_KEY_PATH=${values[5]}
  HTTP3_ENABLED=${values[6]}
  AUTO_HTTPS_REDIRECTS=${values[7]}
  DECOY_MODE=${values[8]}
  DECOY_UPSTREAM=${values[9]}
  DECOY_REDIRECT=${values[10]}
  DECOY_TITLE=${values[11]}
  PROBE_MODE=${values[12]}
  PROBE_SECRET=${values[13]}
  PAC_ENABLED=${values[14]}
  PAC_PATH=${values[15]}
  HIDE_IP=${values[16]}
  HIDE_VIA=${values[17]}
  TARGET_PORTS_MODE=${values[18]}
  TARGET_PORTS=${values[19]}
  ACL_MODE=${values[20]}
  ACL_CUSTOM=${values[21]}
  UPSTREAM_URL=${values[22]}
  DIAL_TIMEOUT=${values[23]}
  MAX_IDLE_CONNS=${values[24]}
  MAX_IDLE_CONNS_PER_HOST=${values[25]}
  MANAGE_UFW=${values[26]}
  OPEN_HTTP_PORT=${values[27]}
  INSTALL_MODE=${values[28]}
  SERVER_BUILD_MODE=${values[29]}
  if [[ "$TLS_MODE" == 'existing' ]]; then
    [[ -n "$SOURCE_CERT_PATH" && -n "$SOURCE_KEY_PATH" ]] ||
      die 'Для existing TLS settings.json должен содержать certificate и private_key.'
  else
    SOURCE_CERT_PATH=''
    SOURCE_KEY_PATH=''
  fi
  validate_settings
}

write_users_file() {
  local target=$1
  validate_user_arrays || die 'Невалидный набор пользователей.'
  : >"$target"
  chmod 0600 "$target"
  local index
  for index in "${!USERNAMES[@]}"; do
    printf '%s\t%s\n' "${USERNAMES[$index]}" "${PASSWORDS[$index]}" >>"$target"
  done
}

load_users() {
  local source=${1:-$USERS_FILE}
  assert_sensitive_file_security "$source" 'users.tsv'
  USERNAMES=()
  PASSWORDS=()
  local username password extra
  while IFS=$'\t' read -r username password extra; do
    username=${username%$'\r'}
    password=${password%$'\r'}
    extra=${extra%$'\r'}
    [[ -n "$username" ]] || continue
    [[ -z "${extra:-}" ]] || die 'users.tsv содержит лишние поля.'
    USERNAMES+=("$username")
    PASSWORDS+=("$password")
  done <"$source"
  validate_user_arrays || die 'users.tsv не прошёл валидацию.'
}

render_caddyfile() {
  local plan_file=$1
  local users_file=$2
  local python_bin
  python_bin=$(find_python) || die 'Для рендеринга Caddyfile нужен Python 3.'
  "$python_bin" - "$plan_file" "$users_file" <<'PY'
import json
import sys

plan_path, users_path = sys.argv[1:3]
with open(plan_path, "r", encoding="utf-8") as fh:
    plan = json.load(fh)

users = []
with open(users_path, "r", encoding="utf-8") as fh:
    for raw in fh:
        raw = raw.rstrip("\r\n")
        if not raw:
            continue
        username, password = raw.split("\t")
        users.append((username, password))

if not users:
    raise SystemExit("at least one user is required")

def q(value):
    return json.dumps(str(value), ensure_ascii=False)

server = plan["server"]
tls = plan["tls"]
decoy = plan["decoy"]
privacy = plan["privacy"]
pac = plan["pac"]
egress = plan["egress"]

protocols = "h1 h2 h3" if server["http3"] else "h1 h2"
lines = [
    "{",
    "    order forward_proxy first",
    "    admin off",
    "    servers {",
    f"        protocols {protocols}",
    "    }",
]
if not server["auto_https_redirects"]:
    lines.append("    auto_https disable_redirects")
if privacy.get("exclude_activity_error_log", True):
    lines.extend([
        "    log {",
        "        exclude http.log.error",
        "        exclude http.handlers.forward_proxy",
        "    }",
    ])
lines.extend([
    "}",
    "",
    f":443, {server['domain']} {{",
    "    encode zstd gzip",
])
if tls["mode"] == "existing":
    lines.append(f"    tls {q(tls['certificate'])} {q(tls['private_key'])}")
elif tls.get("acme_email"):
    lines.append(f"    tls {q(tls['acme_email'])}")

lines.extend([
    "",
    "    route {",
    "        forward_proxy {",
])
for username, password in users:
    lines.append(f"            basic_auth {q(username)} {q(password)}")
if privacy["hide_ip"]:
    lines.append("            hide_ip")
if privacy["hide_via"]:
    lines.append("            hide_via")
if privacy["probe_mode"] == "secret_domain":
    lines.append(f"            probe_resistance {q(privacy['probe_secret'])}")
else:
    lines.append("            probe_resistance")
if pac["enabled"]:
    lines.append(f"            serve_pac {q(pac['path'])}")

if egress.get("upstream"):
    lines.append(f"            upstream {q(egress['upstream'])}")
else:
    if egress["target_ports_mode"] != "unrestricted":
        ports = " ".join(str(item) for item in egress["target_ports"])
        lines.append(f"            ports {ports}")

    acl_mode = egress["acl_mode"]
    if acl_mode != "plugin_default":
        hardened_denies = [
            "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10",
            "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
            "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15",
            "224.0.0.0/4", "::/128", "::1/128", "fc00::/7",
            "fe80::/10", "ff00::/8",
        ]
        lines.append("            acl {")
        lines.append("                deny " + " ".join(hardened_denies))
        custom = egress.get("acl_custom", [])
        if acl_mode == "custom_deny" and custom:
            lines.append("                deny " + " ".join(custom))
            lines.append("                allow all")
        elif acl_mode == "allowlist" and custom:
            lines.append("                allow " + " ".join(custom))
            lines.append("                deny all")
        else:
            lines.append("                allow all")
        lines.append("            }")

lines.extend([
    f"            dial_timeout {egress['dial_timeout']}",
    f"            max_idle_conns {egress['max_idle_conns']}",
    f"            max_idle_conns_per_host {egress['max_idle_conns_per_host']}",
    "        }",
    "",
])

mode = decoy["mode"]
if mode == "static":
    lines.extend([
        f"        root * {q(decoy['root'])}",
        "        file_server",
    ])
elif mode == "reverse_proxy":
    lines.append(f"        reverse_proxy {q(decoy['upstream'])}")
elif mode == "redirect":
    lines.append(f"        redir {q(decoy['redirect'])} 302")
else:
    lines.append('        respond "Not Found" 404')

lines.extend([
    "    }",
    "}",
    "",
])
print("\n".join(lines))
PY
}

stage_client_bundle() {
  local plan_file=$1
  local users_file=$2
  local target_dir=$3
  local python_bin
  python_bin=$(find_python) || die 'Для генерации клиентских файлов нужен Python 3.'
  [[ -d "$target_dir" && ! -L "$target_dir" ]] || die 'Небезопасный staging-каталог клиентов.'

  "$python_bin" - "$plan_file" "$users_file" "$target_dir" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import urllib.parse

plan_path, users_path, target_value = sys.argv[1:4]
target = pathlib.Path(target_value)
with open(plan_path, "r", encoding="utf-8") as fh:
    plan = json.load(fh)

users = []
with open(users_path, "r", encoding="utf-8") as fh:
    for raw in fh:
        raw = raw.rstrip("\r\n")
        if raw:
            users.append(tuple(raw.split("\t")))

server = plan["server"]
domain = server["domain"]
port = int(server["listen_port"])
http3 = bool(server["http3"])
suffix = "" if port == 443 else f":{port}"

def write_secret(path, content):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)

def proxy_url(scheme, username, password):
    user = urllib.parse.quote(username, safe="")
    secret = urllib.parse.quote(password, safe="")
    return f"{scheme}://{user}:{secret}@{domain}{suffix}"

summary = [
    "NaiveProxy Server Wizard",
    f"Server: {domain}:{port}",
    f"Recommended native client: {plan['upstream_versions']['recommended_client_release']}",
    "Keep this file private.",
    "",
]

for index, (username, password) in enumerate(users, 1):
    h2_url = proxy_url("https", username, password)
    base_name = f"{index:03d}-{username}"
    native_h2 = {
        "listen": "socks://127.0.0.1:1080",
        "proxy": h2_url,
    }
    write_secret(
        target / f"native-{base_name}-h2.json",
        json.dumps(native_h2, ensure_ascii=False, indent=2) + "\n",
    )
    sing_h2 = {
        "outbounds": [{
            "type": "naive",
            "tag": "naive-h2",
            "server": domain,
            "server_port": port,
            "username": username,
            "password": password,
            "insecure_concurrency": 0,
            "quic": False,
            "tls": {"enabled": True, "server_name": domain},
        }]
    }
    write_secret(
        target / f"sing-box-{base_name}-h2.json",
        json.dumps(sing_h2, ensure_ascii=False, indent=2) + "\n",
    )
    summary.extend([
        f"[{index:03d}] {username}",
        f"Password: {password}",
        f"HTTPS/H2: {h2_url}",
    ])
    if http3:
        h3_url = proxy_url("quic", username, password)
        native_h3 = {
            "listen": "socks://127.0.0.1:1080",
            "proxy": h3_url,
        }
        write_secret(
            target / f"native-{base_name}-h3.json",
            json.dumps(native_h3, ensure_ascii=False, indent=2) + "\n",
        )
        sing_h3 = {
            "outbounds": [{
                "type": "naive",
                "tag": "naive-h3",
                "server": domain,
                "server_port": port,
                "username": username,
                "password": password,
                "insecure_concurrency": 0,
                "quic": True,
                "quic_congestion_control": "bbr",
                "tls": {"enabled": True, "server_name": domain},
            }]
        }
        write_secret(
            target / f"sing-box-{base_name}-h3.json",
            json.dumps(sing_h3, ensure_ascii=False, indent=2) + "\n",
        )
        summary.append(f"QUIC/H3: {h3_url}")
    summary.append("")

if plan["pac"]["enabled"]:
    summary.append(f"PAC: https://{domain}{suffix}{plan['pac']['path']}")
    summary.append("")

write_secret(target / "clients.txt", "\n".join(summary))

report = {
    "schema_version": 1,
    "wizard_version": plan["wizard_version"],
    "server": server,
    "tls_mode": plan["tls"]["mode"],
    "decoy_mode": plan["decoy"]["mode"],
    "privacy": {
        "probe_mode": plan["privacy"]["probe_mode"],
        "hide_ip": plan["privacy"]["hide_ip"],
        "hide_via": plan["privacy"]["hide_via"],
    },
    "egress": {
        "target_ports_mode": plan["egress"]["target_ports_mode"],
        "acl_mode": plan["egress"]["acl_mode"],
        "upstream_configured": bool(plan["egress"]["upstream"]),
    },
    "user_count": len(users),
    "upstream_versions": plan["upstream_versions"],
}
write_secret(
    target / "install-report.json",
    json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
)

checksum_lines = []
for path in sorted(target.iterdir()):
    if path.name == "checksums.sha256" or not path.is_file():
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    checksum_lines.append(f"{digest}  {path.name}")
write_secret(target / "checksums.sha256", "\n".join(checksum_lines) + "\n")
PY
  find "$target_dir" -type f -exec chmod 0600 {} +
  chmod 0700 "$target_dir"
}

render_static_site() {
  local target_dir=$1
  local title=$2
  local python_bin
  python_bin=$(find_python) || die 'Для генерации сайта нужен Python 3.'
  [[ -d "$target_dir" && ! -L "$target_dir" ]] || die 'Небезопасный каталог сайта.'
  printf '%s\0' "$title" |
    "$python_bin" -c '
import html
import pathlib
import sys

title = sys.stdin.buffer.read().rstrip(b"\0").decode("utf-8")
target = pathlib.Path(sys.argv[1])
safe = html.escape(title)
page = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{safe}</title>
  <link rel="stylesheet" href="/assets/site.css">
</head>
<body>
  <main>
    <p class="eyebrow">SERVICE STATUS</p>
    <h1>{safe}</h1>
    <p class="lead">The requested service is online. This page is intentionally minimal.</p>
    <a class="button" href="/about.html">Learn more</a>
  </main>
  <script src="/assets/site.js"></script>
</body>
</html>
"""
about = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>About — {safe}</title><link rel="stylesheet" href="/assets/site.css"></head>
<body><main><p class="eyebrow">ABOUT</p><h1>{safe}</h1>
<p class="lead">A small independent web service.</p><a class="button" href="/">Home</a></main>
<script src="/assets/site.js"></script></body></html>
"""
css = """html{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;
font-family:Inter,ui-sans-serif,system-ui,sans-serif;background:#0b1020;color:#e8ecff}
main{width:min(760px,calc(100% - 40px));padding:56px;border:1px solid #25304f;border-radius:24px;
background:linear-gradient(145deg,#151d35,#0d1326);box-shadow:0 32px 80px #0008}
.eyebrow{color:#7dd3fc;font-size:.78rem;font-weight:800;letter-spacing:.18em}.lead{max-width:560px;color:#b8c2df;
font-size:1.12rem;line-height:1.7}h1{font-size:clamp(2.4rem,8vw,5.8rem);line-height:.95;margin:.25em 0}
.button{display:inline-block;margin-top:20px;padding:12px 18px;border-radius:999px;background:#7dd3fc;color:#07101d;
font-weight:800;text-decoration:none}@media(max-width:600px){main{padding:32px 24px}}"""
js = """document.documentElement.dataset.ready="true";"""
assets = target / "assets"
assets.mkdir(mode=0o755, exist_ok=True)
assets.chmod(0o755)
for path, content in [
    (target / "index.html", page),
    (target / "about.html", about),
    (assets / "site.css", css),
    (assets / "site.js", js),
]:
    path.write_text(content, encoding="utf-8", newline="\n")
    path.chmod(0o644)
' "$target_dir"
}

check_supported_platform() {
  [[ -r /etc/os-release ]] || die 'Не найден /etc/os-release.'
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == 'ubuntu' ]] || die 'Поддерживается только Ubuntu Server.'
  [[ "${VERSION_ID:-}" == '22.04' || "${VERSION_ID:-}" == '24.04' ]] ||
    die "Поддерживаются Ubuntu 22.04 и 24.04; обнаружена ${VERSION_ID:-unknown}."
  [[ "$(uname -s)" == 'Linux' ]] || die 'Поддерживается только Linux.'
  case "$(uname -m)" in
    x86_64 | aarch64 | arm64) ;;
    *) die "Архитектура $(uname -m) пока не поддерживается." ;;
  esac
  have systemctl || die 'Не найден systemd.'
}

install_dependencies() {
  info 'Устанавливаю проверенные системные зависимости.'
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
    ca-certificates curl dnsutils iproute2 openssl python3 tar xz-utils util-linux
  maybe_fail 'dependencies'
}

ensure_runtime_dir() {
  (( RUNTIME_CLAIMED == 0 )) || return 0
  (( LOCK_ACQUIRED == 1 )) || die 'Runtime dir нельзя захватывать без глобальной блокировки.'
  [[ ! -L "$RUNTIME_DIR" ]] || die 'Runtime dir является symlink.'
  if [[ -d "$RUNTIME_DIR" ]]; then
    [[ -f "${RUNTIME_DIR}/.owner" && ! -L "${RUNTIME_DIR}/.owner" ]] ||
      die 'Существующий runtime dir не имеет ownership marker.'
    grep -Fxq "$APP_ID" "${RUNTIME_DIR}/.owner" ||
      die 'Runtime dir принадлежит другому приложению.'
  else
    install -d -m 0700 -o root -g root -- "$RUNTIME_DIR"
    printf '%s\n' "$APP_ID" >"${RUNTIME_DIR}/.owner"
    chmod 0600 "${RUNTIME_DIR}/.owner"
  fi
  find "$RUNTIME_DIR" -mindepth 1 -maxdepth 1 ! -name '.owner' -exec rm -rf -- {} +
  RUNTIME_CLAIMED=1
}

cleanup_runtime_dir() {
  (( RUNTIME_CLAIMED == 1 )) || return 0
  [[ -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" ]] || return 0
  [[ -f "${RUNTIME_DIR}/.owner" && ! -L "${RUNTIME_DIR}/.owner" ]] ||
    { error 'Runtime ownership marker повреждён; cleanup остановлен.'; return 1; }
  grep -Fxq "$APP_ID" "${RUNTIME_DIR}/.owner" ||
    { error 'Runtime dir больше не принадлежит мастеру; cleanup остановлен.'; return 1; }
  find "$RUNTIME_DIR" -mindepth 1 -maxdepth 1 ! -name '.owner' \
    -exec rm -rf -- {} + || return 1
  RUNTIME_CLAIMED=0
}

cleanup_build_area() {
  (( BUILD_CLAIMED == 1 )) || return 0
  if [[ -n "$BUILD_SWAP_FILE" ]]; then
    if [[ "$BUILD_SWAP_FILE" == "${BUILD_ROOT}/"* ]]; then
      if swap_file_is_active "$BUILD_SWAP_FILE"; then
        if ! swapoff "$BUILD_SWAP_FILE" >/dev/null 2>&1; then
          die "Не удалось отключить временный swap ${BUILD_SWAP_FILE}."
          return 1
        fi
      fi
      rm -f -- "$BUILD_SWAP_FILE" || return 1
    fi
    BUILD_SWAP_FILE=''
  fi
  [[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] || return 0
  [[ -f "${BUILD_ROOT}/.owner" && ! -L "${BUILD_ROOT}/.owner" ]] ||
    { error 'Build ownership marker повреждён; cleanup остановлен.'; return 1; }
  grep -Fxq "$APP_ID" "${BUILD_ROOT}/.owner" ||
    { error 'Build root больше не принадлежит мастеру; cleanup остановлен.'; return 1; }
  rm -rf --one-file-system -- "$BUILD_ROOT" || return 1
  BUILD_CLAIMED=0
}

ensure_build_root() {
  (( BUILD_CLAIMED == 0 )) || return 0
  (( LOCK_ACQUIRED == 1 )) || die 'Build root нельзя захватывать без глобальной блокировки.'
  [[ ! -L "$BUILD_ROOT" ]] || die 'Build root является symlink.'
  if [[ -d "$BUILD_ROOT" ]]; then
    [[ -f "${BUILD_ROOT}/.owner" && ! -L "${BUILD_ROOT}/.owner" ]] ||
      die 'Существующий build root не имеет ownership marker.'
    grep -Fxq "$APP_ID" "${BUILD_ROOT}/.owner" ||
      die 'Build root принадлежит другому приложению.'
  else
    install -d -m 0700 -o root -g root -- "$BUILD_ROOT"
    printf '%s\n' "$APP_ID" >"${BUILD_ROOT}/.owner"
    chmod 0600 "${BUILD_ROOT}/.owner"
  fi
  local stale_swap
  while IFS= read -r -d '' stale_swap; do
    if swap_file_is_active "$stale_swap"; then
      swapoff "$stale_swap" >/dev/null 2>&1 ||
        die "Не удалось отключить оставшийся временный swap ${stale_swap}."
    fi
  done < <(find "$BUILD_ROOT" -mindepth 2 -maxdepth 2 -type f \
    -name 'temporary-build.swap' -print0)
  find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 ! -name '.owner' -exec rm -rf -- {} +
  BUILD_CLAIMED=1
}

swap_file_is_active() {
  local path=$1
  local active
  active=$(swapon --show=NAME --noheadings --raw 2>/dev/null) || return 1
  grep -Fxq "$path" <<<"$active"
}

cleanup_all() {
  local original_status=$?
  local failed=0
  local had_errexit=0
  [[ $- == *e* ]] && had_errexit=1
  set +e
  cleanup_runtime_dir || failed=1
  cleanup_build_area || failed=1
  (( had_errexit == 0 )) || set -e
  (( failed == 0 )) || error 'Не все временные ресурсы удалось очистить; проверьте runtime/build dir и swap.'
  if (( failed != 0 && original_status == 0 )); then
    exit 1
  fi
  exit "$original_status"
}

resolve_public_ipv4() {
  local endpoint value
  for endpoint in \
    'https://api4.ipify.org' \
    'https://ipv4.icanhazip.com' \
    'https://ifconfig.co/ip'; do
    value=$(curl -4fsS --max-time 8 "$endpoint" 2>/dev/null | tr -d '\r\n ' || true)
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 1
}

resolve_public_ipv6() {
  local endpoint value
  for endpoint in 'https://api6.ipify.org' 'https://ipv6.icanhazip.com'; do
    value=$(curl -6fsS --max-time 8 "$endpoint" 2>/dev/null | tr -d '\r\n ' || true)
    if [[ "$value" == *:* ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 1
}

validate_dns() {
  info "Проверяю DNS для ${DOMAIN}."
  local public_v4
  public_v4=$(resolve_public_ipv4) || die 'Не удалось определить публичный IPv4 VPS.'

  local -a records_v4=()
  mapfile -t records_v4 < <(dig +short A "$DOMAIN" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/')
  (( ${#records_v4[@]} > 0 )) || die "У домена ${DOMAIN} нет A-записи."
  local record
  for record in "${records_v4[@]}"; do
    [[ "$record" == "$public_v4" ]] ||
      die "A-запись ${DOMAIN} содержит посторонний IPv4 ${record}."
  done

  local -a records_v6=()
  mapfile -t records_v6 < <(dig +short AAAA "$DOMAIN" | awk '/:/')
  if (( ${#records_v6[@]} > 0 )); then
    local public_v6
    public_v6=$(resolve_public_ipv6) ||
      die "У ${DOMAIN} есть AAAA-запись, но VPS не имеет рабочего публичного IPv6."
    local python_bin
    python_bin=$(find_python) || die 'Для проверки IPv6 нужен Python 3.'
    if ! "$python_bin" - "$public_v6" "${records_v6[@]}" <<'PY'
import ipaddress
import sys

public = ipaddress.ip_address(sys.argv[1])
records = [ipaddress.ip_address(item) for item in sys.argv[2:]]
raise SystemExit(0 if records and all(item == public for item in records) else 1)
PY
    then
      die "Не все AAAA-записи ${DOMAIN} совпадают с публичным IPv6 VPS."
    fi
  fi
  success 'DNS указывает на этот VPS.'
}

service_is_active() {
  systemctl is-active --quiet "$SERVICE_NAME"
}

service_is_enabled() {
  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null
}

socket_lines() {
  local protocol=$1
  local port=$2
  if [[ "$protocol" == 'tcp' ]]; then
    ss -H -ltnp | awk -v suffix=":${port}" '$4 ~ suffix"$" {print}'
  else
    ss -H -lunp | awk -v suffix=":${port}" '$4 ~ suffix"$" {print}'
  fi
}

check_port_conflicts() {
  service_is_active && {
    info 'Управляемый сервис уже активен; его listener будет проверен после reload.'
    return 0
  }
  local occupied
  occupied=$(socket_lines tcp 443 || true)
  [[ -z "$occupied" ]] || die 'TCP/443 уже занят сторонним процессом. Мастер не перезаписывает чужой web stack.'
  if [[ "$HTTP3_ENABLED" == 'true' ]]; then
    occupied=$(socket_lines udp 443 || true)
    [[ -z "$occupied" ]] || die 'UDP/443 уже занят сторонним процессом; HTTP/3 нельзя включить безопасно.'
  fi
  if [[ "$OPEN_HTTP_PORT" == 'true' || "$AUTO_HTTPS_REDIRECTS" == 'true' ]]; then
    occupied=$(socket_lines tcp 80 || true)
    [[ -z "$occupied" ]] || die 'TCP/80 уже занят сторонним процессом; ACME/HTTPS redirect могут конфликтовать.'
  fi
}

check_unmanaged_conflicts() {
  if [[ -e "$MANIFEST_FILE" ]]; then
    [[ -f "$MANIFEST_FILE" && ! -L "$MANIFEST_FILE" ]] ||
      die 'Manifest мастера имеет небезопасный тип.'
    return 0
  fi

  local path
  for path in "$CONFIG_DIR" "$CADDY_BIN" "$SERVICE_FILE" "$WEB_ROOT"; do
    if [[ -e "$path" || -L "$path" ]]; then
      die "Обнаружен неуправляемый конфликт ${path}. Мастер не будет его перезаписывать."
    fi
  done
}

validate_existing_certificate() {
  [[ -f "$SOURCE_CERT_PATH" && -r "$SOURCE_CERT_PATH" ]] || die 'Сертификат не читается.'
  [[ -f "$SOURCE_KEY_PATH" && -r "$SOURCE_KEY_PATH" ]] || die 'Закрытый ключ не читается.'
  openssl x509 -in "$SOURCE_CERT_PATH" -noout >/dev/null 2>&1 || die 'Некорректный PEM-сертификат.'
  openssl pkey -in "$SOURCE_KEY_PATH" -noout >/dev/null 2>&1 || die 'Некорректный закрытый ключ.'
  openssl x509 -in "$SOURCE_CERT_PATH" -checkend 86400 -noout >/dev/null 2>&1 ||
    die 'Сертификат истёк или истечёт менее чем через 24 часа.'
  openssl x509 -in "$SOURCE_CERT_PATH" -checkhost "$DOMAIN" -noout >/dev/null 2>&1 ||
    die "Сертификат не содержит SAN для ${DOMAIN}."

  local cert_pub key_pub
  cert_pub=$(mktemp "${RUNTIME_DIR}/cert-pub.XXXXXX")
  key_pub=$(mktemp "${RUNTIME_DIR}/key-pub.XXXXXX")
  openssl x509 -in "$SOURCE_CERT_PATH" -pubkey -noout >"$cert_pub"
  openssl pkey -in "$SOURCE_KEY_PATH" -pubout >"$key_pub"
  cmp -s "$cert_pub" "$key_pub" || die 'Сертификат и закрытый ключ не образуют пару.'
}

verify_download() {
  local path=$1
  local expected=$2
  local actual
  actual=$(sha256sum "$path" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || die "SHA-256 не совпал для $(basename "$path")."
}

download_file() {
  local url=$1
  local target=$2
  curl -fL --retry 4 --retry-all-errors --connect-timeout 15 \
    --max-time 600 "$url" -o "$target"
}

prepare_source_built_caddy() {
  local build_dir=$1
  local arch go_arch go_sha xcaddy_sha
  arch=$(uname -m)
  case "$arch" in
    x86_64)
      go_arch='amd64'
      go_sha=$GO_AMD64_SHA256
      xcaddy_sha=$XCADDY_AMD64_SHA256
      ;;
    aarch64 | arm64)
      go_arch='arm64'
      go_sha=$GO_ARM64_SHA256
      xcaddy_sha=$XCADDY_ARM64_SHA256
      ;;
    *) die "Source build не поддерживает архитектуру ${arch}." ;;
  esac

  local go_archive="${build_dir}/go.tar.gz"
  local xcaddy_archive="${build_dir}/xcaddy.tar.gz"
  local go_url="https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"
  local xcaddy_url="https://github.com/caddyserver/xcaddy/releases/download/v${XCADDY_VERSION}/xcaddy_${XCADDY_VERSION}_linux_${go_arch}.tar.gz"

  info "Загружаю закреплённые Go ${GO_VERSION} и xcaddy ${XCADDY_VERSION}."
  download_file "$go_url" "$go_archive"
  verify_download "$go_archive" "$go_sha"
  download_file "$xcaddy_url" "$xcaddy_archive"
  verify_download "$xcaddy_archive" "$xcaddy_sha"

  install -d -m 0700 -- "${build_dir}/toolchain" "${build_dir}/xcaddy"
  tar -xzf "$go_archive" -C "${build_dir}/toolchain"
  tar -xzf "$xcaddy_archive" -C "${build_dir}/xcaddy"
  local go_bin="${build_dir}/toolchain/go/bin/go"
  local xcaddy_bin="${build_dir}/xcaddy/xcaddy"
  [[ -x "$go_bin" && -x "$xcaddy_bin" ]] || die 'Не удалось распаковать toolchain.'

  local available_kib swap_kib total_kib free_kib required_free_kib
  available_kib=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
  swap_kib=$(awk '/SwapTotal:/{print $2}' /proc/meminfo)
  total_kib=$((available_kib + swap_kib))
  free_kib=$(df -Pk "$BUILD_ROOT" | awk 'NR==2{print $4}')
  if (( total_kib < 1572864 )); then
    required_free_kib=5242880
    (( free_kib >= required_free_kib )) ||
      die 'Недостаточно диска для безопасной сборки на малом объёме RAM (нужно около 5 GiB свободно после распаковки toolchain).'
    BUILD_SWAP_FILE="${build_dir}/temporary-build.swap"
    info 'RAM меньше 1.5 GiB: создаю временный swap 2 GiB только на время сборки.'
    fallocate -l 2G "$BUILD_SWAP_FILE"
    chmod 0600 "$BUILD_SWAP_FILE"
    mkswap "$BUILD_SWAP_FILE" >/dev/null
    swapon "$BUILD_SWAP_FILE"
  else
    required_free_kib=3145728
    (( free_kib >= required_free_kib )) ||
      die 'Недостаточно диска для source build (нужно около 3 GiB свободно после распаковки toolchain).'
  fi

  info "Собираю Caddy ${CADDY_CORE_VERSION} с закреплённым naïve forwardproxy."
  (
    cd "$build_dir"
    export PATH="${build_dir}/toolchain/go/bin:${PATH}"
    export GOTOOLCHAIN=local
    export GOPATH="${build_dir}/gopath"
    export GOCACHE="${build_dir}/gocache"
    export CGO_ENABLED=0
    export GOMAXPROCS=1
    export GOFLAGS='-p=1'
    "$xcaddy_bin" build "$CADDY_CORE_VERSION" \
      --output "${build_dir}/caddy-candidate" \
      --with "github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_COMMIT}" >&2
  )
  if [[ -n "$BUILD_SWAP_FILE" ]]; then
    swapoff "$BUILD_SWAP_FILE"
    rm -f -- "$BUILD_SWAP_FILE"
    BUILD_SWAP_FILE=''
  fi
  PREPARED_CANDIDATE="${build_dir}/caddy-candidate"
}

prepare_upstream_prebuilt_caddy() {
  local build_dir=$1
  [[ "$(uname -m)" == 'x86_64' ]] ||
    die 'Upstream prebuilt asset существует только для Linux amd64.'
  warn 'Выбран upstream Caddy 2.11.2: он отстаёт от security-fix релизов Caddy 2.11.3/2.11.4.'
  local archive="${build_dir}/${CADDY_ARCHIVE_NAME}"
  download_file "$CADDY_ARCHIVE_URL" "$archive"
  verify_download "$archive" "$CADDY_ARCHIVE_SHA256"
  tar -xJf "$archive" -C "$build_dir"
  local candidate="${build_dir}/caddy-forwardproxy-naive/caddy"
  [[ -x "$candidate" ]] || chmod 0700 "$candidate"
  PREPARED_CANDIDATE=$candidate
}

prepare_candidate_binary() {
  ensure_runtime_dir
  ensure_build_root
  PREPARED_CANDIDATE=''
  local build_dir
  build_dir=$(mktemp -d "${BUILD_ROOT}/build.XXXXXX")
  chmod 0700 "$build_dir"
  if [[ "$SERVER_BUILD_MODE" == 'source_patched' ]]; then
    prepare_source_built_caddy "$build_dir"
  else
    prepare_upstream_prebuilt_caddy "$build_dir"
  fi
  local candidate=$PREPARED_CANDIDATE
  [[ -x "$candidate" ]] || die 'Кандидат Caddy не создан.'
  "$candidate" version >/dev/null
  caddy_has_forwardproxy "$candidate" ||
    die 'Собранный Caddy не содержит http.handlers.forward_proxy.'
  if [[ "$SERVER_BUILD_MODE" == 'source_patched' ]]; then
    grep -Fq "${CADDY_CORE_VERSION#v}" <<<"$("$candidate" version)" ||
      die 'Версия собранного Caddy не совпадает с закреплённой.'
  fi
  maybe_fail 'binary_staged'
}

ensure_service_identity() {
  if ! getent group "$SERVICE_GROUP" >/dev/null; then
    groupadd --system "$SERVICE_GROUP"
  fi
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system \
      --gid "$SERVICE_GROUP" \
      --home-dir "$CADDY_DATA_DIR" \
      --no-create-home \
      --shell /usr/sbin/nologin \
      --comment 'NaiveProxy Caddy service' \
      "$SERVICE_USER"
  fi
}

install_layout() {
  install -d -m 0750 -o root -g "$SERVICE_GROUP" -- "$CONFIG_DIR"
  install -d -m 0750 -o root -g "$SERVICE_GROUP" -- "$STATE_DIR"
  install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" -- "$CADDY_DATA_DIR" "$LOG_DIR"
  install -d -m 0700 -o root -g root -- "$BACKUP_ROOT"
  install -d -m 0755 -o root -g root -- "$WEB_ROOT"
}

render_service_unit() {
  local target=$1
  cat <<EOF >"$target"
[Unit]
Description=NaiveProxy Caddy forward proxy
Documentation=https://github.com/klzgrad/naiveproxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
Environment=HOME=${CADDY_DATA_DIR}
Environment=XDG_DATA_HOME=${CADDY_DATA_DIR}
Environment=XDG_CONFIG_HOME=${CADDY_DATA_DIR}
ExecStart=${CADDY_BIN} run --environ --config ${CADDY_CONFIG} --adapter caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${STATE_DIR} ${LOG_DIR}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$target"
}

validate_service_unit() {
  local unit=$1
  systemd-analyze verify "$unit" >/dev/null
}

safe_remove_managed_target() {
  local target=$1
  local allowed=0 item
  for item in \
    "$CONFIG_DIR" "$CADDY_BIN" "$SERVICE_FILE" "$WEB_ROOT" "$OUTPUT_DIR" \
    "$SELF_INSTALL_PATH" "$CADDY_DATA_DIR" "$LOG_DIR"; do
    [[ "$target" == "$item" ]] && allowed=1
  done
  (( allowed == 1 )) || die "Отказ удаления неуправляемого пути: ${target}"
  if [[ -L "$target" || -f "$target" ]]; then
    rm -f -- "$target"
  elif [[ -d "$target" ]]; then
    rm -rf --one-file-system -- "$target"
  fi
}

snapshot_target() {
  local label=$1
  local target=$2
  local payload="${CURRENT_BACKUP}/payload"
  if [[ -e "$target" || -L "$target" ]]; then
    cp -a -- "$target" "${payload}/${label}"
    printf '%s\n' "$label" >>"${CURRENT_BACKUP}/present.list"
  fi
}

begin_transaction() {
  FIREWALL_RULES_ADDED=()
  FIREWALL_RULES_REMOVED=()
  install -d -m 0700 -o root -g root -- "$BACKUP_ROOT"
  CURRENT_BACKUP=$(mktemp -d "${BACKUP_ROOT}/transaction-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  chmod 0700 "$CURRENT_BACKUP"
  install -d -m 0700 -- "${CURRENT_BACKUP}/payload"
  : >"${CURRENT_BACKUP}/present.list"

  service_is_active && SERVICE_WAS_ACTIVE=1 || SERVICE_WAS_ACTIVE=0
  service_is_enabled && SERVICE_WAS_ENABLED=1 || SERVICE_WAS_ENABLED=0
  printf 'service_active=%s\nservice_enabled=%s\n' \
    "$SERVICE_WAS_ACTIVE" "$SERVICE_WAS_ENABLED" >"${CURRENT_BACKUP}/service.state"

  snapshot_target 'config' "$CONFIG_DIR"
  snapshot_target 'binary' "$CADDY_BIN"
  snapshot_target 'unit' "$SERVICE_FILE"
  snapshot_target 'web' "$WEB_ROOT"
  snapshot_target 'clients' "$OUTPUT_DIR"
  snapshot_target 'self' "$SELF_INSTALL_PATH"
  snapshot_target 'caddy-data' "$CADDY_DATA_DIR"
  snapshot_target 'logs' "$LOG_DIR"

  install -d -m 0750 -o root -g "$SERVICE_GROUP" -- "$STATE_DIR"
  local transaction_tmp
  transaction_tmp=$(mktemp "${STATE_DIR}/.transaction.XXXXXX")
  printf '{"schema_version":1,"status":"in_progress","backup":%s}\n' \
    "$(printf '%s' "$CURRENT_BACKUP" | "$(find_python)" -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    >"$transaction_tmp"
  chown root:"$SERVICE_GROUP" "$transaction_tmp"
  chmod 0640 "$transaction_tmp"
  mv -fT "$transaction_tmp" "$TRANSACTION_FILE"

  # Arm immediately after the complete snapshot, before the first managed mutation.
  TRANSACTION_ARMED=1
  TRANSACTION_COMMITTED=0
  maybe_fail 'backup_created'
}

backup_contains() {
  local label=$1
  grep -Fxq "$label" "${CURRENT_BACKUP}/present.list"
}

restore_target() {
  local label=$1
  local target=$2
  safe_remove_managed_target "$target" || return 1
  if backup_contains "$label"; then
    cp -a -- "${CURRENT_BACKUP}/payload/${label}" "$target" || return 1
  else
    local rc=$?
    (( rc == 1 )) || return "$rc"
  fi
}

rollback_firewall_rules() {
  have ufw || return 0
  local failed=0
  FIREWALL_RULES_ADDED=()
  FIREWALL_RULES_REMOVED=()
  if [[ -n "$CURRENT_BACKUP" && -f "${CURRENT_BACKUP}/firewall.added" ]]; then
    mapfile -t FIREWALL_RULES_ADDED <"${CURRENT_BACKUP}/firewall.added"
  fi
  if [[ -n "$CURRENT_BACKUP" && -f "${CURRENT_BACKUP}/firewall.removed" ]]; then
    mapfile -t FIREWALL_RULES_REMOVED <"${CURRENT_BACKUP}/firewall.removed"
  fi
  local rule
  for rule in "${FIREWALL_RULES_ADDED[@]}"; do
    if ufw_rule_exists "$rule"; then
      ufw --force delete allow "$rule" comment "$APP_ID" >/dev/null 2>&1 || failed=1
    fi
  done
  for rule in "${FIREWALL_RULES_REMOVED[@]}"; do
    if ! ufw_rule_exists "$rule"; then
      ufw allow "$rule" comment "$APP_ID" >/dev/null 2>&1 || failed=1
    fi
  done
  (( failed == 0 ))
}

rollback_transaction() {
  (( TRANSACTION_ARMED == 1 && TRANSACTION_COMMITTED == 0 )) || return 0
  (( ROLLBACK_IN_PROGRESS == 0 )) || return 0
  ROLLBACK_IN_PROGRESS=1
  warn "Выполняю автоматический откат из ${CURRENT_BACKUP}."
  set +e
  local failed=0
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  service_is_active && failed=1
  restore_target 'config' "$CONFIG_DIR" || failed=1
  restore_target 'binary' "$CADDY_BIN" || failed=1
  restore_target 'unit' "$SERVICE_FILE" || failed=1
  restore_target 'web' "$WEB_ROOT" || failed=1
  restore_target 'clients' "$OUTPUT_DIR" || failed=1
  restore_target 'self' "$SELF_INSTALL_PATH" || failed=1
  restore_target 'caddy-data' "$CADDY_DATA_DIR" || failed=1
  restore_target 'logs' "$LOG_DIR" || failed=1
  rollback_firewall_rules || failed=1
  systemctl daemon-reload >/dev/null 2>&1 || failed=1
  if (( SERVICE_WAS_ENABLED == 1 )); then
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || failed=1
    service_is_enabled || failed=1
  else
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    service_is_enabled && failed=1
  fi
  if (( SERVICE_WAS_ACTIVE == 1 )); then
    systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || failed=1
    service_is_active || failed=1
  else
    service_is_active && failed=1
  fi
  if (( failed == 0 )); then
    rm -f -- "$TRANSACTION_FILE" || failed=1
  fi
  set -e
  ROLLBACK_IN_PROGRESS=0
  if (( failed != 0 )); then
    error "Откат завершился не полностью. Маркер ${TRANSACTION_FILE} сохранён; требуется повторное восстановление."
    return 1
  fi
  TRANSACTION_ARMED=0
  warn 'Откат управляемых файлов завершён. Установленные apt-пакеты и системный пользователь не удалялись.'
}

commit_transaction() {
  rm -f -- "$TRANSACTION_FILE"
  printf '%s\n' 'committed' >"${CURRENT_BACKUP}/status"
  TRANSACTION_COMMITTED=1
  TRANSACTION_ARMED=0
}

handle_error() {
  local exit_code=$1
  local line=$2
  local command=$3
  trap - ERR
  error "Сбой на строке ${line}; команда: ${command}."
  rollback_transaction || true
  exit "$exit_code"
}

handle_signal() {
  trap - ERR INT TERM
  error 'Выполнение прервано сигналом.'
  rollback_transaction || true
  exit 130
}

ufw_is_active() {
  have ufw || return 1
  local status
  status=$(ufw status 2>/dev/null) || return 1
  grep -Fq 'Status: active' <<<"${status%%$'\n'*}"
}

ufw_rule_exists() {
  local rule=$1
  local added
  added=$(ufw show added 2>/dev/null) || return 1
  grep -Fq "ufw allow ${rule} comment '${APP_ID}'" <<<"$added"
}

add_managed_ufw_rule() {
  local rule=$1
  ufw_rule_exists "$rule" && return 0
  FIREWALL_RULES_ADDED+=("$rule")
  [[ -n "$CURRENT_BACKUP" ]] && printf '%s\n' "$rule" >>"${CURRENT_BACKUP}/firewall.added"
  ufw allow "$rule" comment "$APP_ID" >/dev/null
}

remove_managed_ufw_rule() {
  local rule=$1
  ufw_rule_exists "$rule" || return 0
  FIREWALL_RULES_REMOVED+=("$rule")
  [[ -n "$CURRENT_BACKUP" ]] && printf '%s\n' "$rule" >>"${CURRENT_BACKUP}/firewall.removed"
  ufw --force delete allow "$rule" comment "$APP_ID" >/dev/null
}

apply_firewall() {
  [[ "$MANAGE_UFW" == 'true' ]] || {
    info 'Управление UFW отключено; проверьте firewall самостоятельно.'
    return 0
  }
  if ! ufw_is_active; then
    info 'UFW не активен; мастер не включает его автоматически.'
    return 0
  fi

  add_managed_ufw_rule '443/tcp'
  if [[ "$HTTP3_ENABLED" == 'true' ]]; then
    add_managed_ufw_rule '443/udp'
  else
    remove_managed_ufw_rule '443/udp'
  fi
  if [[ "$OPEN_HTTP_PORT" == 'true' ]]; then
    add_managed_ufw_rule '80/tcp'
  else
    remove_managed_ufw_rule '80/tcp'
  fi
  success 'Управляемые правила UFW синхронизированы.'
  maybe_fail 'firewall_changed'
}

install_file_atomically() {
  local source=$1
  local target=$2
  local mode=$3
  local owner=$4
  local group=$5
  local parent temp
  parent=$(dirname "$target")
  if [[ -e "$parent" || -L "$parent" ]]; then
    [[ -d "$parent" && ! -L "$parent" ]] ||
      die "Небезопасный родительский каталог для атомарной установки: ${parent}"
  else
    install -d -m 0755 -- "$parent"
  fi
  temp=$(mktemp "${parent}/.$(basename "$target").new.XXXXXX")
  install -m "$mode" -o "$owner" -g "$group" -- "$source" "$temp"
  mv -fT -- "$temp" "$target"
}

prepare_tls_assets() {
  if [[ "$TLS_MODE" != 'existing' ]]; then
    return 0
  fi
  validate_existing_certificate
  install -d -m 0750 -o root -g "$SERVICE_GROUP" -- "$(dirname "$MANAGED_CERT")"
  local cert_tmp key_tmp
  cert_tmp=$(mktemp "$(dirname "$MANAGED_CERT")/.fullchain.new.XXXXXX")
  key_tmp=$(mktemp "$(dirname "$MANAGED_KEY")/.privkey.new.XXXXXX")
  install -m 0644 -o root -g "$SERVICE_GROUP" -- "$SOURCE_CERT_PATH" "$cert_tmp"
  install -m 0640 -o root -g "$SERVICE_GROUP" -- "$SOURCE_KEY_PATH" "$key_tmp"
  mv -fT -- "$cert_tmp" "$MANAGED_CERT"
  mv -fT -- "$key_tmp" "$MANAGED_KEY"
}

replace_static_site() {
  if [[ "$DECOY_MODE" != 'static' ]]; then
    safe_remove_managed_target "$WEB_ROOT"
    return 0
  fi
  local parent stage old
  parent=$(dirname "$WEB_ROOT")
  install -d -m 0755 -- "$parent"
  stage=$(mktemp -d "${parent}/.naiveproxy-web.new.XXXXXX")
  chmod 0755 "$stage"
  render_static_site "$stage" "$DECOY_TITLE"
  old="${WEB_ROOT}.old.$$"
  if [[ -e "$WEB_ROOT" || -L "$WEB_ROOT" ]]; then
    [[ ! -e "$old" && ! -L "$old" ]] || die "Временный путь сайта уже существует: ${old}"
    mv -T -- "$WEB_ROOT" "$old"
  fi
  mv -T -- "$stage" "$WEB_ROOT"
  if [[ -e "$old" || -L "$old" ]]; then
    rm -rf --one-file-system -- "$old"
  fi
}

install_candidate_config() {
  local plan_file=$1
  local users_file=$2
  local caddy_file=$3
  install_file_atomically "$plan_file" "$SETTINGS_FILE" 0640 root "$SERVICE_GROUP"
  install_file_atomically "$users_file" "$USERS_FILE" 0640 root "$SERVICE_GROUP"
  install_file_atomically "$caddy_file" "$CADDY_CONFIG" 0640 root "$SERVICE_GROUP"
}

install_candidate_service() {
  local unit_temp
  unit_temp=$(mktemp "${RUNTIME_DIR}/naiveproxy-candidate.XXXXXX.service")
  render_service_unit "$unit_temp"
  validate_service_unit "$unit_temp"
  install_file_atomically "$unit_temp" "$SERVICE_FILE" 0644 root root
  systemctl daemon-reload
}

validate_live_candidate() {
  [[ -x "$CADDY_BIN" ]] || die 'Caddy binary не установлен.'
  caddy_has_forwardproxy "$CADDY_BIN" ||
    die 'Установленный Caddy потерял forwardproxy module.'
  chown root:"$SERVICE_GROUP" "$CADDY_CONFIG" "$SETTINGS_FILE" "$USERS_FILE"
  chmod 0640 "$CADDY_CONFIG" "$SETTINGS_FILE" "$USERS_FILE"

  local validation_log
  validation_log=$(mktemp "${RUNTIME_DIR}/caddy-validation.XXXXXX")
  chmod 0600 "$validation_log"
  if ! runuser -u "$SERVICE_USER" -- env \
    "HOME=${CADDY_DATA_DIR}" \
    "XDG_DATA_HOME=${CADDY_DATA_DIR}" \
    "XDG_CONFIG_HOME=${CADDY_DATA_DIR}" \
    "$CADDY_BIN" adapt --config "$CADDY_CONFIG" --adapter caddyfile \
      --validate >/dev/null 2>"$validation_log"; then
    die 'Caddy adapt/validate отклонил конфигурацию; stderr скрыт, чтобы не раскрыть credentials.'
    return 1
  fi
  : >"$validation_log"
  if ! runuser -u "$SERVICE_USER" -- env \
    "HOME=${CADDY_DATA_DIR}" \
    "XDG_DATA_HOME=${CADDY_DATA_DIR}" \
    "XDG_CONFIG_HOME=${CADDY_DATA_DIR}" \
    "$CADDY_BIN" validate --config "$CADDY_CONFIG" --adapter caddyfile \
      >/dev/null 2>"$validation_log"; then
    die 'Caddy validate отклонил конфигурацию; stderr скрыт, чтобы не раскрыть credentials.'
    return 1
  fi
  rm -f -- "$validation_log"
  maybe_fail 'config_validated'
}

install_self_copy() {
  local source_path=${BASH_SOURCE[0]}
  if [[ -f "$source_path" && ! -L "$source_path" ]]; then
    install_file_atomically "$source_path" "$SELF_INSTALL_PATH" 0755 root root
  else
    warn 'Мастер запущен из stdin; постоянная копия не установлена. Скачайте файл и запустите повторно.'
  fi
}

replace_client_bundle() {
  local plan_file=$1
  local users_file=$2
  local parent stage old
  parent=$(dirname "$OUTPUT_DIR")
  install -d -m 0700 -o root -g root -- "$parent"
  [[ ! -L "$parent" ]] || die 'Родительский каталог экспорта является symlink.'
  stage=$(mktemp -d "${parent}/.$(basename "$OUTPUT_DIR").new.XXXXXX")
  chmod 0700 "$stage"
  stage_client_bundle "$plan_file" "$users_file" "$stage"
  old="${OUTPUT_DIR}.old.$$"
  if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
    [[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || die 'Текущий каталог клиентов имеет небезопасный тип.'
    [[ ! -e "$old" && ! -L "$old" ]] || die 'Конфликт временного каталога клиентов.'
    mv -T -- "$OUTPUT_DIR" "$old"
  fi
  mv -T -- "$stage" "$OUTPUT_DIR"
  if [[ -e "$old" || -L "$old" ]]; then
    rm -rf --one-file-system -- "$old"
  fi
  chmod 0700 "$OUTPUT_DIR"
  find "$OUTPUT_DIR" -type f -exec chmod 0600 {} +
}

wait_for_service() {
  local _
  for _ in $(seq 1 30); do
    service_is_active && return 0
    sleep 1
  done
  systemctl status "$SERVICE_NAME" --no-pager -l >&2 || true
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
  die 'Сервис не перешёл в active.'
}

wait_for_tls_and_decoy() {
  local _ code
  for _ in $(seq 1 90); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
      --resolve "${DOMAIN}:443:127.0.0.1" \
      --connect-timeout 3 --max-time 8 \
      "https://${DOMAIN}/" 2>/dev/null || true)
    if [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
      return 0
    fi
    sleep 2
  done
  journalctl -u "$SERVICE_NAME" -n 100 --no-pager >&2 || true
  die 'TLS/decoy не вернули HTTP 2xx, 3xx или 4xx за 180 секунд.'
}

verify_h2_alpn() {
  local output
  output=$(mktemp "${RUNTIME_DIR}/openssl-alpn.XXXXXX")
  chmod 0600 "$output"
  timeout 15 openssl s_client \
    -connect '127.0.0.1:443' \
    -servername "$DOMAIN" -alpn h2 \
    </dev/null >"$output" 2>/dev/null || true
  if ! grep -Fq 'ALPN protocol: h2' "$output"; then
    rm -f -- "$output"
    die 'TLS listener не согласовал ALPN h2.'
  fi
  rm -f -- "$output"
}

verify_proxy_connect() {
  local username=${USERNAMES[0]}
  local password=${PASSWORDS[0]}
  local curl_config
  curl_config=$(mktemp "${RUNTIME_DIR}/curl-proxy.XXXXXX")
  chmod 0600 "$curl_config"
  {
    printf 'proxy = "https://%s:443"\n' "$DOMAIN"
    printf 'proxy-user = "%s:%s"\n' "$username" "$password"
    printf 'resolve = "%s:443:127.0.0.1"\n' "$DOMAIN"
    printf 'url = "https://example.com/"\n'
    printf 'output = "/dev/null"\n'
    printf 'silent\nshow-error\nfail\nconnect-timeout = 8\nmax-time = 30\n'
  } >"$curl_config"
  curl --config "$curl_config"
  rm -f -- "$curl_config"
}

can_run_default_proxy_health_check() {
  if [[ -z "$UPSTREAM_URL" && "$TARGET_PORTS_MODE" != 'unrestricted' ]]; then
    [[ " ${TARGET_PORTS} " == *' 443 '* ]] || return 1
  fi
  [[ "$ACL_MODE" == 'hardened' || "$ACL_MODE" == 'plugin_default' ]] || return 1
}

verify_proxy_connect_if_supported() {
  if can_run_default_proxy_health_check; then
    verify_proxy_connect
    success 'Авторизованный CONNECT к контрольному HTTPS-сайту работает.'
  else
    warn 'Полный CONNECT smoke пропущен: выбранные ACL/порты не гарантируют доступ к стандартной контрольной цели. TLS, конфигурация, H2 и listeners всё равно проверены.'
  fi
}

verify_listeners() {
  [[ -n "$(socket_lines tcp 443 || true)" ]] || die 'TCP/443 не слушается.'
  if [[ "$HTTP3_ENABLED" == 'true' ]]; then
    [[ -n "$(socket_lines udp 443 || true)" ]] || die 'HTTP/3 выбран, но UDP/443 не слушается.'
  else
    [[ -z "$(socket_lines udp 443 || true)" ]] ||
      die 'HTTP/3 отключён, но UDP/443 всё равно слушается.'
  fi
}

run_local_health_checks() {
  info 'Жду TLS и выполняю локальные проверки.'
  wait_for_service
  wait_for_tls_and_decoy
  verify_h2_alpn
  verify_listeners
  verify_proxy_connect_if_supported
  success 'TLS, H2 и listener работают.'
  maybe_fail 'local_health'
}

write_manifest() {
  local target=$1
  local python_bin
  python_bin=$(find_python) || die 'Для manifest нужен Python 3.'
  "$python_bin" - "$target" "$APP_VERSION" "$CONFIG_DIR" \
    "$CADDY_BIN" "$CADDY_CONFIG" "$SETTINGS_FILE" "$USERS_FILE" \
    "$SERVICE_FILE" "$SELF_INSTALL_PATH" "$MANAGED_CERT" "$MANAGED_KEY" \
    "$WEB_ROOT" "$OUTPUT_DIR" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
from datetime import datetime, timezone

target = pathlib.Path(sys.argv[1])
wizard_version = sys.argv[2]
config_root = pathlib.Path(sys.argv[3])
roots = [pathlib.Path(value) for value in sys.argv[4:]]
resources = {}

def add_resource(path):
    if path.is_symlink() or not path.exists():
        return
    stat = path.stat()
    entry = {
        "kind": "directory" if path.is_dir() else "file",
        "mode": oct(stat.st_mode & 0o777),
        "uid": stat.st_uid,
        "gid": stat.st_gid,
    }
    if path.is_file():
        entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    resources[str(path)] = entry

add_resource(config_root)
for root in roots:
    add_resource(root)
    if root.is_dir() and not root.is_symlink():
        for path in sorted(root.rglob("*")):
            add_resource(path)
document = {
    "schema_version": 1,
    "owner": "naiveproxy-server-wizard",
    "wizard_version": wizard_version,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "resources": resources,
}
target.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
target.chmod(0o640)
PY
}

install_manifest() {
  local temp
  temp=$(mktemp "${RUNTIME_DIR}/manifest.XXXXXX")
  write_manifest "$temp"
  install_file_atomically "$temp" "$MANIFEST_FILE" 0640 root "$SERVICE_GROUP"
}

verify_manifest_drift() {
  [[ -f "$MANIFEST_FILE" && ! -L "$MANIFEST_FILE" ]] || return 0
  local python_bin
  python_bin=$(find_python) || die 'Для проверки drift нужен Python 3.'
  "$python_bin" - "$MANIFEST_FILE" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
bad = []
for name, expected in manifest.get("resources", {}).items():
    path = pathlib.Path(name)
    expected_kind = expected.get("kind", "file")
    kind_matches = path.is_dir() if expected_kind == "directory" else path.is_file()
    if not kind_matches or path.is_symlink():
        bad.append(name)
        continue
    stat = path.stat()
    metadata_matches = (
        oct(stat.st_mode & 0o777) == expected.get("mode")
        and stat.st_uid == expected.get("uid")
        and stat.st_gid == expected.get("gid")
    )
    content_matches = (
        expected_kind == "directory"
        or hashlib.sha256(path.read_bytes()).hexdigest() == expected.get("sha256")
    )
    if not metadata_matches or not content_matches:
        bad.append(name)
if bad:
    for item in bad:
        print(item)
    raise SystemExit(2)
PY
}

prepare_plan_artifacts() {
  ensure_runtime_dir
  local plan_file users_file caddy_file
  plan_file=$(mktemp "${RUNTIME_DIR}/plan.XXXXXX")
  users_file=$(mktemp "${RUNTIME_DIR}/users.XXXXXX")
  caddy_file=$(mktemp "${RUNTIME_DIR}/Caddyfile.XXXXXX")
  write_plan_json "$plan_file"
  write_users_file "$users_file"
  render_caddyfile "$plan_file" "$users_file" >"$caddy_file"
  chmod 0600 "$plan_file" "$users_file" "$caddy_file"
  printf '%s\n%s\n%s\n' "$plan_file" "$users_file" "$caddy_file"
}

apply_installation() {
  local candidate_binary=$1
  local plan_file=$2
  local users_file=$3
  local caddy_file=$4

  # The service account is intentionally outside the managed rollback boundary.
  # It must exist before begin_transaction creates group-owned transaction state.
  ensure_service_identity
  begin_transaction
  install_layout
  prepare_tls_assets
  replace_static_site
  install_file_atomically "$candidate_binary" "$CADDY_BIN" 0755 root root
  install_candidate_config "$plan_file" "$users_file" "$caddy_file"
  maybe_fail 'config_committed'
  install_candidate_service
  validate_live_candidate
  apply_firewall
  install_self_copy

  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  maybe_fail 'service_started'
  run_local_health_checks

  replace_client_bundle "$plan_file" "$users_file"
  maybe_fail 'client_bundle_written'
  install_manifest
  commit_transaction
  success "Установка завершена. Клиентские файлы: ${OUTPUT_DIR}"
}

prompt_domain() {
  local default_value=${1:-}
  local value
  while true; do
    value=$(prompt_value 'Домен с готовой A/AAAA-записью' "$default_value")
    value=${value,,}
    if is_valid_domain "$value"; then
      DOMAIN=$value
      return 0
    fi
    warn 'Введите полноценный домен, например proxy.example.com.'
  done
}

prompt_acme_email() {
  local default_value=${1:-}
  local value
  while true; do
    value=$(prompt_value 'Email для уведомлений ACME (можно оставить пустым)' "$default_value")
    if is_valid_email_or_empty "$value"; then
      ACME_EMAIL=$value
      return 0
    fi
    warn 'Некорректный email.'
  done
}

prompt_count() {
  local label=$1
  local default_value=${2:-1}
  local value
  while true; do
    value=$(prompt_value "$label" "$default_value")
    if is_valid_count "$value"; then
      printf '%s' "$((10#$value))"
      return 0
    fi
    warn 'Введите число от 1 до 500.'
  done
}

prompt_positive_int() {
  local label=$1
  local default_value=$2
  local value
  while true; do
    value=$(prompt_value "$label" "$default_value")
    if is_valid_positive_int "$value"; then
      printf '%s' "$((10#$value))"
      return 0
    fi
    warn 'Введите положительное целое число.'
  done
}

prompt_duration() {
  local label=$1
  local default_value=$2
  local value
  while true; do
    value=$(prompt_value "$label" "$default_value")
    if is_valid_duration "$value"; then
      printf '%s' "$value"
      return 0
    fi
    warn 'Используйте формат 500ms, 30s, 2m или 1h.'
  done
}

collect_manual_users() {
  local count=$1
  USERNAMES=()
  PASSWORDS=()
  local index username password
  for ((index = 1; index <= count; index++)); do
    while true; do
      username=$(prompt_value "Логин пользователя ${index}")
      is_valid_username "$username" || {
        warn 'Логин: 1–64 символа A-Z, a-z, 0-9, точка, _ или -.'
        continue
      }
      username_exists "$username" && {
        warn 'Такой логин уже добавлен.'
        continue
      }
      break
    done
    while true; do
      password=$(prompt_secret "Пароль пользователя ${username}")
      is_valid_password "$password" || {
        warn 'Пароль: 12–128 URI-safe ASCII символов без пробелов, кавычек и двоеточия.'
        continue
      }
      break
    done
    USERNAMES+=("$username")
    PASSWORDS+=("$password")
  done
}

collect_imported_users() {
  local path
  while true; do
    path=$(prompt_value 'Абсолютный путь к TSV-файлу login<TAB>password')
    if is_safe_absolute_path "$path" && [[ -f "$path" && ! -L "$path" ]]; then
      load_users "$path"
      return 0
    fi
    warn 'Нужен обычный абсолютный файл, не symlink.'
  done
}

collect_users() {
  local allow_keep=${1:-false}
  local choice count prefix
  local -a labels=(
    'Сгенерировать логины и стойкие пароли'
    'Ввести логины и пароли вручную'
    'Импортировать защищённый TSV'
  )
  if [[ "$allow_keep" == 'true' && ${#USERNAMES[@]} -gt 0 ]]; then
    labels+=("Сохранить текущих пользователей (${#USERNAMES[@]})")
  fi
  choice=$(menu 'Учётные данные' "${labels[@]}")
  case "$choice" in
    1)
      count=$(prompt_count 'Количество пользователей' '1')
      while true; do
        prefix=$(prompt_value 'Префикс логинов' 'user')
        is_valid_username "$prefix" && break
        warn 'Недопустимый префикс.'
      done
      create_generated_users "$count" "$prefix"
      ;;
    2)
      count=$(prompt_count 'Количество пользователей' '1')
      collect_manual_users "$count"
      ;;
    3)
      collect_imported_users
      ;;
    4)
      [[ "$allow_keep" == 'true' ]] || die 'Некорректный выбор пользователей.'
      validate_user_arrays || die 'Текущий набор пользователей повреждён.'
      ;;
    *) die 'Некорректный выбор пользователей.' ;;
  esac
}

collect_tls() {
  local choice
  choice=$(menu 'TLS-сертификат' \
    'Автоматический публичный сертификат Caddy/ACME' \
    'Существующие fullchain.pem и private key')
  if [[ "$choice" == '1' ]]; then
    TLS_MODE='acme'
    SOURCE_CERT_PATH=''
    SOURCE_KEY_PATH=''
    prompt_acme_email "$ACME_EMAIL"
  else
    TLS_MODE='existing'
    while true; do
      SOURCE_CERT_PATH=$(prompt_value 'Абсолютный путь к fullchain.pem' "$SOURCE_CERT_PATH")
      is_safe_absolute_path "$SOURCE_CERT_PATH" && break
      warn 'Некорректный абсолютный путь.'
    done
    while true; do
      SOURCE_KEY_PATH=$(prompt_value 'Абсолютный путь к private key' "$SOURCE_KEY_PATH")
      is_safe_absolute_path "$SOURCE_KEY_PATH" && break
      warn 'Некорректный абсолютный путь.'
    done
    ACME_EMAIL=''
  fi
}

collect_transport() {
  local choice
  choice=$(menu 'Транспорт' \
    'HTTPS / HTTP/2 (TCP 443)' \
    'HTTPS / HTTP/2 + QUIC / HTTP/3 (TCP и UDP 443)')
  if [[ "$choice" == '1' ]]; then
    HTTP3_ENABLED='false'
  else
    HTTP3_ENABLED='true'
  fi
}

collect_decoy() {
  local choice
  choice=$(menu 'Обычный сайт на том же домене' \
    'Встроенный многофайловый сайт-заглушка' \
    'Reverse proxy на существующий HTTPS-сайт' \
    'Перенаправление на другой HTTPS-сайт' \
    'Нейтральный ответ 404')
  case "$choice" in
    1)
      DECOY_MODE='static'
      DECOY_UPSTREAM=''
      DECOY_REDIRECT=''
      DECOY_TITLE=$(prompt_value 'Заголовок сайта' "${DECOY_TITLE:-Welcome}")
      ;;
    2)
      DECOY_MODE='reverse_proxy'
      while true; do
        DECOY_UPSTREAM=$(prompt_value 'HTTPS URL upstream-сайта' "$DECOY_UPSTREAM")
        is_valid_decoy_url "$DECOY_UPSTREAM" && break
        warn 'Нужен HTTPS URL без пробелов и кавычек.'
      done
      ;;
    3)
      DECOY_MODE='redirect'
      while true; do
        DECOY_REDIRECT=$(prompt_value 'HTTPS URL перенаправления' "$DECOY_REDIRECT")
        is_valid_decoy_url "$DECOY_REDIRECT" && break
        warn 'Нужен HTTPS URL без пробелов и кавычек.'
      done
      ;;
    4)
      DECOY_MODE='respond'
      ;;
  esac
}

collect_target_ports() {
  local choice value
  choice=$(menu 'Разрешённые порты назначения через proxy' \
    'Только web: 80 и 443 (рекомендуется)' \
    'Расширенный безопасный набор' \
    'Собственный список' \
    'Без ограничения портов (опаснее)')
  case "$choice" in
    1)
      TARGET_PORTS_MODE='web'
      TARGET_PORTS='80 443'
      ;;
    2)
      TARGET_PORTS_MODE='common'
      TARGET_PORTS='53 80 123 443 465 587 853 993 995 5222 5223 8080 8443'
      ;;
    3)
      TARGET_PORTS_MODE='custom'
      while true; do
        value=$(prompt_value 'Порты через пробел или запятую' "$TARGET_PORTS")
        if validate_port_list "$value"; then
          TARGET_PORTS=$(normalize_space_list "$value")
          break
        fi
        warn 'Некорректный список портов.'
      done
      ;;
    4)
      TARGET_PORTS_MODE='unrestricted'
      TARGET_PORTS=''
      warn 'Без ports-ограничения пользователи смогут обращаться к любому внешнему TCP-порту.'
      ;;
  esac
}

collect_acl() {
  local choice value
  choice=$(menu 'ACL назначения' \
    'Усиленная блокировка private/link-local/metadata (рекомендуется)' \
    'Усиленная блокировка + собственный deny-list' \
    'Разрешать только собственный allow-list' \
    'Встроенный ACL плагина')
  case "$choice" in
    1)
      ACL_MODE='hardened'
      ACL_CUSTOM=''
      ;;
    2)
      ACL_MODE='custom_deny'
      while true; do
        value=$(prompt_value 'CIDR/домены для дополнительной блокировки')
        if validate_acl_list "$value"; then
          ACL_CUSTOM=$(normalize_space_list "$value")
          break
        fi
        warn 'Некорректный ACL.'
      done
      ;;
    3)
      ACL_MODE='allowlist'
      while true; do
        value=$(prompt_value 'Разрешённые CIDR/домены')
        if validate_acl_list "$value"; then
          ACL_CUSTOM=$(normalize_space_list "$value")
          break
        fi
        warn 'Некорректный ACL.'
      done
      ;;
    4)
      ACL_MODE='plugin_default'
      ACL_CUSTOM=''
      warn 'Встроенный ACL закрывает не все private/metadata диапазоны.'
      ;;
  esac
}

collect_probe_and_pac() {
  local choice
  choice=$(menu 'Probe resistance' \
    'Неверная авторизация незаметно попадает на обычный сайт' \
    'Секретный домен для browser-auth challenge')
  if [[ "$choice" == '1' ]]; then
    PROBE_MODE='fallthrough'
    PROBE_SECRET=''
  else
    PROBE_MODE='secret_domain'
    while true; do
      PROBE_SECRET=$(prompt_secret 'Secret-domain (ввод скрыт)')
      is_valid_domain "$PROBE_SECRET" && break
      warn 'Некорректный secret-domain.'
    done
  fi

  if confirm 'Создать секретный PAC endpoint?' 'no'; then
    PAC_ENABLED='true'
    PAC_PATH="/$(generate_secret_label)/proxy.pac"
  else
    PAC_ENABLED='false'
    PAC_PATH=''
  fi
}

collect_upstream() {
  local choice
  choice=$(menu 'Маршрут исходящего proxy-трафика' \
    'Напрямую с этого VPS' \
    'Через следующий HTTPS/SOCKS5 proxy hop')
  if [[ "$choice" == '1' ]]; then
    UPSTREAM_URL=''
  else
    while true; do
      UPSTREAM_URL=$(prompt_secret 'Upstream URL (ввод скрыт; значение сохранится в root-owned config)')
      is_valid_upstream_url "$UPSTREAM_URL" && break
      warn 'Разрешены https://remote или http/socks5 на 127.0.0.1 без пробелов и кавычек.'
    done
    TARGET_PORTS_MODE='unrestricted'
    TARGET_PORTS=''
    ACL_MODE='plugin_default'
    ACL_CUSTOM=''
    warn 'Upstream несовместим с ports/ACL плагина; эти ограничения отключены.'
  fi
}

collect_quick_configuration() {
  local existing=${1:-false}
  INSTALL_MODE='quick'
  SERVER_BUILD_MODE='source_patched'
  prompt_domain "$DOMAIN"
  TLS_MODE='acme'
  prompt_acme_email "$ACME_EMAIL"
  if [[ "$existing" == 'true' ]]; then
    validate_user_arrays || die 'Текущий набор пользователей повреждён.'
    info "Быстрый режим сохраняет ${#USERNAMES[@]} текущих пользователей и их пароли."
  else
    local count prefix
    count=$(prompt_count 'Количество пользователей' '1')
    prefix=$(prompt_value 'Префикс логинов' 'user')
    create_generated_users "$count" "$prefix"
  fi
  HTTP3_ENABLED='true'
  AUTO_HTTPS_REDIRECTS='true'
  DECOY_MODE='static'
  DECOY_TITLE='Web Service'
  PROBE_MODE='fallthrough'
  PAC_ENABLED='false'
  HIDE_IP='true'
  HIDE_VIA='true'
  TARGET_PORTS_MODE='web'
  TARGET_PORTS='80 443'
  ACL_MODE='hardened'
  ACL_CUSTOM=''
  UPSTREAM_URL=''
  DIAL_TIMEOUT='30s'
  MAX_IDLE_CONNS='256'
  MAX_IDLE_CONNS_PER_HOST='8'
  MANAGE_UFW='true'
  OPEN_HTTP_PORT='true'
}

collect_guided_configuration() {
  local allow_keep=${1:-false}
  INSTALL_MODE='guided'
  SERVER_BUILD_MODE='source_patched'
  prompt_domain "$DOMAIN"
  collect_tls
  collect_transport
  collect_users "$allow_keep"
  collect_decoy
  collect_target_ports
  collect_acl
  collect_probe_and_pac
  HIDE_IP='true'
  HIDE_VIA='true'
  UPSTREAM_URL=''
  DIAL_TIMEOUT='30s'
  MAX_IDLE_CONNS='256'
  MAX_IDLE_CONNS_PER_HOST='8'
  MANAGE_UFW='true'
  OPEN_HTTP_PORT='true'
}

collect_expert_configuration() {
  local allow_keep=${1:-false}
  INSTALL_MODE='expert'
  prompt_domain "$DOMAIN"
  collect_tls
  collect_transport
  collect_users "$allow_keep"
  collect_decoy
  collect_probe_and_pac
  collect_upstream
  if [[ -z "$UPSTREAM_URL" ]]; then
    collect_target_ports
    collect_acl
  fi
  confirm 'Скрывать IP пользователя в Forwarded?' 'yes' && HIDE_IP='true' || HIDE_IP='false'
  confirm 'Удалять Via header?' 'yes' && HIDE_VIA='true' || HIDE_VIA='false'
  confirm 'Оставить автоматический HTTP→HTTPS redirect?' 'yes' &&
    AUTO_HTTPS_REDIRECTS='true' || AUTO_HTTPS_REDIRECTS='false'
  confirm 'Открывать TCP/80 в UFW?' 'yes' && OPEN_HTTP_PORT='true' || OPEN_HTTP_PORT='false'
  confirm 'Синхронизировать правила активного UFW?' 'yes' && MANAGE_UFW='true' || MANAGE_UFW='false'
  DIAL_TIMEOUT=$(prompt_duration 'Таймаут подключения к сайту назначения' "$DIAL_TIMEOUT")
  MAX_IDLE_CONNS=$(prompt_positive_int 'Максимум idle-соединений всего' "$MAX_IDLE_CONNS")
  MAX_IDLE_CONNS_PER_HOST=$(prompt_positive_int 'Максимум idle-соединений на host' "$MAX_IDLE_CONNS_PER_HOST")
  local build_choice
  if [[ "$(uname -m)" != 'x86_64' ]]; then
    SERVER_BUILD_MODE='source_patched'
    info 'Для arm64 доступна только актуальная source build; legacy upstream asset опубликован лишь для amd64.'
  else
    build_choice=$(menu 'Сборка Caddy' \
      "Caddy ${CADDY_CORE_VERSION} + pinned plugin commit (рекомендуется)" \
      "Официальный upstream asset ${CADDY_RELEASE_TAG} (устаревший Caddy, только amd64)")
    if [[ "$build_choice" == '1' ]]; then
      SERVER_BUILD_MODE='source_patched'
    else
      SERVER_BUILD_MODE='upstream_prebuilt'
    fi
  fi
}

show_plan() {
  printf '\nПлан установки\n' >&2
  printf '  Домен: %s\n' "$DOMAIN" >&2
  printf '  Listener: TCP/443%s\n' \
    "$( [[ "$HTTP3_ENABLED" == 'true' ]] && printf ' + UDP/443' || true )" >&2
  printf '  TLS: %s\n' "$TLS_MODE" >&2
  printf '  Пользователей: %d\n' "${#USERNAMES[@]}" >&2
  printf '  Сайт: %s\n' "$DECOY_MODE" >&2
  printf '  Probe resistance: %s\n' "$PROBE_MODE" >&2
  printf '  PAC: %s\n' "$PAC_ENABLED" >&2
  printf '  Порты назначения: %s\n' "$TARGET_PORTS_MODE" >&2
  printf '  ACL: %s\n' "$ACL_MODE" >&2
  printf '  Upstream hop: %s\n' "$( [[ -n "$UPSTREAM_URL" ]] && printf 'настроен' || printf 'нет' )" >&2
  printf '  UFW: %s\n' "$MANAGE_UFW" >&2
  printf '  Caddy: %s\n' "$SERVER_BUILD_MODE" >&2
  printf '  Клиентские секреты: %s (права 0700/0600)\n\n' "$OUTPUT_DIR" >&2
}

stage_installed_binary() {
  [[ -x "$CADDY_BIN" && ! -L "$CADDY_BIN" ]] || return 1
  caddy_has_forwardproxy "$CADDY_BIN" || return 1
  local installed_version
  installed_version=$("$CADDY_BIN" version 2>/dev/null) || return 1
  if [[ "$SERVER_BUILD_MODE" == 'source_patched' ]]; then
    grep -Fq "${CADDY_CORE_VERSION}" <<<"$installed_version" || return 1
  else
    grep -Fq 'v2.11.2' <<<"$installed_version" || return 1
  fi
  ensure_runtime_dir
  local candidate
  candidate=$(mktemp "${RUNTIME_DIR}/caddy-existing.XXXXXX")
  install -m 0700 -- "$CADDY_BIN" "$candidate"
  printf '%s' "$candidate"
}

confirm_drift_if_needed() {
  local drift_output
  if ! drift_output=$(verify_manifest_drift 2>&1); then
    warn 'Управляемые файлы изменены вне мастера:'
    printf '%s\n' "$drift_output" >&2
    confirm 'Принять текущее состояние и продолжить с перезаписью?' 'no' ||
      die 'Операция отменена из-за config drift.'
  fi
}

run_preflight() {
  check_supported_platform
  check_unmanaged_conflicts
  check_port_conflicts
  validate_dns
  if [[ "$TLS_MODE" == 'existing' ]]; then
    validate_existing_certificate
  fi
  success 'Preflight завершён без блокирующих ошибок.'
}

run_install_flow() {
  local existing='false'
  if [[ -f "$SETTINGS_FILE" && -f "$USERS_FILE" ]]; then
    existing='true'
    load_settings
    load_users
    confirm_drift_if_needed
  fi

  local mode
  mode=$(menu 'Режим настройки' \
    'Быстрый — минимум вопросов и безопасные значения' \
    'Пошаговый — основные варианты' \
    'Экспертный — все поддерживаемые параметры')
  case "$mode" in
    1) collect_quick_configuration "$existing" ;;
    2) collect_guided_configuration "$existing" ;;
    3) collect_expert_configuration "$existing" ;;
  esac

  validate_settings
  validate_user_arrays || die 'Невалидный набор пользователей.'
  show_plan
  confirm 'Применить этот план?' 'no' || die 'Установка отменена.'

  install_dependencies
  run_preflight

  local candidate_binary
  if [[ "$existing" == 'true' ]]; then
    candidate_binary=$(stage_installed_binary || true)
  fi
  if [[ -z "${candidate_binary:-}" ]]; then
    prepare_candidate_binary
    candidate_binary=$PREPARED_CANDIDATE
  fi

  local -a artifacts=()
  mapfile -t artifacts < <(prepare_plan_artifacts)
  (( ${#artifacts[@]} == 3 )) || die 'Не удалось подготовить plan artifacts.'
  apply_installation "$candidate_binary" "${artifacts[0]}" "${artifacts[1]}" "${artifacts[2]}"
}

append_generated_users() {
  local count=$1
  local prefix=$2
  local index=1 added=0 username
  while (( added < count )); do
    printf -v username '%s-%03d' "$prefix" "$index"
    ((++index))
    username_exists "$username" && continue
    is_valid_username "$username" || die "Невалидное сгенерированное имя: ${username}"
    USERNAMES+=("$username")
    PASSWORDS+=("$(generate_password)")
    ((++added))
  done
}

append_manual_users() {
  local count=$1
  local index username password
  for ((index = 1; index <= count; index++)); do
    while true; do
      username=$(prompt_value "Новый логин ${index}")
      is_valid_username "$username" || {
        warn 'Недопустимый логин.'
        continue
      }
      username_exists "$username" && {
        warn 'Такой логин уже существует.'
        continue
      }
      break
    done
    while true; do
      password=$(prompt_secret "Пароль ${username}")
      is_valid_password "$password" && break
      warn 'Пароль не соответствует безопасному формату.'
    done
    USERNAMES+=("$username")
    PASSWORDS+=("$password")
  done
}

apply_state_change() {
  local action_label=$1
  validate_settings
  validate_user_arrays || die 'Невалидный набор пользователей.'
  show_plan
  confirm "${action_label}?" 'no' || die 'Операция отменена.'
  confirm_drift_if_needed
  check_port_conflicts

  local candidate_binary
  candidate_binary=$(stage_installed_binary) || die 'Установленный Caddy не прошёл проверку.'
  local -a artifacts=()
  mapfile -t artifacts < <(prepare_plan_artifacts)
  (( ${#artifacts[@]} == 3 )) || die 'Не удалось подготовить plan artifacts.'
  apply_installation "$candidate_binary" "${artifacts[0]}" "${artifacts[1]}" "${artifacts[2]}"
}

add_users_flow() {
  load_settings
  load_users
  local choice count prefix
  choice=$(menu 'Добавление пользователей' \
    'Сгенерировать автоматически' \
    'Ввести вручную')
  count=$(prompt_count 'Сколько пользователей добавить' '1')
  (( ${#USERNAMES[@]} + count <= 500 )) || die 'Итоговое количество превысит 500.'
  if [[ "$choice" == '1' ]]; then
    while true; do
      prefix=$(prompt_value 'Префикс новых логинов' 'user')
      is_valid_username "$prefix" && break
      warn 'Недопустимый префикс.'
    done
    append_generated_users "$count" "$prefix"
  else
    append_manual_users "$count"
  fi
  apply_state_change 'Добавить пользователей и перезагрузить конфигурацию'
}

remove_user_flow() {
  load_settings
  load_users
  (( ${#USERNAMES[@]} > 1 )) || die 'Нельзя удалить единственного пользователя.'
  local value index=-1 current
  value=$(prompt_value 'Точный логин для удаления')
  for current in "${!USERNAMES[@]}"; do
    [[ "${USERNAMES[$current]}" == "$value" ]] && index=$current
  done
  (( index >= 0 )) || die 'Пользователь не найден.'
  unset 'USERNAMES[index]' 'PASSWORDS[index]'
  USERNAMES=("${USERNAMES[@]}")
  PASSWORDS=("${PASSWORDS[@]}")
  apply_state_change "Удалить пользователя ${value}"
}

rotate_user_flow() {
  load_settings
  load_users
  local value index=-1 current choice password
  value=$(prompt_value 'Точный логин для смены пароля')
  for current in "${!USERNAMES[@]}"; do
    [[ "${USERNAMES[$current]}" == "$value" ]] && index=$current
  done
  (( index >= 0 )) || die 'Пользователь не найден.'
  choice=$(menu 'Новый пароль' 'Сгенерировать автоматически' 'Ввести вручную')
  if [[ "$choice" == '1' ]]; then
    password=$(generate_password)
  else
    while true; do
      password=$(prompt_secret "Новый пароль ${value}")
      is_valid_password "$password" && break
      warn 'Пароль не соответствует безопасному формату.'
    done
  fi
  PASSWORDS[index]=$password
  apply_state_change "Сменить пароль пользователя ${value}"
}

export_clients_flow() {
  load_settings
  load_users
  confirm_drift_if_needed
  confirm "Пересоздать защищённый клиентский bundle в ${OUTPUT_DIR}?" 'yes' ||
    die 'Экспорт отменён.'
  begin_transaction
  replace_client_bundle "$SETTINGS_FILE" "$USERS_FILE"
  commit_transaction
  success "Клиентские файлы обновлены: ${OUTPUT_DIR}"
}

show_installation_status() {
  load_settings
  load_users
  printf '\nСтатус %s\n' "$APP_NAME"
  printf 'Домен: %s\n' "$DOMAIN"
  printf 'Пользователей: %d\n' "${#USERNAMES[@]}"
  printf 'HTTP/3: %s\n' "$HTTP3_ENABLED"
  printf 'Сервис active: %s\n' "$(service_is_active && printf yes || printf no)"
  printf 'Сервис enabled: %s\n' "$(service_is_enabled && printf yes || printf no)"
  if [[ -x "$CADDY_BIN" ]]; then
    printf 'Caddy: %s\n' "$("$CADDY_BIN" version 2>/dev/null || printf unknown)"
    printf 'Forwardproxy module: %s\n' \
      "$(caddy_has_forwardproxy "$CADDY_BIN" && printf yes || printf no)"
  fi
  printf 'TCP/443 listener: %s\n' "$( [[ -n "$(socket_lines tcp 443 || true)" ]] && printf yes || printf no )"
  printf 'UDP/443 listener: %s\n' "$( [[ -n "$(socket_lines udp 443 || true)" ]] && printf yes || printf no )"
  if verify_manifest_drift >/dev/null 2>&1; then
    printf 'Config drift: no\n'
  else
    printf 'Config drift: YES\n'
  fi
}

diagnose_installation() {
  show_installation_status
  if service_is_active; then
    wait_for_tls_and_decoy
    verify_h2_alpn
    verify_listeners
    verify_proxy_connect_if_supported
    success 'Полная локальная диагностика пройдена.'
  else
    die 'Сервис не активен.'
  fi
}

remove_all_managed_ufw_rules() {
  ufw_is_active || return 0
  local rule
  for rule in '80/tcp' '443/tcp' '443/udp'; do
    remove_managed_ufw_rule "$rule"
  done
}

uninstall_flow() {
  load_settings
  load_users
  warn 'Будут удалены сервис, binary, Caddy config, сертификаты и сайт, управляемые только этим мастером.'
  warn "Клиентские файлы ${OUTPUT_DIR} и backup ${BACKUP_ROOT} будут сохранены."
  local phrase
  phrase=$(prompt_value 'Для подтверждения введите УДАЛИТЬ NAIVEPROXY')
  [[ "$phrase" == 'УДАЛИТЬ NAIVEPROXY' ]] || die 'Удаление отменено.'
  confirm_drift_if_needed
  begin_transaction
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  safe_remove_managed_target "$CONFIG_DIR"
  safe_remove_managed_target "$CADDY_BIN"
  safe_remove_managed_target "$SERVICE_FILE"
  safe_remove_managed_target "$WEB_ROOT"
  safe_remove_managed_target "$SELF_INSTALL_PATH"
  safe_remove_managed_target "$CADDY_DATA_DIR"
  safe_remove_managed_target "$LOG_DIR"
  remove_all_managed_ufw_rules
  systemctl daemon-reload
  commit_transaction
  success 'Управляемая установка удалена. Backup и клиентский bundle сохранены.'
}

restore_target_from_backup() {
  local backup=$1
  local label=$2
  local target=$3
  safe_remove_managed_target "$target"
  if grep -Fxq "$label" "${backup}/present.list"; then
    cp -a -- "${backup}/payload/${label}" "$target"
  fi
}

rollback_previous_operation_flow() {
  local -a backups=()
  mapfile -t backups < <(
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'transaction-*' \
      -exec test -f '{}/status' ';' -print | sort -r
  )
  (( ${#backups[@]} > 0 )) || die 'Нет завершённых backup для отката.'
  local index=0 backup
  printf '\nДоступные backup:\n' >&2
  for backup in "${backups[@]}"; do
    ((++index))
    printf '  %d) %s\n' "$index" "$(basename "$backup")" >&2
    (( index >= 10 )) && break
  done
  local selected
  selected=$(prompt_value 'Номер backup' '1')
  [[ "$selected" =~ ^[0-9]+$ ]] || die 'Некорректный номер.'
  (( 10#$selected >= 1 && 10#$selected <= index )) || die 'Некорректный номер.'
  backup=${backups[$((10#$selected - 1))]}
  confirm "Восстановить состояние до операции из $(basename "$backup")?" 'no' ||
    die 'Откат отменён.'

  begin_transaction
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  restore_target_from_backup "$backup" 'config' "$CONFIG_DIR"
  restore_target_from_backup "$backup" 'binary' "$CADDY_BIN"
  restore_target_from_backup "$backup" 'unit' "$SERVICE_FILE"
  restore_target_from_backup "$backup" 'web' "$WEB_ROOT"
  restore_target_from_backup "$backup" 'clients' "$OUTPUT_DIR"
  restore_target_from_backup "$backup" 'self' "$SELF_INSTALL_PATH"
  restore_target_from_backup "$backup" 'caddy-data' "$CADDY_DATA_DIR"
  restore_target_from_backup "$backup" 'logs' "$LOG_DIR"
  systemctl daemon-reload

  local old_active old_enabled
  old_active=$(awk -F= '$1=="service_active"{print $2}' "${backup}/service.state")
  old_enabled=$(awk -F= '$1=="service_enabled"{print $2}' "${backup}/service.state")
  if [[ "$old_enabled" == '1' && -f "$SERVICE_FILE" ]]; then
    systemctl enable "$SERVICE_NAME" >/dev/null
  else
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  if [[ "$old_active" == '1' && -f "$SERVICE_FILE" ]]; then
    systemctl start "$SERVICE_NAME"
    load_settings
    load_users
    run_local_health_checks
  fi
  if [[ -f "$SETTINGS_FILE" ]]; then
    load_settings
    apply_firewall
  else
    remove_all_managed_ufw_rules
  fi
  commit_transaction
  success 'Выбранное предыдущее состояние восстановлено.'
}

recover_incomplete_transaction() {
  [[ -f "$TRANSACTION_FILE" && ! -L "$TRANSACTION_FILE" ]] || return 0
  local python_bin backup
  python_bin=$(find_python) || die 'Для восстановления transaction нужен Python 3.'
  backup=$("$python_bin" -c '
import json,sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    print(json.load(fh)["backup"])
' "$TRANSACTION_FILE")
  [[ "$backup" == "${BACKUP_ROOT}/transaction-"* && -d "$backup" ]] ||
    die 'Найдена повреждённая незавершённая transaction.'
  warn "Найдена незавершённая операция: $(basename "$backup")."
  confirm 'Автоматически восстановить состояние из её snapshot?' 'yes' ||
    die 'Сначала завершите восстановление незавершённой transaction.'
  CURRENT_BACKUP=$backup
  SERVICE_WAS_ACTIVE=$(awk -F= '$1=="service_active"{print $2}' "${backup}/service.state")
  SERVICE_WAS_ENABLED=$(awk -F= '$1=="service_enabled"{print $2}' "${backup}/service.state")
  TRANSACTION_ARMED=1
  TRANSACTION_COMMITTED=0
  rollback_transaction
}

print_help() {
  cat <<EOF
${APP_NAME} ${APP_VERSION}

Использование:
  sudo bash naiveproxy-server-wizard.sh
  sudo naiveproxy-wizard --status
  sudo naiveproxy-wizard --diagnose
  sudo naiveproxy-wizard --apply-quick DOMAIN COUNT PREFIX --yes
  sudo naiveproxy-wizard --apply-manifest SETTINGS_JSON USERS_TSV --yes
  naiveproxy-server-wizard.sh --version

Внутренние тестовые команды:
  --internal-render-config SETTINGS_JSON USERS_TSV
  --internal-render-clients SETTINGS_JSON USERS_TSV OUTPUT_DIR
  --internal-render-site OUTPUT_DIR TITLE
  --internal-validate-settings SETTINGS_JSON USERS_TSV

Внимание: render-config выводит credentials, а render-clients/render-site записывают файлы.

Мастер поддерживает quick/guided/expert, ACME/existing TLS, H2/H3,
несколько пользователей, PAC, decoy site, ACL, destination ports,
upstream hop, lifecycle-операции, backup и автоматический rollback.
EOF
}

noninteractive_guard() {
  require_root
  assert_runtime_paths
  acquire_lock
  ensure_runtime_dir
  [[ ! -e "$TRANSACTION_FILE" && ! -L "$TRANSACTION_FILE" ]] ||
    die 'Есть незавершённая transaction; запустите мастер интерактивно для восстановления.'
}

apply_noninteractive_loaded_plan() {
  validate_settings
  validate_user_arrays || die 'Невалидный набор пользователей.'
  check_supported_platform
  install_dependencies
  run_preflight
  local candidate_binary
  if [[ -f "$MANIFEST_FILE" ]]; then
    verify_manifest_drift >/dev/null ||
      die 'Обнаружен config drift; non-interactive apply запрещён.'
    candidate_binary=$(stage_installed_binary || true)
  fi
  if [[ -z "${candidate_binary:-}" ]]; then
    prepare_candidate_binary
    candidate_binary=$PREPARED_CANDIDATE
  fi
  local -a artifacts=()
  mapfile -t artifacts < <(prepare_plan_artifacts)
  (( ${#artifacts[@]} == 3 )) || die 'Не удалось подготовить plan artifacts.'
  apply_installation "$candidate_binary" "${artifacts[0]}" "${artifacts[1]}" "${artifacts[2]}"
}

apply_quick_noninteractive() {
  [[ $# == 4 && "$4" == '--yes' ]] ||
    die 'Формат: --apply-quick DOMAIN COUNT PREFIX --yes'
  noninteractive_guard
  DOMAIN=${1,,}
  local count=$2
  local prefix=$3
  is_valid_domain "$DOMAIN" || die 'Некорректный домен.'
  is_valid_count "$count" || die 'COUNT должен быть от 1 до 500.'
  is_valid_username "$prefix" || die 'Некорректный PREFIX.'
  INSTALL_MODE='quick'
  SERVER_BUILD_MODE='source_patched'
  TLS_MODE='acme'
  ACME_EMAIL=''
  HTTP3_ENABLED='true'
  AUTO_HTTPS_REDIRECTS='true'
  DECOY_MODE='static'
  DECOY_TITLE='Web Service'
  PROBE_MODE='fallthrough'
  PAC_ENABLED='false'
  HIDE_IP='true'
  HIDE_VIA='true'
  TARGET_PORTS_MODE='web'
  TARGET_PORTS='80 443'
  ACL_MODE='hardened'
  ACL_CUSTOM=''
  UPSTREAM_URL=''
  DIAL_TIMEOUT='30s'
  MAX_IDLE_CONNS='256'
  MAX_IDLE_CONNS_PER_HOST='8'
  MANAGE_UFW='true'
  OPEN_HTTP_PORT='true'
  create_generated_users "$count" "$prefix"
  apply_noninteractive_loaded_plan
}

apply_manifest_noninteractive() {
  [[ $# == 3 && "$3" == '--yes' ]] ||
    die 'Формат: --apply-manifest SETTINGS_JSON USERS_TSV --yes'
  noninteractive_guard
  load_settings "$1"
  load_users "$2"
  apply_noninteractive_loaded_plan
}

interactive_main() {
  require_root
  require_tty
  assert_runtime_paths
  acquire_lock
  ensure_runtime_dir
  recover_incomplete_transaction
  print_banner

  if [[ -f "$SETTINGS_FILE" && -f "$USERS_FILE" ]]; then
    local action
    action=$(menu 'Действие' \
      'Перенастроить сервер' \
      'Добавить пользователей' \
      'Удалить пользователя' \
      'Сменить пароль пользователя' \
      'Пересоздать клиентские файлы' \
      'Диагностика' \
      'Обновить/rebuild Caddy' \
      'Откатить последнюю операцию' \
      'Удалить управляемую установку')
    case "$action" in
      1) run_install_flow ;;
      2) add_users_flow ;;
      3) remove_user_flow ;;
      4) rotate_user_flow ;;
      5) export_clients_flow ;;
      6) diagnose_installation ;;
      7)
        load_settings
        load_users
        SERVER_BUILD_MODE='source_patched'
        show_plan
        confirm 'Пересобрать и применить закреплённый Caddy?' 'no' || die 'Операция отменена.'
        install_dependencies
        run_preflight
        local rebuilt
        prepare_candidate_binary
        rebuilt=$PREPARED_CANDIDATE
        local -a rebuilt_artifacts=()
        mapfile -t rebuilt_artifacts < <(prepare_plan_artifacts)
        apply_installation "$rebuilt" "${rebuilt_artifacts[0]}" "${rebuilt_artifacts[1]}" "${rebuilt_artifacts[2]}"
        ;;
      8) rollback_previous_operation_flow ;;
      9) uninstall_flow ;;
    esac
  else
    run_install_flow
  fi
}

main() {
  local command=${1:-}
  case "$command" in
    --version)
      printf '%s %s\n' "$APP_NAME" "$APP_VERSION"
      ;;
    --help | -h)
      print_help
      ;;
    --internal-render-config)
      [[ $# == 3 ]] || die 'Нужны SETTINGS_JSON и USERS_TSV.'
      render_caddyfile "$2" "$3"
      ;;
    --internal-render-clients)
      [[ $# == 4 ]] || die 'Нужны SETTINGS_JSON, USERS_TSV и OUTPUT_DIR.'
      stage_client_bundle "$2" "$3" "$4"
      ;;
    --internal-render-site)
      [[ $# == 3 ]] || die 'Нужны OUTPUT_DIR и TITLE.'
      render_static_site "$2" "$3"
      ;;
    --internal-validate-settings)
      [[ $# == 3 ]] || die 'Нужны SETTINGS_JSON и USERS_TSV.'
      load_settings "$2"
      load_users "$3"
      printf '%s\n' 'OK'
      ;;
    --status)
      require_root
      assert_runtime_paths
      acquire_lock
      ensure_runtime_dir
      show_installation_status
      ;;
    --diagnose)
      require_root
      assert_runtime_paths
      acquire_lock
      ensure_runtime_dir
      diagnose_installation
      ;;
    --apply-quick)
      shift
      apply_quick_noninteractive "$@"
      ;;
    --apply-manifest)
      shift
      apply_manifest_noninteractive "$@"
      ;;
    '')
      interactive_main
      ;;
    *)
      die "Неизвестная команда: ${command}. Используйте --help."
      ;;
  esac
}

if [[ "$SOURCE_ONLY" != '1' ]]; then
  trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR
  trap 'handle_signal' INT TERM
  trap 'cleanup_all' EXIT
  main "$@"
fi
