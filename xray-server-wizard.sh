#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly APP_NAME="Xray Server Wizard"
readonly APP_VERSION="0.2.3"
readonly MIN_XRAY_VERSION="26.3.27"
readonly INSTALLER_COMMIT="e741a4f56d368afbb9e5be3361b40c4552d3710d"
readonly INSTALLER_SHA256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"
readonly INSTALLER_URL="https://raw.githubusercontent.com/XTLS/Xray-install/${INSTALLER_COMMIT}/install-release.sh"

readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_PATH="${CONFIG_DIR}/config.json"
readonly CERT_DIR="${CONFIG_DIR}/certs/xray-server-wizard"
readonly STATE_DIR="/var/lib/xray-server-wizard"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly DEFAULT_OUTPUT_DIR="/root"
readonly CERTBOT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/xray-server-wizard"
readonly NGINX_CONFIG="/etc/nginx/sites-available/xray-server-wizard"
readonly NGINX_ENABLED="/etc/nginx/sites-enabled/xray-server-wizard"
readonly NGINX_DEFAULT_ENABLED="/etc/nginx/sites-enabled/default"
readonly SITE_ROOT="/var/www/xray-server-wizard"
readonly SITE_INDEX="${SITE_ROOT}/index.html"

COLOR_ENABLED=0
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  COLOR_ENABLED=1
fi

if (( COLOR_ENABLED )); then
  readonly C_RESET=$'\033[0m'
  readonly C_BOLD=$'\033[1m'
  readonly C_BLUE=$'\033[38;5;39m'
  readonly C_GREEN=$'\033[38;5;41m'
  readonly C_YELLOW=$'\033[38;5;214m'
  readonly C_RED=$'\033[38;5;196m'
  readonly C_MUTED=$'\033[38;5;245m'
else
  readonly C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_MUTED=""
fi

MODE=""
PROTOCOL=""
TRANSPORT=""
SECURITY=""
PORT="443"
CLIENT_COUNT="1"
CLIENT_HOST=""
DOMAIN=""
SNI=""
PATH_VALUE=""
SERVICE_NAME=""
XHTTP_MODE="auto"
CERT_SOURCE=""
SOURCE_CERT_PATH=""
SOURCE_KEY_PATH=""
TLS_CERT_PATH="${CERT_DIR}/fullchain.pem"
TLS_KEY_PATH="${CERT_DIR}/privkey.pem"
REALITY_TARGET=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
SHORT_ID=""
FINGERPRINT="chrome"
NAME_PREFIX="Xray"
PUBLIC_IP=""
OUTPUT_DIR="${XRAY_WIZARD_OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
OUTPUT_FILE=""
BACKUP_PATH=""
HAD_CONFIG=0
XRAY_BACKUP_READY=0
XRAY_WAS_ACTIVE=0
SERVICE_USER="nobody"
SERVICE_GROUP="nogroup"
SITE_MODE="none"
INTERNAL_PORT=""
XRAY_LISTEN="0.0.0.0"
XRAY_INBOUND_PORT=""
XRAY_SECURITY=""
IPV6_ENABLED=0
WEB_BACKUP_DIR=""
WEB_BACKUP_READY=0
HAD_NGINX_CONFIG=0
HAD_NGINX_ENABLED=0
HAD_NGINX_DEFAULT_ENABLED=0
HAD_SITE_INDEX=0
NGINX_WAS_ACTIVE=0
ROLLBACK_ARMED=0
ROLLBACK_IN_PROGRESS=0
declare -a CREDENTIALS=()

print_header() {
  printf '\n%s%s%s %sv%s%s\n' "$C_BOLD" "$C_BLUE" "$APP_NAME" "$C_MUTED" "$APP_VERSION" "$C_RESET"
  printf '%sОднофайловая настройка Xray для Ubuntu 22.04%s\n\n' "$C_MUTED" "$C_RESET"
}

info() {
  printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
}

