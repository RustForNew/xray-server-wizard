# NaiveProxy Server Wizard

Санитизированный отчёт локальных и реальных VPS-проверок: [TESTING.md](TESTING.md).

Автономный однофайловый мастер для установки серверной части NaïveProxy на чистый
Ubuntu VPS. Проект не связан с RFN VPN и не требует его кода, базы данных или
инфраструктуры.

Версия мастера: `0.1.0`

Поддерживаемые ОС: Ubuntu Server `22.04` и `24.04`

Поддерживаемые архитектуры: `amd64`, `arm64`

Стандартный listener: `TCP/443`; для HTTP/3 дополнительно `UDP/443`

> [!WARNING]
> `klzgrad/forwardproxy` помечен авторами как experimental. Он не даёт
> абсолютной гарантии незаметности или безопасности в среде, где ошибка может
> угрожать свободе или физической безопасности пользователя.

## Что устанавливается

Сервер NaïveProxy — не отдельный процесс `naive`. Мастер собирает Caddy с
naïve-веткой `forwardproxy`, которая принимает HTTP CONNECT, выполняет Basic
Auth, padding negotiation и проксирование.

По умолчанию используется воспроизводимая комбинация:

- Caddy `v2.11.4`;
- `klzgrad/forwardproxy` commit
  `d62c80d3dd2c706b6b87579844d2397bddd18317`;
- Go `1.26.5`;
- xcaddy `0.4.5`.

Загрузки Go и xcaddy проверяются по закреплённым SHA-256. Исходная сборка
выбрана по умолчанию, потому что официальный server asset
`v2.11.2-naive` содержит более старый Caddy 2.11.2. В экспертном режиме его
можно выбрать явно с предупреждением только на `amd64`; для `arm64` используется
актуальная source build.

## Возможности

### Режимы

- **Быстрый** — домен, количество пользователей и префикс логинов.
- **Пошаговый** — основные TLS, transport, users, cover-site, ACL и PAC.
- **Экспертный** — все поддерживаемые параметры, включая upstream proxy hop,
  pooling и timeouts.
- **Non-interactive quick** — для воспроизводимого автоматического развёртывания.
- **Non-interactive manifest** — настройки и пользователи из защищённых файлов.

### TLS и transport

- автоматический публичный сертификат Caddy/ACME;
- существующие `fullchain.pem` и private key;
- проверка cert/key pair, SAN и срока действия;
- HTTPS через HTTP/2;
- QUIC через HTTP/3;
- явное отключение HTTP/3;
- опциональное отключение HTTP→HTTPS redirect.

Naïve forwardproxy должен быть catch-all listener на `:443`. Мастер намеренно
не обещает нестандартный серверный порт, потому что upstream прямо требует,
чтобы адрес начинался с `:443`.

### Пользователи

- от 1 до 500 пользователей;
- автоматическая CSPRNG-генерация;
- ручной ввод без отображения пароля;
- импорт `login<TAB>password`;
- добавление и удаление пользователей;
- ротация отдельного пароля;
- защита от дубликатов;
- логины и пароли не передаются через CLI arguments.

### Обычный сайт и probe resistance

- встроенный многофайловый адаптивный сайт;
- reverse proxy на другой HTTPS-сайт;
- HTTP redirect;
- нейтральный `404`;
- `probe_resistance` с fallthrough на сайт;
- режим secret-domain для browser auth challenge;
- секретный PAC endpoint.

Встроенный сайт содержит HTML, CSS, JavaScript и дополнительную страницу. Это
важно для новых клиентов NaïveProxy, которые могут использовать URL со
стартовой HTML-страницы для preamble-трафика.

### Egress и privacy

- `hide_ip`;
- `hide_via`;
- web-only destination ports `80 443`;
- расширенный или собственный список портов;
- unrestricted-режим с предупреждением;
- усиленная блокировка loopback, RFC1918, CGNAT, link-local, metadata, ULA и
  multicast;
- собственный deny-list;
- allow-list;
- встроенный ACL плагина;
- следующий HTTPS/SOCKS5 proxy hop.

`upstream` несовместим с `ports` и `acl` в самом forwardproxy. Мастер
автоматически исключает это невозможное сочетание.

### Эксплуатация

- отдельный binary `/usr/local/bin/caddy-naive`;
- отдельный `naiveproxy-caddy.service`;
- отдельный непривилегированный пользователь;
- systemd hardening и только `CAP_NET_BIND_SERVICE`;
- синхронизация собственных правил активного UFW;
- `caddy adapt --validate` и `caddy validate` от service user;
- TLS/ALPN H2, TCP/UDP listeners и authenticated CONNECT smoke, если выбранные
  ACL/порты допускают стандартную контрольную цель;
