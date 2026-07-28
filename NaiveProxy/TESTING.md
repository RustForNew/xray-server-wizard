# Проверка NaiveProxy Server Wizard

Дата проверки: 2026-07-27.

В отчёте нет паролей, proxy URI и содержимого клиентских конфигураций.

## Локальные проверки

- `python tests/test_wizard.py`: 45/45 тестов пройдено.
- `bash -n naiveproxy-server-wizard.sh`: пройдено.
- ShellCheck 0.11.0: замечаний нет.
- Примеры `settings.example.json` и `users.example.tsv` проходят встроенную валидацию.

## Реальный VPS

Проверенная среда:

- чистый Ubuntu Server 22.04 x86_64;
- домен `test.ge-rfn.life`, DNS-only;
- Caddy 2.11.4;
- закреплённый `klzgrad/forwardproxy` commit;
- NaiveProxy client 150.0.7871.63 для Windows x64;
- два сгенерированных пользователя;
- ACME, статический cover-site, H2 и HTTP/3;
- UFW на исходном VPS был неактивен, поэтому мастер по контракту не включал его автоматически.

Сервер начинал как чистый. После исходной установки финальная ревизия мастера была
применена повторно через `--apply-manifest` с сохранением пользователей. Повторная
компиляция не потребовалась: мастер проверил и переиспользовал установленный Caddy.

Пройдены:

- source build Caddy на VPS с 1 GiB RAM и временным swap 2 GiB;
- удаление build-каталога и временного swap после сборки;
- получение доверенного сертификата, SAN и запас срока более семи дней;
- Caddy `adapt --validate` и `validate` от service user;
- наличие `http.handlers.forward_proxy`;
- active/enabled systemd service;
- TCP/443, UDP/443 и отсутствие listener административного API на 2019;
- `0750` для каталога конфигурации, `0640` для конфигурации/пользователей/manifest;
- `0700`/`0600` для клиентского bundle;
- `0755`/`0644` для cover-site и его assets;
- внешняя загрузка главной страницы и CSS;
- отсутствие config drift и незавершённой transaction;
- отсутствие логинов и паролей в journal, установочных логах и process arguments;
- оба пользователя через native client по H2 (`https://`);
- оба пользователя через native client по QUIC/H3 (`quic://`);
- egress IP клиента совпадает с IP VPS;
- отклонение случайного неверного пароля;
- отклонение подключения к HTTPS proxy без credentials;
- блокировка через proxy серверного loopback, metadata/link-local, RFC1918 и IPv6 ULA;
- 12 параллельных запросов;
- передача официального Windows-архива клиента через proxy со сверкой SHA-256;
- idempotent повторное применение manifest;
- автоматический rollback после `NAIVE_WIZARD_FAILPOINT=config_committed`;
- сохранение сервиса, пользователей и client connectivity после rollback;
- удаление второго пользователя, сохранение работы первого и отклонение старого
  клиентского конфига отозванного пользователя;
- восстановление исходных двух пользователей и повторная проверка H2/H3;
- реальная перезагрузка VPS, новый boot ID, автоматический старт сервиса и
  повторная внешняя проверка H2/H3.

Один вызов `--diagnose` сразу после fault-injection вернул временную ошибку
контрольного внешнего сайта. Повторный вызов и native-client H2/H3 прошли; сервер,
TLS, сайт и listeners в этот момент оставались рабочими.

## Найдено и исправлено во время E2E

- ожидание блокировки `dpkg` на свежем Ubuntu;
- ложное отсутствие forwardproxy из-за `grep -q` и `pipefail`;
- порядок создания service identity и transaction;
- очистка временного swap/build state;
- права каталога статических assets при строгом `umask`;
- ослабление mode существующего config-каталога атомарной записью;
- предупреждение Bash при помещении NUL-байтов OpenSSL в переменную;
- требование свободного диска для source build с временным swap.

## Что не проверено на отдельной реальной машине

Следующие ветки покрыты локальной валидацией/рендерингом, но не полным VPS E2E:

- Ubuntu 24.04;
- arm64;
- existing certificate вместо ACME;
- активный UFW и облачный firewall;
- legacy prebuilt Caddy;
- reverse proxy, redirect и neutral 404 вместо статического cover-site;
- custom ACL/ports, upstream proxy, PAC и secret probe domain;
- interactive PTY-прохождение каждой ветки guided/expert;
- packet capture QUIC. Работоспособность HTTP/3 доказана функционально отдельным
  native-конфигом `quic://`.

Модуль forwardproxy сам upstream помечает как experimental. Результаты выше не
являются гарантией доступности в любой сети, абсолютной анонимности или обхода
конкретной системы фильтрации.
