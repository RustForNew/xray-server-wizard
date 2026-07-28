# Xray Server Wizard

Однофайловый интерактивный установщик Xray-core для Ubuntu Server 22.04.

Версия: `0.2.3`  
Runtime-файл: `xray-server-wizard.sh`

## NaiveProxy Server Wizard

Отдельный мастер NaiveProxy находится в папке
[`NaiveProxy`](NaiveProxy/README.md). Он не зависит от Xray Server Wizard и
устанавливается отдельным сервисом.

Быстрая установка на Ubuntu:

```bash
sudo apt-get update && sudo apt-get install -y curl
curl -fL https://raw.githubusercontent.com/RustForNew/xray-server-wizard/main/NaiveProxy/naiveproxy-server-wizard.sh -o naiveproxy-server-wizard.sh
chmod 700 naiveproxy-server-wizard.sh
sudo bash ./naiveproxy-server-wizard.sh
```

Прямая загрузка установщика:
[`naiveproxy-server-wizard.sh`](https://raw.githubusercontent.com/RustForNew/xray-server-wizard/main/NaiveProxy/naiveproxy-server-wizard.sh).

## Требования

- Ubuntu Server 22.04;
- root-доступ или пользователь с `sudo`;
- systemd;
- публичный IPv4;
- открытые порты в firewall/security group VPS-провайдера;
- домен с готовой A-записью для TLS;
- доступный `80/tcp` для Let's Encrypt HTTP-01;
- доступный UDP-порт для Hysteria2.

## Установка с GitHub

Выполнить на VPS:

```bash
sudo apt-get update && sudo apt-get install -y curl
curl -fL https://raw.githubusercontent.com/RustForNew/xray-server-wizard/main/xray-server-wizard.sh -o xray-server-wizard.sh
chmod 700 xray-server-wizard.sh && sudo bash ./xray-server-wizard.sh
```

При работе под `root`:

```bash
apt-get update && apt-get install -y curl
curl -fL https://raw.githubusercontent.com/RustForNew/xray-server-wizard/main/xray-server-wizard.sh -o xray-server-wizard.sh
chmod 700 xray-server-wizard.sh && bash ./xray-server-wizard.sh
```

Проверка версии:

```bash
bash ./xray-server-wizard.sh --version
```

Повторный запуск:

```bash
sudo bash ./xray-server-wizard.sh
```

## Режимы

### Автоматический

1. Выбрать протокол и транспорт.
2. Выбрать TLS или REALITY, если транспорт поддерживает оба варианта.
3. Указать количество пользователей.
4. Для TLS указать домен с готовой DNS-записью.
5. Проверить план и подтвердить установку.

Автоматически создаются порт, UUID/credentials, path, `serviceName`, XHTTP mode, REALITY keys, short ID, конфигурации Xray/Nginx и клиентские ссылки.

### Экспертный

Доступны ручные параметры:

- протокол;
- транспорт;
- TLS или REALITY;
- порт сервера;
- адрес сервера в клиентской ссылке;
- количество пользователей;
- XHTTP path;
- XHTTP mode;
- gRPC `serviceName`;
- WebSocket path;
- REALITY target;
- REALITY SNI;
- получение Let's Encrypt или подключение существующего certificate/key;
- префикс названий подключений.

## Поддерживаемые профили

| Протокол | Транспорт | TLS | REALITY |
|---|---|---:|---:|
| VLESS | TCP/RAW | да | да |
| VLESS | XHTTP | да | да |
| VLESS | gRPC | да | да |
| VLESS | WebSocket | да | нет |
| Trojan | TCP/RAW | да | да |
| Trojan | XHTTP | да | да |
| Trojan | gRPC | да | да |
| Trojan | WebSocket | да | нет |
| Hysteria2 | Hysteria/QUIC | да | нет |

Всего: 15 профилей.

### VLESS

- ссылки `vless://`;
- отдельный UUID для каждого пользователя;
- `xtls-rprx-vision` для TCP/RAW;
- от 1 до 500 пользователей.

### Trojan

- ссылки `trojan://`;
- отдельный credential для каждого пользователя;
- от 1 до 500 пользователей.

### Hysteria2

- ссылки `hysteria2://`;
- QUIC/UDP;
- обязательный TLS;
- от 1 до 500 пользователей.

## Транспорты

### TCP/RAW

- TLS;
- REALITY;
- VLESS Vision;
- TLS fallback на локальный сайт Nginx.

### XHTTP

- TLS;
- REALITY;
- собственный path;
- modes: `auto`, `packet-up`, `stream-up`, `stream-one`.

### gRPC

- TLS;
- REALITY;
- собственный `serviceName`.

### WebSocket

- TLS;
- собственный path;
- собственный Host/SNI.

### Hysteria2

- Hysteria transport;
- QUIC/UDP;
- TLS.

## TLS

Автоматическая конфигурация TLS включает:

- установку Nginx и Certbot;
- проверку A/AAAA домена;
- Let's Encrypt HTTP-01;
- HTTPS-сайт-заглушку;
- постоянный ACME webroot;
- Certbot deploy-hook;
- проверку `nginx -t`;
- проверку и запуск Xray/Nginx.

В экспертном режиме можно указать существующие certificate/key.

## REALITY

Автоматическая конфигурация REALITY включает:

- X25519 key pair;
- short ID;
- fingerprint `chrome`;
- target и SNI;
- проверку TLS target;
- защиту от target, направленного на этот же VPS и тот же порт.

Адрес VPS указывается в поле адреса клиентского подключения. REALITY target указывается отдельно.

## Результат

Основной файл с подключениями:

```text
/root/xray-clients.txt
```

Архивная копия каждого запуска:

```text
/root/xray-clients-<UTC timestamp>.txt
```

Формат записи:

```text
[001]
UUID: <credential>
VLESS: <connection URI>
```

Для Trojan используется поле `TROJAN`, для Hysteria2 — `HYSTERIA2`. Права файлов: `0600`.

## Файлы на сервере

```text
/usr/local/bin/xray
/usr/local/etc/xray/config.json
/usr/local/etc/xray/certs/xray-server-wizard/
/var/lib/xray-server-wizard/backups/
/var/www/xray-server-wizard/index.html
/etc/nginx/sites-available/xray-server-wizard
/root/xray-clients.txt
```

## Проверки и откат

Перед применением мастер:

1. Показывает итоговый план.
2. Проверяет занятость TCP/UDP-портов.
3. Создаёт backup управляемых файлов.
4. Проверяет Xray командой `xray run -test`.
5. Проверяет Nginx командой `nginx -t`.
6. Запускает systemd-сервисы.
7. Проверяет состояние сервисов.
8. Восстанавливает предыдущую конфигурацию при ошибке.

Если UFW активен, мастер добавляет правила для выбранных TCP/UDP-портов.

## Обновление

```bash
curl -fL https://raw.githubusercontent.com/RustForNew/xray-server-wizard/main/xray-server-wizard.sh -o xray-server-wizard.sh
chmod 700 xray-server-wizard.sh
sudo bash ./xray-server-wizard.sh
```

## Ограничения

- создаётся один inbound-профиль за запуск;
- управляемый Xray-конфиг заменяется после создания backup;
- произвольные существующие Xray-конфиги не объединяются;
- сторонние активные конфигурации Nginx автоматически не изменяются;
- CDN не настраивается;
- wildcard-сертификаты и DNS-01 не поддерживаются;
- NAT, CGNAT и firewall/security group VPS-провайдера не настраиваются;
- доступность UDP зависит от VPS-провайдера;
- требуется клиент с поддержкой выбранного профиля;
- минимальная версия Xray-core: `26.3.27`.

## Проверка проекта

```bash
bash -n xray-server-wizard.sh
python tests/test_wizard.py
```

Проверка конфигураций через Xray и Nginx:

```bash
XRAY_BIN=/path/to/xray NGINX_BIN=/path/to/nginx python tests/test_wizard.py
```

## Файлы репозитория

```text
xray-server-wizard.sh
README.md
CHANGELOG.md
tests/test_wizard.py
```