- config drift detection;
- глобальный `flock`;
- snapshot до первой мутации управляемых файлов;
- автоматический rollback при ошибке или сигнале;
- обнаружение незавершённой transaction после аварии;
- ручной откат к предыдущему snapshot;
- безопасное удаление только wizard-owned файлов.

## Требования

- чистый Ubuntu Server 22.04 или 24.04;
- root или `sudo`;
- публичный IPv4;
- домен с A-записью на VPS;
- корректный AAAA, если он существует;
- DNS-запись без CDN/reverse proxy, который не пропускает CONNECT;
- свободный TCP/443;
- свободный UDP/443 для HTTP/3;
- свободный TCP/80 для надёжного ACME и redirect;
- открытые security group/firewall порты у VPS-провайдера;
- исходящий HTTPS-доступ к GitHub, `go.dev` и Go module proxy/source hosts.

Для source build желательно не менее 1.5 GiB суммарной RAM+swap и около 3 GiB
свободного диска после распаковки toolchain. Если памяти меньше, мастер временно
создаёт swap-файл 2 GiB в собственном build-каталоге и удаляет его после сборки.
В этом случае требуется около 5 GiB свободного диска после распаковки toolchain.

Мастер не может автоматически изменить NAT, CGNAT, DNS-панель или внешний
firewall VPS-провайдера без отдельных API-доступов.

## Запуск

### Установка одной командой с GitHub

```bash
sudo apt-get update && sudo apt-get install -y curl
curl -fL https://raw.githubusercontent.com/RustForNew/xray-server-wizard/main/NaiveProxy/naiveproxy-server-wizard.sh -o naiveproxy-server-wizard.sh
chmod 700 naiveproxy-server-wizard.sh
sudo bash ./naiveproxy-server-wizard.sh
```

При работе непосредственно под `root` уберите `sudo`.

### Запуск из скопированного проекта

Скопировать проект на VPS и выполнить:

```bash
chmod 700 naiveproxy-server-wizard.sh
sudo bash ./naiveproxy-server-wizard.sh
```

После первой установки мастер копируется в:

```text
/usr/local/sbin/naiveproxy-wizard
```

Повторный запуск:

```bash
sudo naiveproxy-wizard
```

### Non-interactive quick

```bash
sudo bash ./naiveproxy-server-wizard.sh \
  --apply-quick proxy.example.com 3 user --yes
```

Пароли генерируются внутри root-процесса и не появляются в командной строке.

### Non-interactive manifest

```bash
sudo bash ./naiveproxy-server-wizard.sh \
  --apply-manifest /root/settings.json /root/users.tsv --yes
```

Полный рабочий шаблон находится в
[`examples/settings.example.json`](examples/settings.example.json). Скопируйте
его, измените домен и нужные параметры. Основные enum:

- `tls.mode`: `acme` или `existing`; для `existing` задайте абсолютные исходные
  пути `tls.certificate` и `tls.private_key`;
- `decoy.mode`: `static`, `reverse_proxy`, `redirect`, `respond`;
- `privacy.probe_mode`: `fallthrough` или `secret_domain`;
- `egress.target_ports_mode`: `web`, `common`, `custom`, `unrestricted`;
- `egress.acl_mode`: `hardened`, `custom_deny`, `allowlist`, `plugin_default`;
- `server_build_mode`: `source_patched` или `upstream_prebuilt`
  (`upstream_prebuilt` только для `amd64`).

`egress.upstream` может содержать credentials. При непустом `upstream` требуется
`target_ports_mode=unrestricted` и `acl_mode=plugin_default`, потому что сам
forwardproxy не совмещает upstream hop с `ports`/`acl`.

`users.tsv`:

```text
alice<TAB>long-random-password
bob<TAB>another-long-random-password
```

Оба входных файла должны принадлежать `root`, иметь права `0600` и не быть
symlink:

```bash
sudo chown root:root /root/settings.json /root/users.tsv
sudo chmod 600 /root/settings.json /root/users.tsv
```

## Клиентские файлы

По умолчанию:

```text
/root/naiveproxy-clients/
```

Для каждого пользователя создаются:

- `native-<N>-<user>-h2.json`;
- `native-<N>-<user>-h3.json`, если включён HTTP/3;
- `sing-box-<N>-<user>-h2.json`;
- `sing-box-<N>-<user>-h3.json`, если включён HTTP/3.

