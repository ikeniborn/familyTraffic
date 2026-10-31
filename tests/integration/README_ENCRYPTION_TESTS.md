# Тесты Безопасности Шифрования / Encryption Security Tests

## Quick Start (Быстрый Старт)

### ✅ Рекомендуемый способ: CLI команда (после установки VLESS)

```bash
# Полный набор тестов / Full test suite (2-3 min)
sudo vless test-security

# Быстрый режим / Quick mode (1 min)
sudo vless test-security --quick

# С подробным выводом / Verbose output
sudo vless test-security --verbose
```

**Алиасы / Aliases:** `test-security`, `security-test`, `security`

---

### Альтернативный способ: Прямой запуск модуля

```bash
# Установка зависимостей / Install dependencies
sudo apt-get update
sudo apt-get install -y openssl curl jq iproute2 iptables nmap tcpdump

# Запуск модуля / Run module directly
sudo /opt/familytraffic/lib/security_tests.sh

# Или из development-репозитория:
cd ~/Documents/Project/vless
sudo lib/security_tests.sh --quick
```

## Что тестируется / What is tested

✅ **Reality Protocol TLS 1.3** - X25519 keys, masquerading, SNI
✅ **stunnel TLS Termination** - SOCKS5/HTTP over TLS (public proxy mode)
✅ **Traffic Encryption** - Packet capture, plaintext detection
✅ **Certificate Security** - Let's Encrypt, expiration, permissions
✅ **DPI Resistance** - Deep Packet Inspection evasion
✅ **SSL/TLS Vulnerabilities** - Weak ciphers, obsolete protocols
✅ **Proxy Security** - Authentication, password strength, binding
✅ **Data Leaks** - Config file exposure, log analysis

## Результаты / Results

| Exit Code | Значение / Meaning |
|-----------|-------------------|
| `0` | ✅ Успех / Success |
| `1` | ❌ Провал / Failed |
| `2` | ⚠️ Ошибка предварительных требований / Prerequisites error |
| `3` | 🔥 Критические уязвимости / Critical vulnerabilities |

## Документация / Documentation

- **Полное руководство (RU):** [../../docs/SECURITY_TESTING_RU.md](../../docs/SECURITY_TESTING_RU.md)
- **Full guide (EN):** [../../docs/SECURITY_TESTING.md](../../docs/SECURITY_TESTING.md)
- **Project docs:** [../../docs/CLAUDE.md](../../docs/CLAUDE.md)

## Помощь / Help

```bash
./test_encryption_security.sh --help
```

## Типичные проблемы / Common issues

**tcpdump not found:**
```bash
sudo apt-get install tcpdump
# or use: ./test_encryption_security.sh --skip-pcap
```

**Containers not running:**
```bash
cd /opt/familytraffic && sudo docker compose up -d
```

**No users configured:**
```bash
sudo vless-user add testuser
```

**Certificate expired:**
```bash
sudo certbot renew
cd /opt/familytraffic && sudo docker compose restart
```

---

**Version:** 1.0
**Date:** 2025-10-07

## Isolated proxy security acceptance

The security lab uses a prebuilt local application image, a disposable Debian UFW/fail2ban node, and three separate client addresses. All services use an internal Docker bridge. Only the node receives `NET_ADMIN`; its network namespace contains the tested firewall. The lab publishes no host ports and mounts no Docker socket.

```bash
bash tests/security_lab/run.sh --image familytraffic:proxy-security
```

The harness tests authenticated HTTP, HTTPS, SOCKS5, TLS-SOCKS, and VLESS Reality against a controlled TLS target. Certificate verification stays enabled. It checks connection bursts, credential classification, address/log spoofing, aggregate bans, another client's access, address changes, unban/expiry, rotation, jail restart, and UFW reload. The migration unit suite supplies synthetic image-mismatch and rollback faults.

The lab selects an unused `/24` within the benchmarking range `198.18.0.0/15`. It checks existing Docker networks and host routes before creating its private bridge. A missing network capability or dependency fails the run. Cleanup targets only the unique Compose project and its node image. It never prunes shared Docker resources.

Redacted output, application image ID, source SHA256 fingerprints, and firewall snapshots remain in `tests/security_lab/artifacts/<unique-project>/`. CI uploads that directory even on failure. Fixture certificates and credentials exist only in the temporary lab directory and are deleted during cleanup.

For focused diagnostics, select one unittest case through `FT_LAB_TEST`:

```bash
FT_LAB_TEST=ProxySecurityTests.test_07_firewall_reload_preserves_ban bash tests/security_lab/run.sh --image familytraffic:proxy-security
```

A focused pass is not evidence that the complete security matrix passed. Run the complete harness after its relevant inputs stabilize.
