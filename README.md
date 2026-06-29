# familyTraffic VPN Server

**v5.33** · Production Ready · MIT License

VLESS + Reality — самодостаточный VPN-сервер с защитой от DPI. Трафик маскируется под TLS 1.3 к легитимному сайту (Google, Cloudflare) и статистически неотличим от обычного HTTPS.

**Возможности:**
- VLESS Reality с XTLS Vision (Tier 1) — основной транспорт, обход DPI
- WebSocket / XHTTP / gRPC (Tier 2) — альтернативные транспорты через CDN
- SOCKS5 + HTTP прокси с TLS — доступ без VPN-клиента
- MTProxy (mtg v2, Fake TLS) — встроенный Telegram-прокси, порт 2053
- Per-user external proxy — индивидуальные цепочки прокси для пользователей
- Let's Encrypt — автоматическое обновление сертификатов

---

## Архитектура

```
Client
  │
  ├─ TCP:443  ──► familytraffic (ssl_preread SNI)
  │                  ├─ Reality clients   ──► 127.0.0.1:8443  (VLESS Reality)
  │                  └─ Tier 2 subdomains ──► port 8448 (http block)
  │                                             ├─► 127.0.0.1:8444 (WebSocket)
  │                                             ├─► 127.0.0.1:8445 (XHTTP)
  │                                             └─► 127.0.0.1:8446 (gRPC)
  │
  ├─ TCP:1080 ──► familytraffic (TLS termination) ──► 127.0.0.1:10800 (SOCKS5)
  ├─ TCP:8118 ──► familytraffic (TLS termination) ──► 127.0.0.1:18118 (HTTP proxy)
  ├─ TCP:1081 ──► familytraffic (no TLS, plaintext) ─► 127.0.0.1:10800 (SOCKS5)     [opt: enable_notls]
  ├─ TCP:8119 ──► familytraffic (no TLS, plaintext) ─► 127.0.0.1:18118 (HTTP proxy) [opt: enable_notls]
  │
  ├─ TCP:2053 ──► familytraffic / mtg v2 (Fake TLS) ──► Telegram DCs  [MTProxy]
  └─ TCP:4443 ──► familytraffic / nginx (LE-cert, cloak) ──► реальный HTTPS [active probing protection]
```

**Контейнер:** `familytraffic` — единый, supervisord управляет процессами:

| Процесс | Приоритет | Описание |
|---|---|---|
| xray | 1 | VLESS Reality, Tier 2, SOCKS5, HTTP proxy |
| nginx | 2 | SNI routing (443), TLS termination, cloak-port (4443) |
| certbot-cron | 3 | Авторенew Let's Encrypt каждые 12 часов |
| mtg | 4 | MTProxy (Fake TLS, порт 2053) — `autostart=true` если включён при установке или `mtproxy setup` |

---

## Требования

| | Минимум | Рекомендовано |
|---|---|---|
| ОС | Ubuntu 20.04, Debian 10 | Ubuntu 22.04 LTS |
| CPU | 1 vCPU | 2 vCPU |
| RAM | 1 GB | 2 GB |
| Диск | 10 GB | 20 GB |

**Обязательно:** публичный IP-адрес, Docker, домен (для TLS-прокси и Tier 2).

---

## Установка

```bash
git clone <repo-url>
cd familytraffic
sudo ./install.sh
```

Установщик интерактивно запросит домен, email, параметры Reality и настроит всё автоматически.

**Детальная инструкция:** [docs/GUIDES.md](docs/GUIDES.md)

---

## Команды

### Пользователи

```
sudo familytraffic add-user <name>          Создать пользователя (выводит QR + URI)
sudo familytraffic remove-user <name>       Удалить пользователя
sudo familytraffic list-users               Список всех пользователей
sudo familytraffic show-user <name>         Показать конфигурацию и QR код
sudo familytraffic regenerate <name>        Перегенерировать клиентские файлы (URI, QR, proxy-конфиги)
```

### Tier 2 транспорты

```
sudo familytraffic add-transport <type> <subdomain>    Включить транспорт (ws|xhttp|grpc)
sudo familytraffic list-transports                     Список активных транспортов
sudo familytraffic remove-transport <type>             Отключить транспорт
```

### Per-user external proxy

```
sudo familytraffic set-proxy <user> <proxy-id|none>   Назначить proxy пользователю
sudo familytraffic show-proxy <user>                  Показать назначение
sudo familytraffic list-proxy-assignments             Список всех назначений
```

### External proxy (server-level)

```
sudo familytraffic-external-proxy add                 Добавить upstream proxy
sudo familytraffic-external-proxy list                Список proxies
sudo familytraffic-external-proxy status              Статус + пользователи по proxies
```

### Сервис

```
sudo familytraffic status                             Статус контейнера
sudo familytraffic logs [xray|nginx|all]              Логи
sudo familytraffic restart                            Перезапуск
sudo familytraffic test-security [--quick]            Тесты безопасности
```

### MTProxy (Telegram proxy)