Общие файлы:

- `clients.txt`;
- `install-report.json` без credentials;
- `checksums.sha256`.

Каталог имеет права `0700`, файлы — `0600`. Терминал показывает только путь,
но не пароли.

Пример native client:

```json
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://user:password@proxy.example.com"
}
```

Для QUIC используется `quic://`.

### Первый запуск клиента

Скопируйте защищённый bundle с VPS на свою машину по SSH:

```bash
scp -r root@SERVER_IP:/root/naiveproxy-clients ./
```

Скачайте native NaïveProxy из официального релиза
[`v150.0.7871.63-1`](https://github.com/klzgrad/naiveproxy/releases/tag/v150.0.7871.63-1)
для своей ОС и архитектуры, распакуйте и запустите H2-конфигурацию:

```bash
./naive ./naiveproxy-clients/native-001-user-001-h2.json
```

Затем проверьте локальный SOCKS:

```bash
curl --proxy socks5h://127.0.0.1:1080 https://www.cloudflare.com/cdn-cgi/trace
```

Для HTTP/3 запустите соответствующий файл `*-h3.json`. Bundle содержит секреты:
храните его как пароль и не отправляйте в публичные чаты или репозитории.

## Файлы сервера

```text
/usr/local/bin/caddy-naive
/usr/local/sbin/naiveproxy-wizard
/etc/naiveproxy-wizard/
/var/lib/naiveproxy-wizard/
/var/lib/naiveproxy-wizard/backups/
/var/www/naiveproxy-wizard/
/var/log/naiveproxy-wizard/
/etc/systemd/system/naiveproxy-caddy.service
/root/naiveproxy-clients/
```

Credentials находятся в `/etc/naiveproxy-wizard/users.tsv`, сгенерированном
Caddyfile, `clients.txt`, клиентских JSON и transaction backup. Basic Auth по
определению требует обратимо доступного секрета; это не хеш пароля. Рабочие
серверные файлы доступны только root и service group, client bundle — только
root. Старые rotated/revoked credentials остаются в защищённых backup до их
ручного удаления; автоматической retention-политики пока нет.

## Диагностика

Быстрый локальный статус без ожидания TLS и внешнего запроса:

```bash
sudo naiveproxy-wizard --status
```

```bash
sudo naiveproxy-wizard --diagnose
```

Проверяются:

- systemd active/enabled;
- Caddy version;
- наличие `http.handlers.forward_proxy`;
- config drift;
- TCP/443;
- UDP/443 согласно выбранному transport;
- публичный TLS;
- ALPN `h2`;
- авторизованный CONNECT до внешнего HTTPS-сайта, если ACL и список портов
  разрешают стандартную контрольную цель; иначе этот шаг явно пропускается.

## Проверка проекта

Windows с Git Bash:

```powershell
python tests/test_wizard.py
shellcheck -x naiveproxy-server-wizard.sh
```

Linux:

```bash
bash -n naiveproxy-server-wizard.sh
python3 tests/test_wizard.py
shellcheck -x naiveproxy-server-wizard.sh
```

Автотесты покрывают validation, Caddyfile renderer, H2/H3, ACL, upstream,
reverse proxy, несколько пользователей, URI encoding, client bundle и
отсутствие credentials в отчёте.

## Объективные ограничения

- Нельзя гарантировать работу у любого VPS-провайдера.
- HTTP/3 может блокироваться или ограничиваться сетью.
- CDN перед доменом обычно несовместим с обычным CONNECT NaïveProxy.
- Self-signed TLS не поддерживается как production-вариант: он заметно меняет
  сетевой профиль.
- Мастер отказывается автоматически объединять неизвестный существующий
  Caddy/Nginx на 443.
- apt-зависимости и созданный системный пользователь не удаляются при
  автоматическом rollback.
- Backup не очищаются автоматически и могут содержать старые credentials.
- Внешний smoke с отдельного клиента необходим перед реальным использованием.
- Клиент NaïveProxy следует регулярно обновлять вместе с Chromium.

## Upstream

- [NaïveProxy](https://github.com/klzgrad/naiveproxy)
- [naïve forwardproxy](https://github.com/klzgrad/forwardproxy/tree/naive)
- [Caddy](https://github.com/caddyserver/caddy)
- [xcaddy](https://github.com/caddyserver/xcaddy)
- [sing-box Naive outbound](https://sing-box.sagernet.org/configuration/outbound/naive/)
