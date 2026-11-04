# Миграция пользователей при переустановке

**familyTraffic v5.33** · [← GUIDES](GUIDES.md) · [← README](../README.md)

---

## Содержание

1. [Контекст и совместимость](#1-контекст-и-совместимость)
2. [Шаг 1 — Резервное копирование](#2-шаг-1--резервное-копирование)
3. [Шаг 2 — Переустановка](#3-шаг-2--переустановка)
4. [Шаг 3 — Восстановление данных](#4-шаг-3--восстановление-данных)
5. [Шаг 4 — Применение конфига](#5-шаг-4--применение-конфига)
6. [Шаг 5 — Верификация](#6-шаг-5--верификация)
7. [Что не нужно восстанавливать](#7-что-не-нужно-восстанавливать)
8. [Схема users.json](#8-схема-usersjson)

---

## 1. Контекст и совместимость

| | Master (старый) | Test / новая версия |
|---|---|---|
| Архитектура | Multi-container (`vless_xray`, `vless_nginx`, …) | Single-container `familytraffic` |
| Install dir | `/opt/vless/` | `/opt/familytraffic/` |
| CLI | `vless`, `vless-external-proxy`, `mtproxy` | `familytraffic`, `familytraffic-external-proxy`, `familytraffic-mtproxy` |
| users.json | `/opt/vless/data/users.json` | `/opt/familytraffic/data/users.json` |

**Схема `users.json` одинакова в обеих версиях** — миграция данных не требуется, достаточно подстановки файлов.

`UUID` и `shortId` каждого пользователя сохраняются, поэтому клиентские конфиги после переустановки менять не нужно — **при условии, что Reality ключи (`keys/`) тоже перенесены**. Если ключи не сохранить, при установке генерируются новые, `pbk` в клиентских ссылках становится недействительным, и VPN перестаёт работать у всех пользователей.

Переименование `/opt/vless` → `/opt/familytraffic` автоматически выполняется `install.sh` через `lib/migrate_rename.sh`.

---

## 2. Шаг 1 — Резервное копирование

Выполнить **до** запуска переустановки:

```bash
BACKUP_TS=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/opt/familytraffic_migration_backup_${BACKUP_TS}"
sudo mkdir -p "${BACKUP_DIR}"

# 1. Пользователи (критично)
sudo cp /opt/familytraffic/data/users.json "${BACKUP_DIR}/users.json"

# 2. xray_config (содержит UUID и shortIds клиентов)
sudo cp /opt/familytraffic/config/xray_config.json "${BACKUP_DIR}/xray_config.json"

# 3. .env (domain, keys, server IP, image tag)
sudo cp /opt/familytraffic/.env "${BACKUP_DIR}/.env"

# 4. MTProxy секреты и конфиг
sudo cp -r /opt/familytraffic/config/mtproxy/ "${BACKUP_DIR}/mtproxy/"

# 5. Per-user proxy assignments
sudo cp /opt/familytraffic/config/external_proxy.json "${BACKUP_DIR}/external_proxy.json" 2>/dev/null || true

# 6. Reality ключи (КРИТИЧНО — без них pbk в клиентских ссылках станет недействительным)
sudo cp -r /opt/familytraffic/keys/ "${BACKUP_DIR}/keys/"

# 7. Клиентские конфиги
sudo cp -r /opt/familytraffic/data/clients/ "${BACKUP_DIR}/clients/"

# 8. Let's Encrypt сертификаты
sudo cp -r /etc/letsencrypt/ "${BACKUP_DIR}/letsencrypt/"

echo "Backup: ${BACKUP_DIR}"
sudo ls -la "${BACKUP_DIR}"
```

Проверить перед продолжением:

```bash
sudo jq '.users | length' "${BACKUP_DIR}/users.json"   # ожидаемое кол-во пользователей
sudo jq -r '.users[].username' "${BACKUP_DIR}/users.json"
```

---

## 3. Шаг 2 — Переустановка

```bash
cd /path/to/familytraffic-repo
sudo ./install.sh
```

При обнаружении существующей установки выбрать **"Cleanup without backup"** — backup уже сделан на предыдущем шаге.

---

## 4. Шаг 3 — Восстановление данных

После завершения установки:

```bash
# Подставить свой timestamp
BACKUP_DIR="/opt/familytraffic_migration_backup_<TS>"

# 1. users.json
sudo cp "${BACKUP_DIR}/users.json" /opt/familytraffic/data/users.json
sudo chmod 600 /opt/familytraffic/data/users.json
sudo chown root:root /opt/familytraffic/data/users.json

# 2. xray_config (клиенты + shortIds)
sudo cp "${BACKUP_DIR}/xray_config.json" /opt/familytraffic/config/xray_config.json

# 3. MTProxy секреты и конфиг
sudo cp -r "${BACKUP_DIR}/mtproxy/" /opt/familytraffic/config/mtproxy/

# 4. Reality ключи (КРИТИЧНО — восстановить до перезапуска контейнера)
sudo cp -r "${BACKUP_DIR}/keys/" /opt/familytraffic/keys/
sudo chmod 600 /opt/familytraffic/keys/private.key
sudo chmod 644 /opt/familytraffic/keys/public.key

# 5. Per-user proxy assignments
sudo cp "${BACKUP_DIR}/external_proxy.json" /opt/familytraffic/config/external_proxy.json 2>/dev/null || true

# 6. Клиентские конфиги
sudo cp -r "${BACKUP_DIR}/clients/" /opt/familytraffic/data/clients/

# 7. Сертификаты (только если не сохранились)
ls /etc/letsencrypt/live/   # проверить наличие
# Если пусто:
sudo rsync -av "${BACKUP_DIR}/letsencrypt/" /etc/letsencrypt/
```

---

## 5. Шаг 4 — Применение конфига

xray применяет `users.json` по `SIGHUP` без разрыва соединений:

```bash
sudo docker kill --signal=SIGHUP familytraffic
```

---

## 6. Шаг 5 — Верификация

```bash
# Список пользователей
sudo familytraffic list-users

# MTProxy
sudo familytraffic-mtproxy status
sudo familytraffic-mtproxy list-secrets

# Внешние прокси
sudo familytraffic-external-proxy list

# Логи контейнера
sudo docker logs familytraffic --tail=50
```

---

## 7. Что не нужно восстанавливать

| Файл | Причина |
|---|---|
| `nginx.conf` | Генерируется установщиком заново по `.env` |
| `supervisord.conf` | Часть Docker-образа |
| `docker-compose.yml` | Копируется из репозитория установщиком (`create_docker_compose`) |
| UFW-правила | Настраиваются установщиком при install |

> **Важно:** `keys/private.key` и `keys/public.key` — **обязательно восстанавливать**. Без них установщик генерирует новую пару ключей, `pbk` в клиентских VLESS-ссылках становится недействительным, и VPN перестаёт работать у всех пользователей без перевыпуска конфигов.

---

## 8. Схема users.json

Поля, критичные для сохранения:

```json
{
  "users": [
    {
      "username": "alice",
      "uuid": "...",               // идентификатор в xray — менять нельзя
      "shortId": "...",            // Reality shortId — менять нельзя
      "proxy_password": "...",     // пароль SOCKS5/HTTP прокси
      "fingerprint": "safari",
      "external_proxy_id": null,   // привязка к внешнему прокси
      "connection_type": "both",   // vpn | proxy | both
      "mtproxy_secret": null,
      "mtproxy_secret_type": null,
      "mtproxy_domain": null,
      "created": "...",
      "created_timestamp": ...
    }
  ],
  "metadata": {
    "created": "...",
    "last_modified": "..."
  }
}
```

UUID и shortId не меняются между версиями — клиентские конфиги остаются действительными после переустановки.

## Coordinated proxy security migration

The authentication-journal image and PROXY-protocol receiver configuration must be deployed together. An ordinary image replacement is insufficient to reconcile host UFW and fail2ban state. Build images in CI, then pull the reviewed artifact before migration. Never build application images on the server.

After reviewing the rollout, use the local immutable image identity:

```bash
docker image ls --no-trunc --digests
read -r -p "Verified local image ID: " image_id
sudo familytraffic-security reconcile --image "$image_id"
sudo familytraffic-security check
```

The reconciliation entry point requires the image capability marker, valid staged configuration, nonempty authenticated accounts, and recognizable managed policy. It preserves user credentials, routes, transport choices, certificates, and volumes. Keep its restricted backup until acceptance checks pass.

On partial failure, restore the previous compatible image/configuration pair and managed host policy. The migration reports failure even after rollback. Older protection may be ineffective; a successful rollback must not be reported as protected deployment success.

Public listeners must never accept client-supplied PROXY metadata. Only loopback Xray receivers accept source metadata from nginx. Direct internal clients must use nginx entry points after this migration.

A first public-proxy installation provisions its initial user before activation. Set `FT_INITIAL_PROXY_USERNAME` for unattended setup, or answer the interactive username prompt. The installer generates credentials and stores them with restrictive permissions. It does not print the password. Retrieve the client configuration through the existing `familytraffic show-user USER` command in a trusted terminal. A missing or invalid username must leave services stopped. Do not remove the authentication guard to complete installation.