Встроенный Telegram-прокси на базе [mtg v2](https://github.com/9seconds/mtg) (Fake TLS).
Можно включить при установке (`install.sh` задаёт вопрос) или позже командой `familytraffic-mtproxy setup`. При включении создаётся `config/supervisord.d/mtg.conf` с `autostart=true` — mtg стартует автоматически при перезапуске контейнера.

**Защита от active probing:** nginx на порту 4443 обслуживает легитимный HTTPS с LE-сертификатом — сканеры видят обычный сайт, а не прокси.

#### Первый запуск

```
sudo familytraffic-mtproxy setup                                    Настроить и включить MTProxy (Fake TLS)
sudo familytraffic-mtproxy setup --fake-domain www.google.com       С явным fake-TLS доменом для маскировки
```

> **`--fake-domain`** — это домен для маскировки трафика, а не домен вашего сервера. mtg притворяется, что устанавливает TLS-соединение с указанным сайтом. Лучше указывать популярный HTTPS-сайт, доступный без ограничений (`www.google.com`, `telegram.org`). Если не указан — используется домен сертификата сервера.

```
sudo familytraffic-mtproxy add-secret --fake-domain www.google.com  Добавить ee-секрет с fake-TLS доменом
sudo familytraffic-mtproxy list-secrets                             Список секретов
sudo familytraffic-mtproxy remove-secret <SECRET>                   Удалить секрет
```

#### Управление

```
sudo familytraffic-mtproxy status                            Статус (supervisorctl status mtg)
sudo familytraffic-mtproxy start                             Запустить mtg
sudo familytraffic-mtproxy stop                              Остановить mtg
sudo familytraffic-mtproxy restart                           Перезапустить mtg
sudo familytraffic-mtproxy logs [--tail N] [--follow]        Логи mtg
sudo familytraffic-mtproxy disable                           Отключить MTProxy + закрыть UFW + убрать nginx
```

#### Конфигурация клиента

В текущей реализации все пользователи используют **один общий секрет**. Ссылка для подключения показывается при `add-secret` или в `list-secrets`:

```
sudo familytraffic-mtproxy list-secrets                      Список секретов (type/secret/domain)
```

Ссылка формата: `tg://proxy?server=<IP>&port=2053&secret=<SECRET>`

---

## Клиентские приложения

### Android

| Приложение | Особенности |
|---|---|
| [v2rayNG](https://github.com/2dust/v2rayNG) | Классический клиент, VLESS Reality, импорт по ссылке/QR |
| [Hiddify](https://github.com/hiddify/hiddify-app) | Простой GUI, все транспорты, рекомендуется |

### iOS

| Приложение | Особенности |
|---|---|
| [Hiddify](https://github.com/hiddify/hiddify-app) | Простой GUI, все транспорты, рекомендуется |
| Shadowrocket | Платное, широкая поддержка протоколов |
| Streisand | Бесплатное, VLESS Reality |

### Windows

| Приложение | Особенности |
|---|---|
| [Hiddify](https://github.com/hiddify/hiddify-app) | Простой GUI, VLESS Reality + все транспорты, **рекомендуется** |
| [v2rayN](https://github.com/2dust/v2rayN) | Классический клиент, гибкая настройка |
| [Nekoray / NekoBox](https://github.com/MatsuriDayo/nekoray) | Современный GUI, тонкая настройка маршрутизации |
| [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) | Если нужен системный HTTP/SOCKS5 прокси с правилами |

### macOS

| Приложение | Особенности |
|---|---|
| [Hiddify](https://github.com/hiddify/hiddify-app) | Простой GUI, все транспорты, рекомендуется |
| [v2rayA](https://v2raya.org) | Web-интерфейс, гибкая маршрутизация |

### Linux

| Приложение | Особенности |
|---|---|
| [v2rayA](https://v2raya.org) | Web-интерфейс, системный прокси, гибкая маршрутизация |
| [Hiddify](https://github.com/hiddify/hiddify-app) | GUI, все транспорты |

> **Подключение:** Ссылку `vless://...` или QR-код пользователя можно получить командой:
> ```bash
> sudo familytraffic show-user <name>
> ```

---

## Документация

- **[docs/GUIDES.md](docs/GUIDES.md)** — полная пошаговая инструкция
- [docs/MIGRATION.md](docs/MIGRATION.md) — миграция со старых версий
- [docs/SECURITY.md](docs/SECURITY.md) — модель безопасности
- [CLAUDE.md](CLAUDE.md) — техническая документация для разработчиков

### Wiki (`docs/wiki/`)

Гранулярная техническая вики по подсистемам (semantic-индекс для `iwiki`):

| Страница | Тема |
|---|---|
| [architecture](docs/wiki/architecture.md) | Single-container design, supervisord, traffic flow |
| [installation](docs/wiki/installation.md) | `install.sh`, OS detection, миграция |
| [cli-tools](docs/wiki/cli-tools.md) | CLI: `familytraffic*` команды |
| [user-management](docs/wiki/user-management.md) | VLESS-пользователи, UUID, QR/URI |
| [transports](docs/wiki/transports.md) | Reality (Tier 1), ws/xhttp/grpc (Tier 2), SNI routing |
| [mtproxy](docs/wiki/mtproxy.md) | MTProxy (mtg v2), ee-секреты, `mtg.toml` |
| [proxy-chains](docs/wiki/proxy-chains.md) | Per-user upstream proxy, whitelist |
| [certificates](docs/wiki/certificates.md) | Let's Encrypt, certbot, автообновление |
| [security](docs/wiki/security.md) | Hardening, fail2ban, UFW |
| [services](docs/wiki/services.md) | Orchestrator, service ops, контейнер |
| [docker](docs/wiki/docker.md) | 3-stage build, supervisord, CI/CD |
| [testing](docs/wiki/testing.md) | BATS unit/integration/performance тесты |
