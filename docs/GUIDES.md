# familyTraffic VPN — Руководство

**v5.33** · [← README](../README.md)

---

## Содержание

1. [Предварительные требования](#1-предварительные-требования)
2. [Установка](#2-установка)
3. [Управление пользователями](#3-управление-пользователями)
4. [Подключение клиентов](#4-подключение-клиентов)
5. [SOCKS5 и HTTP прокси](#5-socks5-и-http-прокси)
6. [Tier 2 транспорты (WS / XHTTP / gRPC)](#6-tier-2-транспорты-ws--xhttp--grpc)
7. [Reverse proxy](#7-reverse-proxy)
8. [External proxy](#8-external-proxy)
9. [Обновление сертификатов](#9-обновление-сертификатов)
10. [Диагностика](#10-диагностика)
11. [Удаление](#11-удаление)
12. [Обновление версии](#12-обновление-версии)

---

## 1. Предварительные требования

**Сервер:**
- Ubuntu 20.04+ или Debian 10+
- Публичный IPv4-адрес
- Открытые входящие порты: `443`, `1080`, `8118`

**Для TLS-прокси, Tier 2, Reverse proxy:**
- Домен с A-записью, указывающей на IP сервера
- Email для Let's Encrypt

**Зависимости** (устанавливает `install.sh`):
- Docker 24+, Docker Compose v2
- certbot
- ufw, jq, qrencode

---

## 2. Установка

```bash
git clone <repo-url>
cd vless
sudo ./install.sh
```

Установщик пройдёт через шаги:

1. **Проверка системы** — Docker, UFW, порты, DNS
2. **Reality параметры** — домен маскировки (например, `www.microsoft.com`), порт (`443`)
3. **Домен и email** — для Let's Encrypt (опционально, нужен для прокси)
4. **DNS** — автоматическое тестирование Cloudflare/Google/Quad9, выбор оптимального
5. **Прокси-режим** — включить SOCKS5/HTTP прокси или нет
6. **Запуск** — генерация конфигов, старт контейнеров, выпуск сертификата

По окончании установщик выведет URI и QR код для первого пользователя.

**Файлы устанавливаются в `/opt/familytraffic/`:**

```
/opt/familytraffic/
├── config/
│   ├── xray_config.json         # Конфигурация Xray
│   ├── nginx/nginx.conf         # Конфигурация nginx (stream + http, внутри familytraffic)
│   ├── reverse-proxy/           # Legacy: конфиги reverse proxy (удалён в v5.33)
│   └── keys/                    # Reality ключи (private.key, public.key)
├── data/
│   ├── users.json               # База пользователей
│   ├── transports.json          # Tier 2 транспорты
│   └── clients/<name>/          # Конфигурации клиентов (URI, QR, proxy-файлы)
└── logs/
    ├── xray/
    └── nginx/
```

**Контейнеры Docker:**

| Контейнер | Назначение | Всегда |
|---|---|---|
| `familytraffic` | Единый контейнер: nginx (SNI routing 443, TLS termination 1080/8118, Tier 2 8448) + xray + certbot-cron + supervisord | ✅ |
| `familytraffic-mtproxy` | Telegram MTProxy (опциональный, отдельный контейнер) | Опционально |

**CLI-инструменты** после установки:
```
/usr/local/bin/familytraffic
/usr/local/bin/familytraffic-external-proxy
/usr/local/bin/familytraffic-cert-renew
```

---

## 3. Управление пользователями

### Добавить пользователя

```bash
sudo familytraffic add-user <name>
```

Команда:
- Генерирует UUID и fingerprint
- Добавляет пользователя в `xray_config.json` с `flow: xtls-rprx-vision`
- Выводит VLESS URI и QR код
- Создаёт конфиги в `/opt/familytraffic/data/clients/<name>/`

### Показать пользователя

```bash
sudo familytraffic show-user <name>
```

Выводит URI, QR код, SOCKS5/HTTP прокси URI (если прокси включён).

### Список пользователей

```bash
sudo familytraffic list-users
```

### Удалить пользователя

```bash
sudo familytraffic remove-user <name>
```

### Перегенерировать клиентские файлы

```bash
sudo familytraffic regenerate <name>
```

Пересоздаёт клиентские файлы (`vless_uri.txt`, `vless_qr.png`, proxy-конфиги) на основе **текущих настроек сервера** — IP, Reality ключей, shortId из `users.json`.

Нужно запускать после:
- **Миграции на новый сервер** — если изменился IP или были сгенерированы новые Reality ключи (`pbk`)
- **Смены домена** — для обновления proxy URI
- **Ручного изменения** `xray_config.json` или `keys/public.key`

Для всех VPN-пользователей сразу:
```bash
sudo familytraffic list-users | grep -oP '(?<=  )\S+' | xargs -I{} sudo familytraffic regenerate {}
```

После регенерации файлы находятся в `/opt/familytraffic/data/clients/<name>/` — раздайте пользователям новые ссылки.

> **Важно:** После смены Reality ключей все клиенты должны обновить конфиг в приложении. Старые ссылки с устаревшим `pbk` работать не будут.

### Миграция на XTLS Vision

Если на сервере есть пользователи без поля `flow` (созданные до v5.25):

```bash
sudo familytraffic migrate-vision
```

---

## 4. Подключение клиентов

### Получить URI

```bash
sudo familytraffic show-user <name>
```

URI имеет формат:
```
vless://UUID@SERVER:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp#name
```

### Рекомендуемые приложения

| Платформа | Приложение | Протокол |
|---|---|---|
| Android | v2rayNG | VLESS Reality, WS, gRPC |
| iOS | v2rayTun | VLESS Reality, WS, gRPC |
| iOS | Shadowrocket | VLESS Reality |
| Windows | v2rayN | VLESS Reality, WS, gRPC |
| macOS / Linux | v2rayA | VLESS Reality, WS |

Импортируйте URI через QR код или вставкой в буфер обмена.

### Настройки клиента (вручную)

| Параметр | Значение |
|---|---|
| Protocol | VLESS |
| Address | IP или домен сервера |
| Port | 443 |
| UUID | из `vless show-user` |
| Flow | xtls-rprx-vision |
| Security | reality |
| SNI | домен маскировки (например, `www.microsoft.com`) |
| Fingerprint | chrome |
| Public Key | из `vless show-user` |
| Short ID | из `vless show-user` |
| Network | tcp |

---

## 5. SOCKS5 и HTTP прокси

Прокси использует TLS-терминацию через nginx (внутри контейнера `familytraffic`). Нужен домен с сертификатом.

### Схемы подключения

```
SOCKS5:  socks5s://username:password@DOMAIN:1080
HTTP:    https://username:password@DOMAIN:8118
```

`vless show-user <name>` выводит готовые URI для обоих протоколов.

### Проверить подключение

```bash
curl --socks5 username:password@DOMAIN:1080 https://ifconfig.me
curl --proxy https://username:password@DOMAIN:8118 https://ifconfig.me
```

### Настройка в инструментах

**Git:**
```bash
git config --global http.proxy socks5s://username:password@DOMAIN:1080
```

**npm:**
```bash
npm config set proxy https://username:password@DOMAIN:8118
```

**Docker daemon** (`/etc/docker/daemon.json`):
```json
{
  "proxies": {
    "https-proxy": "https://username:password@DOMAIN:8118"
  }
}
```

Готовые файлы конфигурации для каждого пользователя — в `/opt/familytraffic/data/clients/<name>/`.

---

## 6. Tier 2 транспорты (WS / XHTTP / gRPC)

Tier 2 транспорты используют TLS-терминацию через Nginx http-блок (порт 8448, loopback).
Требуют отдельного поддомена и сертификата для каждого транспорта.

### Архитектура Tier 2

```
Client → TCP:443 → familytraffic (nginx stream, ssl_preread)
  └─ SNI ws.domain → 127.0.0.1:8448 (nginx http block, inside familytraffic)
       └─ proxy_pass → 127.0.0.1:8448 (xray WS/XHTTP/gRPC plaintext)
```

### Включить транспорт

```bash
sudo familytraffic add-transport ws   ws.yourdomain.com
sudo familytraffic add-transport xhttp xhttp.yourdomain.com
sudo familytraffic add-transport grpc  grpc.yourdomain.com
```

Команда:
- Добавляет inbound в `xray_config.json` (не затрагивает существующих пользователей)
- Обновляет `nginx.conf`: SNI map + http server block
- Перезагружает nginx внутри контейнера (zero-downtime via supervisorctl)

### Список активных транспортов

```bash
sudo familytraffic list-transports
```

### Отключить транспорт

```bash
sudo familytraffic remove-transport ws
```

### URI для Tier 2

URI генерируется функцией `generate_transport_uri()`. Пример для WebSocket:
```
vless://UUID@ws.domain:443?encryption=none&security=tls&sni=ws.domain&fp=chrome&type=ws&path=%2Fvless-ws#name-ws
```

### Совместимость

| Транспорт | Android (v2rayNG) | iOS (v2rayTun) | Windows (v2rayN) |
|---|---|---|---|
| WebSocket | ✅ | ✅ | ✅ |
| XHTTP | ✅ | ⚠️ требует проверки | ✅ |
| gRPC | ✅ | ✅ | ✅ |

---

## 7. Reverse proxy

Reverse proxy открывает внешний сайт через ваш поддомен без VPN. Требует домен.

### Добавить

```bash
sudo familytraffic-proxy add
```

Интерактивный wizard запросит:
- Поддомен (например, `claude.yourdomain.com`)
- Целевой сайт (например, `claude.ai`)
- Email для сертификата

После добавления сайт доступен по `https://claude.yourdomain.com`.

### Управление

```bash
sudo familytraffic-proxy list              # Список всех routes
sudo familytraffic-proxy show <domain>     # Детали конкретного route
sudo familytraffic-proxy remove <domain>   # Удалить route
```

---

## 8. External proxy

External proxy — upstream proxy, через который Xray пробрасывает трафик.

### Server-level: все пользователи через один proxy

```bash
# Добавить proxy
sudo familytraffic-external-proxy add
# Wizard запросит: тип (socks5/http), адрес, порт, credentials

# Активировать
sudo familytraffic-external-proxy switch <proxy-id>
sudo familytraffic-external-proxy enable

# Статус
sudo familytraffic-external-proxy status
```

### Per-user: у каждого пользователя свой proxy

```bash
# Назначить proxy пользователю
sudo familytraffic set-proxy alice proxy-id

# Вернуть на direct routing
sudo familytraffic set-proxy alice none

# Показать назначение
sudo familytraffic show-proxy alice

# Список всех назначений
sudo familytraffic list-proxy-assignments
```

Per-user proxy работает только для VLESS (email-based routing). SOCKS5/HTTP прокси не поддерживают user-based routing.

---

## 9. Обновление сертификатов

Certbot обновляет сертификаты автоматически через `--deploy-hook`. После обновления хук:

1. Валидирует новые файлы сертификата
2. Проверяет здоровье контейнера `familytraffic` (supervisorctl status)
3. Выполняет `nginx -s reload` (zero-downtime)
4. Перезапускает `familytraffic`

**Принудительное обновление:**
```bash
sudo certbot renew --force-renewal
```

**Ручной вызов хука:**
```bash
RENEWED_DOMAINS="yourdomain.com" sudo /usr/local/bin/familytraffic-cert-renew
```

**Логи:**
```
/opt/familytraffic/logs/certbot-renew.log
/opt/familytraffic/logs/certbot-renew-metrics.json
```

---

## 10. Диагностика

### Статус

```bash
sudo familytraffic status           # Контейнеры, пользователи, прокси, транспорты
docker ps                   # Детальный статус контейнеров
```

### Логи

```bash
sudo familytraffic logs xray        # Xray логи
sudo familytraffic logs nginx       # Nginx логи
sudo familytraffic logs all         # Все логи
docker logs familytraffic --tail 50
docker logs familytraffic --tail 50
```

### Тесты безопасности

```bash
sudo familytraffic test-security            # Полный набор тестов
sudo familytraffic test-security --quick    # Без packet capture
```

### Проверка конфигурации

```bash
# Nginx
docker exec familytraffic nginx -t

# Xray JSON
jq empty /opt/familytraffic/config/xray_config.json && echo "OK"

# Порты
sudo ss -tulnp | grep -E '443|1080|8118'
```

### Частые проблемы

**Xray unhealthy — неправильный порт**

Xray должен слушать на `8443`, не `443`. Проверить:
```bash
jq '.inbounds[0].port' /opt/familytraffic/config/xray_config.json  # должно быть 8443
```

**Nginx не запускается**

```bash
docker exec familytraffic nginx -t  # покажет ошибку в конфиге
docker logs familytraffic --tail 30
```

**Нет интернета в контейнерах (UFW блокирует Docker)**

```bash
# Проверить
docker exec familytraffic ping -c 1 8.8.8.8

# Исправить — добавить в /etc/ufw/after.rules Docker-цепочки, затем:
sudo ufw reload
```

**Cert renewal падает — nginx не запущен внутри familytraffic**

```bash
docker exec familytraffic supervisorctl start nginx
# Затем повторить:
RENEWED_DOMAINS="domain" sudo familytraffic-cert-renew
```

---

## 11. Удаление

```bash
sudo /opt/familytraffic/scripts/vless-uninstall
```

Создаёт резервную копию в `/tmp/familytraffic_backup_YYYYMMDD/`, затем удаляет:
- `/opt/familytraffic/`
- Docker-контейнеры и volumes
- UFW-правила
- Симлинки в `/usr/local/bin/`

---

## 12. Обновление версии

### Как устроено версионирование

CI собирает и публикует образ в GHCR с двумя тегами:
- `:latest` — всегда указывает на последний билд
- `:<version>` — зафиксированная версия (например, `1.1.4`)

Версия читается из файла `VERSION` в корне репозитория. Изменение `VERSION` является **единственным триггером** для запуска сборки при пуше в ветку `test`.

### Как выпустить новую версию

**1. Обновить файл VERSION:**

```bash
echo "1.2.0" > VERSION
```

Формат: `MAJOR.MINOR.PATCH` (например, `1.1.4`, `1.2.0`, `2.0.0`).

**2. Зафиксировать и запушить в ветку `test`:**

```bash
git add VERSION
git commit -m "chore: bump version to 1.2.0"
git push origin test
```

После пуша CI автоматически:
- Собирает Docker-образ
- Публикует `ghcr.io/<owner>/familytraffic:latest` и `ghcr.io/<owner>/familytraffic:1.2.0`
- Отправляет уведомление в Telegram

**3. Обновить сервер:**

```bash
cd /opt/familytraffic
docker compose pull
docker compose up -d
```

Контейнер поднимется с тегом, указанным в `/opt/familytraffic/.env` → `FT_IMAGE_TAG` (по умолчанию `latest`).

### Установка конкретной версии

Если нужно зафиксировать сервер на определённой версии вместо `latest`:

```bash
# При первичной установке
FT_IMAGE_TAG=1.2.0 sudo ./install.sh

# На уже установленном сервере
sed -i 's/^FT_IMAGE_TAG=.*/FT_IMAGE_TAG=1.2.0/' /opt/familytraffic/.env
cd /opt/familytraffic && docker compose pull && docker compose up -d
```

### Откат на предыдущую версию

```bash
sed -i 's/^FT_IMAGE_TAG=.*/FT_IMAGE_TAG=1.1.4/' /opt/familytraffic/.env
cd /opt/familytraffic && docker compose pull && docker compose up -d
```

Убедиться, что образ с нужным тегом существует в реестре:
```bash
docker manifest inspect ghcr.io/<owner>/familytraffic:1.1.4
```

## Proxy authentication protection

Public proxy ports use UFW ALLOW rules. TCP connection frequency is not an authentication signal. The dedicated `familytraffic-proxy-auth` jail counts credential mismatches instead. Existing project-managed LIMIT rules are reconciled during the security migration. Custom source restrictions require operator review.

Check the effective configuration after installation or an image-only update:

```bash
sudo familytraffic-security check
```

A nonzero result means protection has not been verified. Resolve the diagnostic before treating deployment as successful. General process health alone does not prove authentication, source attribution, or bans.

The proxy client address may change. No fixed client-IP allowlist is required. Five credential failures in 600 seconds ban the source IP on enabled proxy ports for 3600 seconds. An IP ban affects all clients sharing that public NAT address.

Inspect the jail without displaying credentials:

```bash
sudo fail2ban-client status familytraffic-proxy-auth
```

Use controlled clients in an isolated test environment for failure-to-ban tests. Do not trigger a ban from the active administrative source on a shared host.