success() {
  printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

warn() {
  printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

die() {
  printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  local line=${1:-unknown}
  printf '%s[ERROR]%s Сбой на строке %s (код %s). Секреты не выводятся.\n' \
    "$C_RED" "$C_RESET" "$line" "$exit_code" >&2
  exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

on_exit() {
  local exit_code=$?
  trap - ERR EXIT
  if (( exit_code != 0 && ROLLBACK_ARMED && ROLLBACK_IN_PROGRESS == 0 )); then
    ROLLBACK_IN_PROGRESS=1
    warn "Операция не завершена; восстанавливаю предыдущие конфиги Xray и Nginx."
    rollback_environment || true
  fi
  exit "$exit_code"
}

trap 'on_exit' EXIT

usage() {
  cat <<EOF
${APP_NAME} v${APP_VERSION}

Использование:
  sudo bash xray-server-wizard.sh
  bash xray-server-wizard.sh --help
  bash xray-server-wizard.sh --version

Интерактивные режимы:
  1. Автоматический — профиль, REALITY/TLS, количество пользователей и домен для TLS.
  2. Экспертный — ручной выбор protocol/transport/security и их параметров.

Поддерживаются:
  - VLESS и Trojan: TCP/RAW, XHTTP, gRPC, WebSocket;
  - TLS для всех перечисленных транспортов;
  - REALITY для TCP/RAW, XHTTP и gRPC;
  - нативный Hysteria2 в Xray-core 26.3.27+.

Для TLS мастер сам ставит Nginx, получает/подключает сертификат, создаёт HTTPS-заглушку
и оставляет постоянный ACME webroot для автоматического продления Certbot.

Скрипт заменяет управляемый config.json только после подтверждения, делает backup,
проверяет Xray через xray run -test, Nginx через nginx -t и откатывается при ошибке сервиса.
EOF
}

prompt() {
  local label=$1
  local default_value=${2:-}
  local answer=""
  if [[ -n "$default_value" ]]; then
    printf '%s%s%s [%s]: ' "$C_BOLD" "$label" "$C_RESET" "$default_value" >&2
  else
    printf '%s%s%s: ' "$C_BOLD" "$label" "$C_RESET" >&2
  fi
  IFS= read -r answer </dev/tty || die "Ввод прерван."
  printf '%s' "${answer:-$default_value}"
}

menu() {
  local title=$1
  shift
  local -a options=("$@")
  local answer=""
  local i
  printf '\n%s%s%s\n' "$C_BOLD" "$title" "$C_RESET" >&2
  for (( i=0; i<${#options[@]}; i++ )); do
    printf '  %s%2d)%s %s\n' "$C_BLUE" "$((i + 1))" "$C_RESET" "${options[$i]}" >&2
  done
  while true; do
    printf 'Выбор [1-%d]: ' "${#options[@]}" >&2
    IFS= read -r answer </dev/tty || die "Ввод прерван."
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( 10#$answer >= 1 && 10#$answer <= ${#options[@]} )); then
      printf '%s' "$((10#$answer))"
      return 0
    fi
    warn "Введите номер от 1 до ${#options[@]}."
  done
}

confirm() {
  local label=$1
  local default=${2:-n}
  local suffix="[y/N]"
  local answer=""
  [[ "$default" == "y" ]] && suffix="[Y/n]"
  printf '%s %s: ' "$label" "$suffix" >&2
  IFS= read -r answer </dev/tty || die "Ввод прерван."
  answer=${answer:-$default}
  [[ "$answer" =~ ^[YyДд]$ ]]
}

require_root() {
  (( EUID == 0 )) || die "Запустите скрипт от root: sudo bash $0"
}

check_os() {
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release. Требуется Ubuntu 22.04."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]] || \
    die "Поддерживается только Ubuntu 22.04; обнаружено ${PRETTY_NAME:-неизвестно}."
  [[ "$(uname -s)" == "Linux" ]] || die "Требуется Linux."
  command -v systemctl >/dev/null 2>&1 || die "Не найден systemd/systemctl."
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_valid_count() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 500 ))
}

is_valid_domain() {
  local value=${1,,}
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

is_valid_host() {
  local value=$1
  [[ -n "$value" && "$value" != *"://"* && "$value" != */* && "$value" != *" "* ]] || return 1
  is_valid_domain "$value" || \
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
    [[ "$value" =~ ^[0-9A-Fa-f:]+$ ]]
}

is_valid_path() {
  local value=$1
  local path_pattern="^/[A-Za-z0-9._~%/-]+$"
  [[ "$value" == /* && ${#value} -le 200 && "$value" =~ $path_pattern ]]
}

is_valid_service_name() {
  local value=$1
  [[ -n "$value" && ${#value} -le 128 && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}

is_valid_reality_target() {
  local value=$1
  [[ "$value" =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):[0-9]{1,5}$ ]] || return 1
  is_valid_port "${value##*:}"
}

random_hex() {
  local bytes=${1:-8}
  openssl rand -hex "$bytes"
}

detect_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
    [[ -n "$ip" ]] || ip=$(curl -4fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)
  fi
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./ && $1 !~ /^127\./ {print; exit}')
  fi
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s' "$ip"
}

reality_target_host() {
  local target=$1
  local host=${target%:*}
  host=${host#[}
  host=${host%]}
  printf '%s' "$host"
}

resolve_host_addresses() {
  local host=$1
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" == *:* ]]; then
    printf '%s\n' "$host"
    return 0
  fi
  {
    if command -v dig >/dev/null 2>&1; then
      dig +short A "$host" 2>/dev/null || true
      dig +short AAAA "$host" 2>/dev/null || true
    elif command -v getent >/dev/null 2>&1; then
      getent ahosts "$host" 2>/dev/null | awk '{print $1}' || true
    fi
  } | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ || /^[0-9A-Fa-f:]+$/' | sort -u
}

collect_self_addresses() {
  local detected=""
  detected=${PUBLIC_IP:-$(detect_public_ip || true)}
  {
    printf '127.0.0.1\n::1\n'
    [[ -n "$detected" ]] && printf '%s\n' "$detected"
    hostname -I 2>/dev/null | tr ' ' '\n' || true
    if command -v ip >/dev/null 2>&1; then
      ip -o addr show 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' || true
    fi
  } | awk 'NF' | sort -u
}

ip_sets_overlap() {
  local target_addresses=$1
  local self_addresses=$2
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$target_addresses" "$self_addresses" <<'PY'
import ipaddress
import sys

def parsed(value):
    result = set()
    for item in value.split():
        try:
            result.add(ipaddress.ip_address(item))
        except ValueError:
            pass
    return result

raise SystemExit(0 if parsed(sys.argv[1]) & parsed(sys.argv[2]) else 1)
PY
    return
  fi

  local target self
  for target in $target_addresses; do
    for self in $self_addresses; do
      [[ "$target" == "$self" ]] && return 0
    done
  done
  return 1
}

reality_target_points_to_self() {
  local target=${1:-$REALITY_TARGET}
  local target_port=${target##*:}
  (( 10#$target_port == 10#$PORT )) || return 1

  local host
  host=$(reality_target_host "$target")
  local -a target_addresses=()
  local -a self_addresses=()
  mapfile -t target_addresses < <(resolve_host_addresses "$host")
  (( ${#target_addresses[@]} > 0 )) || return 1
  mapfile -t self_addresses < <(collect_self_addresses)
  (( ${#self_addresses[@]} > 0 )) || return 1

  ip_sets_overlap "${target_addresses[*]}" "${self_addresses[*]}"
}

validate_reality_target_safety() {
  local host
  host=$(reality_target_host "$REALITY_TARGET")
  local -a target_addresses=()
  mapfile -t target_addresses < <(resolve_host_addresses "$host")
  (( ${#target_addresses[@]} > 0 )) || \
    die "REALITY target ${REALITY_TARGET} не резолвится в IP-адрес с этого VPS."
  if reality_target_points_to_self "$REALITY_TARGET"; then
    die "REALITY target ${REALITY_TARGET} указывает на этот же VPS и тот же порт ${PORT}. Это создаёт цикл Xray → собственный listener. Выберите внешний HTTPS target или отдельный локальный TLS-сервис на другом порту."
  fi
}

apt_with_lock_retry() {
  local attempt status=0
  local max_attempts=120
  local output
  output=$(mktemp)
  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    if apt-get "$@" >"$output" 2>&1; then
      rm -f -- "$output"
      return 0
    else
      status=$?
    fi
    if grep -Eqi 'Could not get lock|Unable to acquire the dpkg frontend lock|is another process using it' "$output"; then
      if (( attempt == 1 || attempt % 6 == 0 )); then
        info "APT занят системным обновлением; жду освобождения блокировки (${attempt}/${max_attempts})..."
      fi
      sleep 5
      continue
    fi
    cat "$output" >&2
    rm -f -- "$output"
    return "$status"
  done
  cat "$output" >&2
  rm -f -- "$output"
  die "APT не освободил блокировку за 10 минут. Повторите запуск после завершения unattended-upgrades."
}

install_dependencies() {
  info "Устанавливаю минимальные системные зависимости..."
  export DEBIAN_FRONTEND=noninteractive
  apt_with_lock_retry update -qq
  apt_with_lock_retry install -y -qq ca-certificates curl openssl python3 certbot dnsutils iproute2
  success "Зависимости готовы."
}

version_ge() {
  local current=$1
  local required=$2
  [[ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n1)" == "$required" ]]
}

current_xray_version() {
  "$XRAY_BIN" version 2>/dev/null | awk 'NR==1 {print $2}'
}

official_service_ready() {
  local unit=""
  unit=$(systemctl cat xray.service 2>/dev/null || true)
  grep -Fq "$XRAY_BIN" <<<"$unit" && grep -Fq "$CONFIG_PATH" <<<"$unit"
}

install_xray() {
  local current=""
  if [[ -x "$XRAY_BIN" ]]; then
    current=$(current_xray_version || true)
  fi
  if [[ -n "$current" ]] && version_ge "$current" "$MIN_XRAY_VERSION" && official_service_ready; then
    success "Xray $current уже установлен."
    return 0
  fi

  info "Устанавливаю официальный Xray-core (требуется >= ${MIN_XRAY_VERSION})..."
  local installer
  installer=$(mktemp)
  curl -fL --retry 3 --connect-timeout 15 "$INSTALLER_URL" -o "$installer"
  printf '%s  %s\n' "$INSTALLER_SHA256" "$installer" | sha256sum -c - >/dev/null || \
    die "Контрольная сумма официального installer не совпала."
  local installer_exit=0
  if bash "$installer" install --without-geodata; then
    installer_exit=0
  else
    installer_exit=$?
  fi
  rm -f -- "$installer"
  current=$(current_xray_version || true)
  if [[ -z "$current" ]] || ! version_ge "$current" "$MIN_XRAY_VERSION"; then
    die "Xray installer завершился с кодом ${installer_exit}; установлена версия ${current:-unknown}, требуется ${MIN_XRAY_VERSION}+."
  fi
  official_service_ready || die "xray.service не использует ожидаемые пути ${XRAY_BIN} и ${CONFIG_PATH}."
  if (( installer_exit != 0 )); then
    warn "Официальный installer не смог запустить Xray с начальным пустым конфигом (код ${installer_exit}); мастер продолжит и установит проверенный конфиг."
    systemctl stop xray.service >/dev/null 2>&1 || true
    systemctl reset-failed xray.service >/dev/null 2>&1 || true
  fi
  success "Установлен Xray $current."
}

resolve_service_identity() {
  local detected_user=""
  detected_user=$(systemctl show xray.service -p User --value 2>/dev/null || true)
  [[ -n "$detected_user" ]] && SERVICE_USER=$detected_user
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    SERVICE_GROUP=$(id -gn "$SERVICE_USER")
  else
    SERVICE_USER="root"
    SERVICE_GROUP="root"
  fi
}

choose_internal_port() {
  local attempt candidate
  for (( attempt=1; attempt<=100; attempt++ )); do
    candidate=$((10000 + 10#$(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000))
    (( candidate != PORT && candidate != 80 )) || continue
    if ! ss -H -ltn "sport = :${candidate}" 2>/dev/null | grep -q .; then
      INTERNAL_PORT=$candidate
      return 0
    fi
  done
  die "Не удалось найти свободный внутренний TCP-порт для связки Xray и Nginx."
}

configure_runtime_topology() {
  SITE_MODE="none"
  XRAY_LISTEN="0.0.0.0"
  XRAY_INBOUND_PORT="$PORT"
  XRAY_SECURITY="$SECURITY"
  INTERNAL_PORT=""

  [[ "$SECURITY" == "tls" ]] || return 0
  (( PORT != 80 )) || die "Порт 80 зарезервирован для HTTP-01 и перенаправления сайта. Для TLS выберите 443 или другой порт."
  choose_internal_port
  case "$TRANSPORT" in
    tcp)
      SITE_MODE="fallback"
      ;;
    xhttp|grpc|ws)
      SITE_MODE="reverse-proxy"
      XRAY_LISTEN="127.0.0.1"
      XRAY_INBOUND_PORT="$INTERNAL_PORT"
      XRAY_SECURITY="none"
      ;;
    hysteria2)
      SITE_MODE="parallel"
      ;;
    *)
      die "Для TLS-транспорта ${TRANSPORT} не определена схема сайта-заглушки."
      ;;
  esac
}

collect_client_count() {
  local value=""
  while true; do
    value=$(prompt "Сколько UUID/пользователей создать" "1")
    if is_valid_count "$value"; then
      CLIENT_COUNT=$((10#$value))
      return 0
    fi
    warn "Допустимо целое число от 1 до 500."
  done
}

collect_port() {
  local value=""
  while true; do
    value=$(prompt "Порт сервера" "443")
    if is_valid_port "$value"; then
      PORT=$((10#$value))
      return 0
    fi
    warn "Порт должен быть от 1 до 65535."
  done
}

collect_domain() {
  local value=""
  while true; do
    value=$(prompt "Домен с готовой A/AAAA-записью")
    value=${value,,}
    if is_valid_domain "$value"; then
      DOMAIN=$value
      CLIENT_HOST=$value
      SNI=$value
      return 0
    fi
    warn "Введите домен без https:// и пути, например vpn.example.com."
  done
}

collect_client_host() {
  local default_value=${1:-}
  local value=""
  while true; do
    value=$(prompt "Адрес сервера в клиентской ссылке" "$default_value")
    if is_valid_host "$value"; then
      CLIENT_HOST=$value
      return 0
    fi
    warn "Введите IP или домен без схемы и пути."
  done
}

collect_transport_details() {
  local expert=${1:-0}
  local token
  token=$(random_hex 5)
  case "$TRANSPORT" in
    xhttp)
      PATH_VALUE="/assets/${token}"
      XHTTP_MODE="auto"
      if (( expert )); then
        while true; do
          PATH_VALUE=$(prompt "XHTTP path" "$PATH_VALUE")
          is_valid_path "$PATH_VALUE" && break
          warn "Path должен начинаться с /, не быть корнем / и содержать только безопасные URL-символы."
        done
        case "$(menu "XHTTP mode" "auto (сервер принимает все режимы)" "packet-up" "stream-up" "stream-one")" in
          1) XHTTP_MODE="auto" ;;
          2) XHTTP_MODE="packet-up" ;;
          3) XHTTP_MODE="stream-up" ;;
          4) XHTTP_MODE="stream-one" ;;
        esac
      fi
      ;;
    ws)
      PATH_VALUE="/ws/${token}"
      if (( expert )); then
        while true; do
          PATH_VALUE=$(prompt "WebSocket path" "$PATH_VALUE")
          is_valid_path "$PATH_VALUE" && break
          warn "Path должен начинаться с /, не быть корнем / и содержать только безопасные URL-символы."
        done
      fi
      ;;
    grpc)
      SERVICE_NAME="grpc${token}"
      if (( expert )); then
        while true; do
          SERVICE_NAME=$(prompt "gRPC serviceName" "$SERVICE_NAME")
          is_valid_service_name "$SERVICE_NAME" && break
          warn "serviceName: 1–128 символов A-Z, a-z, 0-9, ., _, / или -."
        done
      fi
      ;;
  esac
}

collect_auto_profile() {
  MODE="auto"
  local choice
  choice=$(menu "Автоматический режим: сначала выберите протокол и транспорт" \
    "VLESS + TCP/RAW (НЕ рекомендуется для обычного TLS: легче блокировать)" \
    "VLESS + XHTTP" \
    "VLESS + gRPC" \
    "VLESS + WebSocket" \
    "Trojan + TCP/RAW (НЕ рекомендуется для обычного TLS: легче блокировать)" \
    "Trojan + XHTTP" \
    "Trojan + gRPC" \
    "Trojan + WebSocket" \
    "Hysteria2 (UDP)")
  case "$choice" in
    1) PROTOCOL="vless"; TRANSPORT="tcp" ;;
    2) PROTOCOL="vless"; TRANSPORT="xhttp" ;;
    3) PROTOCOL="vless"; TRANSPORT="grpc" ;;
    4) PROTOCOL="vless"; TRANSPORT="ws" ;;
    5) PROTOCOL="trojan"; TRANSPORT="tcp" ;;
    6) PROTOCOL="trojan"; TRANSPORT="xhttp" ;;
    7) PROTOCOL="trojan"; TRANSPORT="grpc" ;;
    8) PROTOCOL="trojan"; TRANSPORT="ws" ;;
    9) PROTOCOL="hysteria2"; TRANSPORT="hysteria2" ;;
  esac

  if [[ "$PROTOCOL" == "hysteria2" ]]; then
    SECURITY="tls"
    info "Hysteria2 использует TLS; REALITY с UDP/QUIC несовместим."
  elif [[ "$TRANSPORT" == "ws" ]]; then
    SECURITY="tls"
    info "WebSocket поддерживается с TLS; REALITY с WebSocket несовместим."
  else
    case "$(menu "Теперь выберите защиту транспорта" "REALITY" "TLS")" in
      1) SECURITY="reality" ;;
      2) SECURITY="tls" ;;
    esac
  fi

  PORT="443"
  collect_client_count
  if [[ "$SECURITY" == "tls" ]]; then
    CERT_SOURCE="acme"
    collect_domain
  else
    PUBLIC_IP=$(detect_public_ip || true)
    [[ -n "$PUBLIC_IP" ]] || die "Не удалось определить публичный IPv4. Используйте экспертный режим."
    CLIENT_HOST=$PUBLIC_IP
    REALITY_TARGET="auto"
  fi
  collect_transport_details 0
  NAME_PREFIX="${PROTOCOL^^}-${TRANSPORT^^}"
  if [[ "$PROTOCOL" == "hysteria2" ]]; then
    NAME_PREFIX="HYSTERIA2"
  fi
  return 0
}

collect_expert_profile() {
  MODE="expert"
  case "$(menu "Экспертный режим: протокол" "VLESS" "Trojan" "Hysteria2")" in
    1) PROTOCOL="vless" ;;
    2) PROTOCOL="trojan" ;;
    3) PROTOCOL="hysteria2" ;;
  esac

  if [[ "$PROTOCOL" == "hysteria2" ]]; then
    TRANSPORT="hysteria2"
    SECURITY="tls"
  else
    case "$(menu "Транспорт" "TCP/RAW (НЕ рекомендуется для обычного TLS: легче блокировать)" "XHTTP" "gRPC" "WebSocket")" in
      1) TRANSPORT="tcp" ;;
      2) TRANSPORT="xhttp" ;;
      3) TRANSPORT="grpc" ;;
      4) TRANSPORT="ws" ;;
    esac
    if [[ "$TRANSPORT" == "ws" ]]; then
      SECURITY="tls"
      info "WebSocket поддерживается с TLS; REALITY с WebSocket несовместим."
    else
      case "$(menu "Защита транспорта" "REALITY" "TLS")" in
        1) SECURITY="reality" ;;
        2) SECURITY="tls" ;;
      esac
    fi
  fi

  collect_port
  collect_client_count
  collect_transport_details 1

  if [[ "$SECURITY" == "tls" ]]; then
    case "$(menu "TLS-сертификат" "Получить Let's Encrypt автоматически" "Использовать существующие cert/key")" in
      1)
        CERT_SOURCE="acme"
        collect_domain
        ;;
      2)
        CERT_SOURCE="existing"
        while true; do
          SOURCE_CERT_PATH=$(prompt "Путь к fullchain/certificate PEM")
          [[ -f "$SOURCE_CERT_PATH" ]] && break
          warn "Файл сертификата не найден."
        done
        while true; do
          SOURCE_KEY_PATH=$(prompt "Путь к private key PEM")
          [[ -f "$SOURCE_KEY_PATH" ]] && break
          warn "Файл ключа не найден."
        done
        PUBLIC_IP=$(detect_public_ip || true)
        collect_client_host "$PUBLIC_IP"
        while true; do
          SNI=$(prompt "TLS SNI" "$CLIENT_HOST")
          is_valid_host "$SNI" && break
          warn "SNI должен быть доменом без схемы и пути."
        done
        ;;
    esac
  else
    PUBLIC_IP=$(detect_public_ip || true)
    collect_client_host "$PUBLIC_IP"
    local suggested_target="www.amazon.com:443"
    while true; do
      REALITY_TARGET=$(prompt "REALITY target (host:port)" "$suggested_target")
      if ! is_valid_reality_target "$REALITY_TARGET"; then
        warn "Формат: example.com:443."
        continue
      fi
      if reality_target_points_to_self "$REALITY_TARGET"; then
        warn "Этот REALITY target указывает на данный VPS и тот же порт ${PORT}; возникнет бесконечный цикл. Укажите внешний HTTPS-сайт."
        continue
      fi
      break
    done
    while true; do
      SNI=$(prompt "REALITY serverName/SNI" "${REALITY_TARGET%:*}")
      is_valid_host "$SNI" && break
      warn "SNI должен быть доменом без схемы и пути."
    done
  fi

  NAME_PREFIX=$(prompt "Префикс названий ссылок" "${PROTOCOL^^}-${TRANSPORT^^}")
  [[ -n "$NAME_PREFIX" ]] || NAME_PREFIX="Xray"
}

show_plan() {
  local transport_label=$TRANSPORT
  [[ "$TRANSPORT" == "tcp" ]] && transport_label="TCP/RAW"
  printf '\n%sПлан настройки%s\n' "$C_BOLD" "$C_RESET"
  printf '  Режим:          %s\n' "$MODE"
  printf '  Протокол:       %s\n' "$PROTOCOL"
  printf '  Транспорт:      %s\n' "$transport_label"
  printf '  Защита:         %s\n' "$SECURITY"
  printf '  Адрес:          %s:%s\n' "$CLIENT_HOST" "$PORT"
  printf '  Пользователей:  %s\n' "$CLIENT_COUNT"
  [[ -n "$PATH_VALUE" ]] && printf '  Path:            %s\n' "$PATH_VALUE"
  [[ -n "$SERVICE_NAME" ]] && printf '  serviceName:     %s\n' "$SERVICE_NAME"
  [[ "$TRANSPORT" == "xhttp" ]] && printf '  XHTTP mode:      %s\n' "$XHTTP_MODE"
  if [[ "$SECURITY" == "tls" ]]; then
    printf '  TLS:             %s\n' "$CERT_SOURCE"
    [[ -n "$DOMAIN" ]] && printf '  Домен:           %s\n' "$DOMAIN"
    printf '  HTTPS-заглушка:  Nginx, автоматически\n'
  else
    printf '  REALITY target:  %s\n' "$REALITY_TARGET"
    [[ -n "$SNI" ]] && printf '  SNI:             %s\n' "$SNI"
  fi
  if [[ -f "$CONFIG_PATH" ]]; then
    warn "Существующий ${CONFIG_PATH} будет заменён после создания backup."
  fi
  printf '\n'
}

validate_dns_for_acme() {
  local -a records=()
  mapfile -t records < <(dig +short A "$DOMAIN" | awk '/^[0-9]+\./')
  (( ${#records[@]} > 0 )) || die "У домена ${DOMAIN} нет A-записи."
  PUBLIC_IP=${PUBLIC_IP:-$(detect_public_ip || true)}
  [[ -n "$PUBLIC_IP" ]] || die "Не удалось определить публичный IPv4 для проверки DNS."
  local found=0
  local record
  for record in "${records[@]}"; do
    [[ "$record" == "$PUBLIC_IP" ]] && found=1
  done
  (( found )) || die "A-запись ${DOMAIN} не указывает на публичный IPv4 ${PUBLIC_IP}."

  local -a aaaa_records=()
  mapfile -t aaaa_records < <(dig +short AAAA "$DOMAIN" | awk '/:/')
  if (( ${#aaaa_records[@]} > 0 )); then
    local public_v6=""
    public_v6=$(curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)
    [[ -n "$public_v6" ]] || die "Есть AAAA-запись ${aaaa_records[0]}, но сервер не имеет рабочего публичного IPv6. Удалите AAAA или настройте IPv6."
    python3 - "$public_v6" "${aaaa_records[@]}" <<'PY' || die "Ни одна AAAA-запись домена не совпадает с публичным IPv6 сервера."
import ipaddress
import sys
public = ipaddress.ip_address(sys.argv[1])
records = (ipaddress.ip_address(value) for value in sys.argv[2:])
raise SystemExit(0 if public in records else 1)
PY
    IPV6_ENABLED=1
    if [[ "$SITE_MODE" == "fallback" || "$SITE_MODE" == "parallel" ]]; then
      [[ -r /proc/sys/net/ipv6/bindv6only && "$(</proc/sys/net/ipv6/bindv6only)" == "0" ]] || \
        die "Для одновременного IPv4/IPv6 Xray требуется net.ipv6.bindv6only=0. Исправьте sysctl или удалите AAAA-запись."
      XRAY_LISTEN="::"
    fi
  fi
  success "DNS домена указывает на этот сервер."
}

port_in_use() {
  local protocol=$1
  local port=${2:-$PORT}
  if [[ "$protocol" == "udp" ]]; then
    ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
  else
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
  fi
}

check_one_target_port() {
  local socket_protocol=$1
  local allowed_pattern=$2
  if port_in_use "$socket_protocol" "$PORT"; then
    local owners=""
    owners=$(ss -H -lnup "sport = :${PORT}" 2>/dev/null || true)
    [[ "$socket_protocol" == "tcp" ]] && owners=$(ss -H -lntp "sport = :${PORT}" 2>/dev/null || true)
    if grep -Eqi "$allowed_pattern" <<<"$owners"; then
      warn "Порт ${PORT}/${socket_protocol} занят управляемым сервисом; мастер безопасно переключит схему."
    else
      die "Порт ${PORT}/${socket_protocol} уже занят другим процессом: ${owners:-неизвестно}."
    fi
  fi
}

check_target_port() {
  if [[ "$PROTOCOL" == "hysteria2" ]]; then
    check_one_target_port "udp" "xray"
    [[ "$SECURITY" == "tls" ]] && check_one_target_port "tcp" "nginx"
  else
    if [[ "$SECURITY" == "tls" ]]; then
      check_one_target_port "tcp" "xray|nginx"
    else
      check_one_target_port "tcp" "xray"
    fi
  fi
}

check_extra_xray_configs() {
  [[ -d "$CONFIG_DIR" ]] || return 0
  local -a extra_configs=()
  mapfile -t extra_configs < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.json' ! -name 'config.json' -print)
  if (( ${#extra_configs[@]} > 0 )); then
    printf '%s\n' "${extra_configs[@]}" >&2
    die "Найдены дополнительные Xray JSON-файлы. Мастер v${APP_VERSION} не объединяет произвольные confdir-конфиги; используйте чистый VPS или уберите их вручную."
  fi
}

select_auto_reality_target() {
  # Amazon is first because its TLS 1.3 endpoint is compatible with the
  # REALITY handshake used by the minimum supported Xray release. A plain
  # `xray tls ping` is necessary but not sufficient for every public site.
  local -a candidates=("www.amazon.com:443" "www.samsung.com:443" "www.microsoft.com:443")
  local candidate
  for candidate in "${candidates[@]}"; do
    if timeout 15 "$XRAY_BIN" tls ping "$candidate" >/dev/null 2>&1; then
      REALITY_TARGET=$candidate
      SNI=${candidate%:*}
      success "Автоматически выбран доступный REALITY target: $REALITY_TARGET"
      warn "Автовыбор REALITY target эвристический. Для осознанного выбора target в том же ASN используйте экспертный режим."
      return 0
    fi
  done
  die "Не удалось автоматически подобрать REALITY target. Используйте экспертный режим."
}

verify_reality_target() {
  timeout 15 "$XRAY_BIN" tls ping "$REALITY_TARGET" >/dev/null 2>&1 || \
    die "REALITY target ${REALITY_TARGET} не проходит TLS-проверку с этого VPS."
}

generate_reality_material() {
  local output=""
  output=$("$XRAY_BIN" x25519)
  REALITY_PRIVATE_KEY=$(awk -F': ' '/^PrivateKey:/ {print $2; exit}' <<<"$output")
  REALITY_PUBLIC_KEY=$(awk -F': ' '/^Password( \(PublicKey\))?:/ {print $2; exit}' <<<"$output")
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || \
    die "Не удалось разобрать ключевую пару REALITY из xray x25519."
  SHORT_ID=$(random_hex 8)
}

generate_credentials() {
  CREDENTIALS=()
  local i credential
  for (( i=1; i<=CLIENT_COUNT; i++ )); do
    credential=$("$XRAY_BIN" uuid)
    [[ "$credential" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Xray вернул невалидный UUID."
    CREDENTIALS+=("$credential")
  done
}

install_nginx() {
  info "Устанавливаю Nginx для HTTPS-сайта-заглушки..."
  export DEBIAN_FRONTEND=noninteractive
  apt_with_lock_retry install -y -qq nginx
  command -v nginx >/dev/null 2>&1 || die "Nginx не установился."
  success "Nginx установлен."
}

check_http_port_for_web() {
  if port_in_use "tcp" "80"; then
    local owners=""
    owners=$(ss -H -lntp 'sport = :80' 2>/dev/null || true)
    grep -qi 'nginx' <<<"$owners" || \
      die "Порт 80/TCP занят не Nginx: ${owners:-неизвестно}. Он нужен для HTTP-01 и перенаправления на HTTPS."
  fi
}

validate_nginx_environment() {
  [[ -d /etc/nginx/sites-enabled ]] || return 0
  local -a foreign_sites=()
  mapfile -t foreign_sites < <(find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 \
    ! -name 'default' ! -name 'xray-server-wizard' -print 2>/dev/null)
  if (( ${#foreign_sites[@]} > 0 )); then
    printf '%s\n' "${foreign_sites[@]}" >&2
    die "Найдены сторонние активные сайты Nginx. Мастер не будет изменять их автоматически; используйте чистый VPS или существующий сертификат и настройте интеграцию вручную."
  fi
  local -a foreign_conf=()
  mapfile -t foreign_conf < <(find /etc/nginx/conf.d -mindepth 1 -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null)
  if (( ${#foreign_conf[@]} > 0 )); then
    printf '%s\n' "${foreign_conf[@]}" >&2
    die "Найдены сторонние конфиги /etc/nginx/conf.d. Мастер не изменяет существующую web-инфраструктуру автоматически."
  fi
}

backup_existing_web_state() {
  (( WEB_BACKUP_READY == 0 )) || return 0
  install -d -m 0700 "$BACKUP_DIR"
  WEB_BACKUP_DIR="${BACKUP_DIR}/web-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -m 0700 "$WEB_BACKUP_DIR"
  systemctl is-active --quiet nginx.service && NGINX_WAS_ACTIVE=1
  if [[ -f "$NGINX_CONFIG" ]]; then
    HAD_NGINX_CONFIG=1
    cp -a -- "$NGINX_CONFIG" "${WEB_BACKUP_DIR}/nginx-site.conf"
  fi
  [[ -e "$NGINX_ENABLED" || -L "$NGINX_ENABLED" ]] && HAD_NGINX_ENABLED=1
  [[ -e "$NGINX_DEFAULT_ENABLED" || -L "$NGINX_DEFAULT_ENABLED" ]] && HAD_NGINX_DEFAULT_ENABLED=1
  if [[ -f "$SITE_INDEX" ]]; then
    HAD_SITE_INDEX=1
    cp -a -- "$SITE_INDEX" "${WEB_BACKUP_DIR}/index.html"
  fi
  WEB_BACKUP_READY=1
  ROLLBACK_ARMED=1
}

install_placeholder_page() {
  install -d -m 0755 -o root -g root "$SITE_ROOT"
  local candidate
  candidate=$(mktemp)
  cat >"$candidate" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <title>Service online</title>
  <style>
    :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    * { box-sizing: border-box; }
    body { min-height: 100vh; margin: 0; display: grid; place-items: center; padding: 24px; color: #f8fafc; background: #0f172a; }
    main { width: min(100%, 680px); padding: clamp(28px, 6vw, 56px); border: 1px solid #475569; border-radius: 24px; background: #172033; box-shadow: 0 24px 70px rgb(0 0 0 / 24%); }
    .status { display: inline-flex; align-items: center; gap: 10px; margin: 0 0 28px; color: #bbf7d0; font-size: 0.875rem; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; }
    .status::before { width: 10px; height: 10px; border-radius: 50%; background: #22c55e; box-shadow: 0 0 0 5px rgb(34 197 94 / 14%); content: ""; }
    h1 { margin: 0; font-size: clamp(2rem, 8vw, 4rem); line-height: 1.02; letter-spacing: -0.045em; }
    p { max-width: 52ch; margin: 24px 0 0; color: #cbd5e1; font-size: clamp(1rem, 2.5vw, 1.125rem); line-height: 1.7; }
    footer { margin-top: 44px; padding-top: 20px; border-top: 1px solid #334155; color: #94a3b8; font-size: 0.875rem; }
    @media (max-width: 420px) { main { border-radius: 18px; } }
    @media (prefers-reduced-motion: reduce) { *, *::before, *::after { scroll-behavior: auto !important; } }
  </style>
</head>
<body>
  <main>
    <div class="status">Operational</div>
    <h1>Service is online.</h1>
    <p>The requested host is available and the secure connection is working. If you expected different content, please verify the address.</p>
    <footer>HTTP status 200 · Secure endpoint</footer>
  </main>
</body>
</html>
HTML
  install -m 0644 -o root -g root "$candidate" "$SITE_INDEX"
  rm -f -- "$candidate"
}

render_nginx_config_stdout() {
  python3 <<'PY'
import os

mode = os.environ["WZ_SITE_MODE"]
port = int(os.environ["WZ_PORT"])
internal_port = int(os.environ["WZ_INTERNAL_PORT"])
transport = os.environ["WZ_TRANSPORT"]
path = os.environ.get("WZ_PATH", "")
service = os.environ.get("WZ_SERVICE_NAME", "").lstrip("/")
cert = os.environ["WZ_TLS_CERT"]
key = os.environ["WZ_TLS_KEY"]
site_root = os.environ["WZ_SITE_ROOT"]
ipv6 = os.environ.get("WZ_ENABLE_IPV6", "0") == "1"

redirect_authority = "$host" if port == 443 else f"$host:{port}"
http_ipv6 = "    listen [::]:80;\n" if ipv6 else ""
blocks = [f"""server {{
    listen 80;
{http_ipv6}    server_name _;

    location ^~ /.well-known/acme-challenge/ {{
        root {site_root};
        default_type text/plain;
        try_files $uri =404;
    }}

    location / {{
        return 301 https://{redirect_authority}$request_uri;
    }}
}}"""]

headers = """    add_header X-Content-Type-Options \"nosniff\" always;
    add_header Referrer-Policy \"no-referrer\" always;
    add_header Content-Security-Policy \"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\" always;"""
site_location = """    location / {
        try_files $uri $uri/ /index.html;
    }"""

if mode == "fallback":
    blocks.append(f"""server {{
    listen 127.0.0.1:{internal_port};
    server_name _;
    root {site_root};
    index index.html;
{headers}
{site_location}
}}""")
elif mode in ("reverse-proxy", "parallel"):
    proxy = ""
    if mode == "reverse-proxy" and transport == "ws":
        proxy = f"""
    location ^~ {path} {{
        if ($http_upgrade != \"websocket\") {{ return 404; }}
        proxy_pass http://127.0.0.1:{internal_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 5d;
    }}"""
    elif mode == "reverse-proxy" and transport in ("grpc", "xhttp"):
        route = f"/{service}" if transport == "grpc" else path
        proxy = f"""
    location ^~ {route} {{
        client_max_body_size 0;
        grpc_set_header X-Real-IP $remote_addr;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        grpc_read_timeout 5m;
        grpc_send_timeout 5m;
        grpc_pass grpc://127.0.0.1:{internal_port};
    }}"""
    tls_ipv6 = f"    listen [::]:{port} ssl http2;\n" if ipv6 else ""
    blocks.append(f"""server {{
    listen {port} ssl http2;
{tls_ipv6}    server_name _;
    root {site_root};
    index index.html;

    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:TLS:10m;
    ssl_session_timeout 1d;
{headers}
{proxy}
{site_location}
}}""")
else:
    raise SystemExit(f"unsupported site mode: {mode}")

print("\n\n".join(blocks))
PY
}

render_nginx_bootstrap_stdout() {
  local ipv6_listen=""
  (( IPV6_ENABLED )) && ipv6_listen="    listen [::]:80;"
  cat <<EOF
server {
    listen 80;
${ipv6_listen}
    server_name _;
    root ${SITE_ROOT};
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root ${SITE_ROOT};
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
}

install_nginx_candidate() {
  local source=$1
  install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  install -m 0644 -o root -g root "$source" "$NGINX_CONFIG"
  ln -sfn "$NGINX_CONFIG" "$NGINX_ENABLED"
  rm -f -- "$NGINX_DEFAULT_ENABLED"
  nginx -t >/dev/null
}

activate_nginx() {
  if systemctl is-active --quiet nginx.service; then
    systemctl reload nginx.service
  else
    systemctl start nginx.service
  fi
  systemctl enable nginx.service >/dev/null
  systemctl is-active --quiet nginx.service
}

prepare_acme_webroot() {
  if [[ -f "$NGINX_CONFIG" && -e "$NGINX_ENABLED" ]] && \
      grep -Fq '/.well-known/acme-challenge/' "$NGINX_CONFIG"; then
    nginx -t >/dev/null
    activate_nginx || die "Не удалось запустить Nginx для ACME webroot."
    return 0
  fi
  local bootstrap
  bootstrap=$(mktemp)
  render_nginx_bootstrap_stdout >"$bootstrap"
  if ! install_nginx_candidate "$bootstrap" || ! activate_nginx; then
    rm -f -- "$bootstrap"
    die "Не удалось подготовить Nginx для проверки Let's Encrypt HTTP-01."
  fi
  rm -f -- "$bootstrap"
}

prepare_reality_transition() {
  [[ -e "$NGINX_ENABLED" || -L "$NGINX_ENABLED" ]] || return 0
  validate_nginx_environment
  backup_existing_web_state
  rm -f -- "$NGINX_ENABLED"
  nginx -t >/dev/null || die "Nginx не прошёл проверку после отключения управляемого TLS-сайта."
  systemctl disable --now nginx.service >/dev/null 2>&1 || true
  info "Управляемый TLS-сайт Nginx отключён: выбран профиль REALITY."
}

copy_tls_material() {
  local cert_source=$1
  local key_source=$2
  local target_dir
  target_dir=$(dirname "$TLS_CERT_PATH")
  install -d -m 0750 -o root -g "$SERVICE_GROUP" "$target_dir"
  install -m 0644 -o root -g "$SERVICE_GROUP" "$cert_source" "$TLS_CERT_PATH"
  install -m 0640 -o root -g "$SERVICE_GROUP" "$key_source" "$TLS_KEY_PATH"
}

install_certbot_hook() {
  local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
  install -d -m 0755 "$hook_dir" || return 1
  local temp_hook
  temp_hook=$(mktemp) || return 1
  if ! cat >"$temp_hook" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "\${RENEWED_DOMAINS:-}" == *"${DOMAIN}"* ]] || exit 0
install -m 0644 -o root -g '${SERVICE_GROUP}' "\${RENEWED_LINEAGE}/fullchain.pem" '${TLS_CERT_PATH}'
install -m 0640 -o root -g '${SERVICE_GROUP}' "\${RENEWED_LINEAGE}/privkey.pem" '${TLS_KEY_PATH}'
nginx -t
systemctl reload nginx.service
systemctl try-restart xray.service
EOF
  then
    rm -f -- "$temp_hook"
    return 1
  fi
  if ! install -m 0750 -o root -g root "$temp_hook" "$CERTBOT_HOOK"; then
    rm -f -- "$temp_hook"
    return 1
  fi
  rm -f -- "$temp_hook"
}

prepare_tls_material() {
  if [[ "$CERT_SOURCE" == "existing" ]]; then
    local custom_id
    custom_id="custom-$(date -u +%Y%m%dT%H%M%SZ)"
    TLS_CERT_PATH="${CERT_DIR}/${custom_id}/fullchain.pem"
    TLS_KEY_PATH="${CERT_DIR}/${custom_id}/privkey.pem"
    copy_tls_material "$SOURCE_CERT_PATH" "$SOURCE_KEY_PATH"
    success "Существующий TLS-сертификат скопирован в защищённый каталог."
    return 0
  fi

  validate_dns_for_acme
  prepare_acme_webroot
  info "Получаю сертификат Let's Encrypt для ${DOMAIN}..."
  certbot certonly --webroot -w "$SITE_ROOT" --non-interactive --agree-tos \
    --register-unsafely-without-email --preferred-challenges http \
    --keep-until-expiring --cert-name "$DOMAIN" -d "$DOMAIN"
  local lineage="/etc/letsencrypt/live/${DOMAIN}"
  [[ -r "${lineage}/fullchain.pem" && -r "${lineage}/privkey.pem" ]] || \
    die "Certbot завершился без ожидаемых файлов сертификата."
  TLS_CERT_PATH="${CERT_DIR}/${DOMAIN}/fullchain.pem"
  TLS_KEY_PATH="${CERT_DIR}/${DOMAIN}/privkey.pem"
  copy_tls_material "${lineage}/fullchain.pem" "${lineage}/privkey.pem"
  success "TLS-сертификат установлен."
}

finalize_certificate_management() {
  if [[ "$SECURITY" == "tls" && "$CERT_SOURCE" == "acme" ]]; then
    if install_certbot_hook; then
      success "Deploy-hook обновит TLS-копию после certbot renew."
    else
      warn "Профиль работает, но deploy-hook certbot не установлен. Настройте обновление сертификата вручную."
    fi
  else
    rm -f -- "$CERTBOT_HOOK"
  fi
}

export_render_environment() {
  export WZ_PROTOCOL="$PROTOCOL"
  export WZ_TRANSPORT="$TRANSPORT"
  export WZ_SECURITY="$SECURITY"
  export WZ_PORT="$PORT"
  export WZ_SERVER_SECURITY="$XRAY_SECURITY"
  export WZ_XRAY_LISTEN="$XRAY_LISTEN"
  export WZ_XRAY_PORT="$XRAY_INBOUND_PORT"
  export WZ_SITE_MODE="$SITE_MODE"
  export WZ_INTERNAL_PORT="$INTERNAL_PORT"
  export WZ_SITE_ROOT="$SITE_ROOT"
  export WZ_ENABLE_IPV6="$IPV6_ENABLED"
  export WZ_CLIENT_HOST="$CLIENT_HOST"
  export WZ_SNI="$SNI"
  export WZ_PATH="$PATH_VALUE"
  export WZ_SERVICE_NAME="$SERVICE_NAME"
  export WZ_XHTTP_MODE="$XHTTP_MODE"
  export WZ_TLS_CERT="$TLS_CERT_PATH"
  export WZ_TLS_KEY="$TLS_KEY_PATH"
  export WZ_REALITY_TARGET="$REALITY_TARGET"
  export WZ_REALITY_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
  export WZ_REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY"
  export WZ_SHORT_ID="$SHORT_ID"
  export WZ_FINGERPRINT="$FINGERPRINT"
  export WZ_NAME_PREFIX="$NAME_PREFIX"
  export WZ_CREDENTIALS
  WZ_CREDENTIALS=$(printf '%s\n' "${CREDENTIALS[@]}")
}

render_config_stdout() {
  python3 <<'PY'
import json
import os

protocol = os.environ["WZ_PROTOCOL"]
transport = os.environ["WZ_TRANSPORT"]
security = os.environ["WZ_SECURITY"]
server_security = os.environ.get("WZ_SERVER_SECURITY", security)
site_mode = os.environ.get("WZ_SITE_MODE", "none")
credentials = [item for item in os.environ["WZ_CREDENTIALS"].splitlines() if item]

if not credentials:
    raise SystemExit("WZ_CREDENTIALS is empty")

network_by_transport = {
    "tcp": "raw",
    "xhttp": "xhttp",
    "grpc": "grpc",
    "ws": "websocket",
    "hysteria2": "hysteria",
}
network = network_by_transport[transport]

users = []
for index, credential in enumerate(credentials, start=1):
    email = f"client-{index}@xray-wizard.local"
    if protocol == "vless":
        user = {"id": credential, "level": 0, "email": email}
        if transport == "tcp":
            user["flow"] = "xtls-rprx-vision"
    elif protocol == "trojan":
        user = {"password": credential, "level": 0, "email": email}
    elif protocol == "hysteria2":
        user = {"auth": credential, "level": 0, "email": email}
    else:
        raise SystemExit(f"unsupported protocol: {protocol}")
    users.append(user)

if protocol == "vless":
    inbound_settings = {"clients": users, "decryption": "none"}
    inbound_protocol = "vless"
elif protocol == "trojan":
    inbound_settings = {"clients": users}
    inbound_protocol = "trojan"
else:
    inbound_settings = {"version": 2, "users": users}
    inbound_protocol = "hysteria"

if site_mode == "fallback":
    inbound_settings["fallbacks"] = [{
        "dest": f"127.0.0.1:{int(os.environ['WZ_INTERNAL_PORT'])}",
        "xver": 0,
    }]

stream = {"network": network, "security": server_security}
if transport == "tcp":
    stream["rawSettings"] = {}
elif transport == "xhttp":
    stream["xhttpSettings"] = {
        "path": os.environ["WZ_PATH"],
        "mode": os.environ["WZ_XHTTP_MODE"],
    }
elif transport == "grpc":
    stream["grpcSettings"] = {
        "serviceName": os.environ["WZ_SERVICE_NAME"],
    }
elif transport == "ws":
    stream["wsSettings"] = {
        "path": os.environ["WZ_PATH"],
    }
elif transport == "hysteria2":
    stream["hysteriaSettings"] = {
        "version": 2,
        "udpIdleTimeout": 60,
    }

if server_security == "reality":
    stream["realitySettings"] = {
        "show": False,
        "target": os.environ["WZ_REALITY_TARGET"],
        "xver": 0,
        "serverNames": [os.environ["WZ_SNI"]],
        "privateKey": os.environ["WZ_REALITY_PRIVATE_KEY"],
        "shortIds": [os.environ["WZ_SHORT_ID"]],
    }
elif server_security == "tls":
    alpn = {
        "tcp": ["http/1.1"] if site_mode == "fallback" else ["h2", "http/1.1"],
        "xhttp": ["h2", "http/1.1"],
        "grpc": ["h2"],
        "ws": ["http/1.1"],
        "hysteria2": ["h3"],
    }[transport]
    tls = {
        "alpn": alpn,
        "minVersion": "1.3" if transport == "hysteria2" else "1.2",
        "certificates": [{
            "certificateFile": os.environ["WZ_TLS_CERT"],
            "keyFile": os.environ["WZ_TLS_KEY"],
        }],
    }
    if transport == "hysteria2":
        tls["maxVersion"] = "1.3"
    stream["tlsSettings"] = tls
elif server_security == "none":
    pass
else:
    raise SystemExit(f"unsupported server security: {server_security}")

config = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "tag": "xray-wizard-in",
        "listen": os.environ.get("WZ_XRAY_LISTEN", "0.0.0.0"),
        "port": int(os.environ.get("WZ_XRAY_PORT", os.environ["WZ_PORT"])),
        "protocol": inbound_protocol,
        "settings": inbound_settings,
        "streamSettings": stream,
        "sniffing": {
            "enabled": True,
            "destOverride": ["http", "tls", "quic"],
            "routeOnly": False,
        },
    }],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
    ],
}

print(json.dumps(config, indent=2, ensure_ascii=False))
PY
}

render_links_stdout() {
  python3 <<'PY'
import os
from urllib.parse import quote, urlencode

protocol = os.environ["WZ_PROTOCOL"]
transport = os.environ["WZ_TRANSPORT"]
security = os.environ["WZ_SECURITY"]
host = os.environ["WZ_CLIENT_HOST"]
port = os.environ["WZ_PORT"]
sni = os.environ["WZ_SNI"]
credentials = [item for item in os.environ["WZ_CREDENTIALS"].splitlines() if item]
prefix = os.environ["WZ_NAME_PREFIX"]

if ":" in host and not host.startswith("["):
    uri_host = f"[{host}]"
else:
    uri_host = host

type_by_transport = {"tcp": "tcp", "xhttp": "xhttp", "grpc": "grpc", "ws": "ws"}

def query_for_standard():
    items = []
    if protocol == "vless":
        items.append(("encryption", "none"))
    items.extend((("security", security), ("type", type_by_transport[transport])))
    if security == "reality":
        items.extend((
            ("sni", sni),
            ("fp", os.environ["WZ_FINGERPRINT"]),
            ("pbk", os.environ["WZ_REALITY_PUBLIC_KEY"]),
            ("sid", os.environ["WZ_SHORT_ID"]),
        ))
    else:
        items.extend((("sni", sni), ("fp", os.environ["WZ_FINGERPRINT"])))
        if transport in ("xhttp", "grpc"):
            items.append(("alpn", "h2"))
        elif transport == "ws":
            items.append(("alpn", "http/1.1"))
    if transport in ("xhttp", "ws"):
        items.append(("path", os.environ["WZ_PATH"]))
    if transport == "xhttp":
        items.append(("mode", os.environ["WZ_XHTTP_MODE"]))
    elif transport == "ws":
        items.append(("host", sni))
    elif transport == "grpc":
        items.append(("serviceName", os.environ["WZ_SERVICE_NAME"]))
    if protocol == "vless" and transport == "tcp":
        items.append(("flow", "xtls-rprx-vision"))
    return urlencode(items, quote_via=quote, safe="")

for index, credential in enumerate(credentials, start=1):
    name = quote(f"{prefix}-{index:02d}", safe="")
    auth = quote(credential, safe="")
    if protocol == "hysteria2":
        query = urlencode((("sni", sni), ("alpn", "h3")), quote_via=quote, safe="")
        uri = f"hysteria2://{auth}@{uri_host}:{port}/?{query}#{name}"
    else:
        uri = f"{protocol}://{auth}@{uri_host}:{port}?{query_for_standard()}#{name}"
    print(f"{credential}\t{uri}")
PY
}

backup_existing_config() {
  (( XRAY_BACKUP_READY == 0 )) || return 0
  install -d -m 0700 "$BACKUP_DIR"
  systemctl is-active --quiet xray.service && XRAY_WAS_ACTIVE=1
  if [[ -f "$CONFIG_PATH" ]]; then
    HAD_CONFIG=1
    BACKUP_PATH="${BACKUP_DIR}/config-$(date -u +%Y%m%dT%H%M%SZ).json"
    cp -a -- "$CONFIG_PATH" "$BACKUP_PATH"
    success "Backup: $BACKUP_PATH"
  fi
  XRAY_BACKUP_READY=1
}

restore_web_state() {
  (( WEB_BACKUP_READY )) || return 0
  if (( HAD_NGINX_CONFIG )); then
    install -m 0644 -o root -g root "${WEB_BACKUP_DIR}/nginx-site.conf" "$NGINX_CONFIG"
  else
    rm -f -- "$NGINX_CONFIG"
  fi
  if (( HAD_NGINX_ENABLED )); then
    ln -sfn "$NGINX_CONFIG" "$NGINX_ENABLED"
  else
    rm -f -- "$NGINX_ENABLED"
  fi
  if (( HAD_NGINX_DEFAULT_ENABLED )); then
    ln -sfn /etc/nginx/sites-available/default "$NGINX_DEFAULT_ENABLED"
  else
    rm -f -- "$NGINX_DEFAULT_ENABLED"
  fi
  if (( HAD_SITE_INDEX )); then
    install -d -m 0755 "$SITE_ROOT"
    install -m 0644 -o root -g root "${WEB_BACKUP_DIR}/index.html" "$SITE_INDEX"
  else
    rm -f -- "$SITE_INDEX"
  fi
}

restore_xray_state() {
  (( XRAY_BACKUP_READY )) || return 0
  if (( HAD_CONFIG )); then
    install -d -m 0750 -o root -g "$SERVICE_GROUP" "$CONFIG_DIR"
    install -m 0640 -o root -g "$SERVICE_GROUP" "$BACKUP_PATH" "$CONFIG_PATH"
  else
    rm -f -- "$CONFIG_PATH"
  fi
}

rollback_environment() {
  (( WEB_BACKUP_READY )) && systemctl stop nginx.service >/dev/null 2>&1 || true
  (( XRAY_BACKUP_READY )) && systemctl stop xray.service >/dev/null 2>&1 || true
  restore_web_state || true
  restore_xray_state || true
  if (( NGINX_WAS_ACTIVE )); then
    nginx -t >/dev/null 2>&1 && systemctl start nginx.service >/dev/null 2>&1 || true
  fi
  if (( XRAY_WAS_ACTIVE )); then
    systemctl start xray.service >/dev/null 2>&1 || true
  fi
}

install_stack_atomically() {
  local xray_candidate nginx_candidate
  xray_candidate=$(mktemp "${TMPDIR:-/tmp}/xray-wizard.XXXXXX.json")
  nginx_candidate=$(mktemp)
  render_config_stdout >"$xray_candidate"
  render_nginx_config_stdout >"$nginx_candidate"
  if ! "$XRAY_BIN" run -test -config "$xray_candidate" >/dev/null; then
    rm -f -- "$xray_candidate" "$nginx_candidate"
    die "Сгенерированный Xray JSON не прошёл xray run -test."
  fi
  backup_existing_config
  install -d -m 0750 -o root -g "$SERVICE_GROUP" "$CONFIG_DIR"
  install -m 0640 -o root -g "$SERVICE_GROUP" "$xray_candidate" "$CONFIG_PATH"
  if ! install_nginx_candidate "$nginx_candidate"; then
    rm -f -- "$xray_candidate" "$nginx_candidate"
    die "Новый конфиг Nginx не прошёл nginx -t."
  fi
  rm -f -- "$xray_candidate" "$nginx_candidate"
  systemctl daemon-reload

  if [[ "$SITE_MODE" == "fallback" ]]; then
    activate_nginx || die "Nginx не запустился с новым конфигом."
    systemctl restart xray.service || die "Xray не запустился с новым конфигом."
  else
    systemctl restart xray.service || die "Xray не запустился с новым конфигом."
    activate_nginx || die "Nginx не запустился с новым конфигом."
  fi

  systemctl enable xray.service >/dev/null
  systemctl is-active --quiet xray.service || die "Xray не активен после запуска."
  systemctl is-active --quiet nginx.service || die "Nginx не активен после запуска."
  ROLLBACK_ARMED=0
  success "Конфигурации Xray и Nginx проверены; оба сервиса запущены."
}

install_xray_config_atomically() {
  local candidate
  candidate=$(mktemp "${TMPDIR:-/tmp}/xray-wizard.XXXXXX.json")
  render_config_stdout >"$candidate"
  if ! "$XRAY_BIN" run -test -config "$candidate" >/dev/null; then
    rm -f -- "$candidate"
    die "Сгенерированный Xray JSON не прошёл xray run -test."
  fi
  backup_existing_config
  install -d -m 0750 -o root -g "$SERVICE_GROUP" "$CONFIG_DIR"
  install -m 0640 -o root -g "$SERVICE_GROUP" "$candidate" "$CONFIG_PATH"
  rm -f -- "$candidate"
  systemctl daemon-reload
  if ! systemctl restart xray.service; then
    warn "Xray не запустился; выполняю откат."
    restore_xray_state
    if (( XRAY_WAS_ACTIVE )); then
      systemctl restart xray.service || true
    else
      systemctl stop xray.service || true
    fi
    die "Новый конфиг откатан. Проверьте journalctl -u xray --no-pager -n 50."
  fi
  systemctl enable xray.service >/dev/null
  systemctl is-active --quiet xray.service || die "Xray не активен после запуска."
  ROLLBACK_ARMED=0
  success "Конфигурация проверена и Xray запущен."
}

open_firewall_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n1 | grep -q 'Status: active'; then
    if [[ "$PROTOCOL" == "hysteria2" ]]; then
      ufw allow "${PORT}/udp" >/dev/null
      [[ "$SECURITY" == "tls" ]] && ufw allow "${PORT}/tcp" >/dev/null
    else
      ufw allow "${PORT}/tcp" >/dev/null
    fi
    if [[ "$SECURITY" == "tls" ]]; then
      ufw allow 80/tcp >/dev/null
      success "UFW: открыты 80/tcp и ${PORT}/tcp$([[ "$PROTOCOL" == "hysteria2" ]] && printf ', %s/udp' "$PORT")."
    else
      success "UFW: открыт ${PORT}/tcp."
    fi
  else
    info "UFW не активен; локальное правило не менялось. Проверьте firewall/security group у VPS-провайдера."
  fi
}

write_access_file() {
  install -d -m 0700 "$OUTPUT_DIR"
  local timestamp
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  OUTPUT_FILE="${OUTPUT_DIR}/xray-clients-${timestamp}.txt"
  local latest_file="${OUTPUT_DIR}/xray-clients.txt"
  local links
  links=$(render_links_stdout)
  {
    printf '%s v%s\n' "$APP_NAME" "$APP_VERSION"
    printf 'Создано (UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Профиль: %s + %s + %s\n' "$PROTOCOL" "$TRANSPORT" "$SECURITY"
    printf 'Сервер: %s:%s\n' "$CLIENT_HOST" "$PORT"
    printf 'SNI: %s\n' "$SNI"
    [[ -n "$PATH_VALUE" ]] && printf 'Path: %s\n' "$PATH_VALUE"
    [[ -n "$SERVICE_NAME" ]] && printf 'serviceName: %s\n' "$SERVICE_NAME"
    [[ "$TRANSPORT" == "xhttp" ]] && printf 'XHTTP mode: %s\n' "$XHTTP_MODE"
    printf '\n'
    local index=0 credential uri link_label
    link_label=${PROTOCOL^^}
    while IFS=$'\t' read -r credential uri; do
      ((index += 1))
      printf '[%03d]\n' "$index"
      printf 'UUID: %s\n' "$credential"
      printf '%s: %s\n\n' "$link_label" "$uri"
    done <<<"$links"
  } >"$OUTPUT_FILE"
  chmod 0600 "$OUTPUT_FILE"
  cp -f -- "$OUTPUT_FILE" "$latest_file"
  chmod 0600 "$latest_file"
  success "UUID и ссылки сохранены: $OUTPUT_FILE"
  success "Актуальная копия: $latest_file"
}

show_result() {
  printf '\n%sГотово%s\n' "$C_BOLD" "$C_RESET"
  printf '  Xray:       %s\n' "$(current_xray_version)"
  printf '  Статус:     %s\n' "$(systemctl is-active xray.service)"
  printf '  Конфиг:     %s\n' "$CONFIG_PATH"
  printf '  Клиенты:    %s\n' "$OUTPUT_FILE"
  if [[ "$SECURITY" == "tls" ]]; then
    local site_host=${DOMAIN:-$SNI}
    [[ "$site_host" == *:* && "$site_host" != \[* ]] && site_host="[${site_host}]"
    local site_url="https://${site_host}"
    (( PORT == 443 )) || site_url="${site_url}:${PORT}"
    printf '  Сайт:       %s/\n' "$site_url"
    printf '  Nginx:      %s\n' "$(systemctl is-active nginx.service)"
  fi
  [[ -n "$BACKUP_PATH" ]] && printf '  Backup:     %s\n' "$BACKUP_PATH"
  printf '\nПроверка логов: journalctl -u xray -u nginx --no-pager -n 50\n'
  printf 'Важно: внешний firewall/security group VPS скрипт проверить не может.\n'
}

internal_render_config() {
  PROTOCOL=${WZ_PROTOCOL:?}
  TRANSPORT=${WZ_TRANSPORT:?}
  SECURITY=${WZ_SECURITY:?}
  render_config_stdout
}

internal_render_links() {
  render_links_stdout
}

internal_render_nginx() {
  render_nginx_config_stdout
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --version) printf '%s\n' "$APP_VERSION"; exit 0 ;;
    --internal-render-config) internal_render_config; exit 0 ;;
    --internal-render-links) internal_render_links; exit 0 ;;
    --internal-render-nginx) internal_render_nginx; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
  esac

  require_root
  check_os
  print_header
  warn "Работает только при публично доступных портах. NAT и firewall провайдера автоматически не исправляются."

  info "Шаг 1/3: выбор профиля и обязательных параметров."
  case "$(menu "Выберите режим" "Автоматический — минимум вопросов" "Экспертный — все параметры вручную")" in
    1) collect_auto_profile ;;
    2) collect_expert_profile ;;
  esac

  info "Шаг 2/3: проверка плана перед изменениями."
  show_plan
  confirm "Применить этот план" "n" || die "Отменено пользователем."

  info "Шаг 3/3: установка, валидация и запуск."
  install_dependencies
  install_xray
  resolve_service_identity
  check_extra_xray_configs
  configure_runtime_topology
  if [[ "$SECURITY" == "reality" ]]; then
    if [[ "$REALITY_TARGET" == "auto" ]]; then
      select_auto_reality_target
    fi
    [[ -n "$SNI" ]] || SNI=${REALITY_TARGET%:*}
    validate_reality_target_safety
    verify_reality_target
    generate_reality_material
    prepare_reality_transition
    check_target_port
  else
    check_target_port
    check_http_port_for_web
    validate_nginx_environment
    backup_existing_web_state
    install_nginx
    validate_nginx_environment
    install_placeholder_page
    prepare_tls_material
  fi

  generate_credentials
  export_render_environment
  if [[ "$SECURITY" == "tls" ]]; then
    install_stack_atomically
  else
    install_xray_config_atomically
  fi
  finalize_certificate_management
  open_firewall_port
  write_access_file
  show_result
}

if [[ "${XRAY_WIZARD_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
