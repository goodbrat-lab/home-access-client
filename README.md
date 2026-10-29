# Secure Remote Access Client Bundle (v1.0.1)

Клиентский пакет для защищённого удалённого доступа к домашней инфраструктуре из корпоративной сети через корпоративный HTTP-прокси (`10.26.254.42:3128`) с маскировкой под HTTPS/WebSocket (`wstunnel`) и туннелированием WireGuard.

[![Release](https://img.shields.io/github/v/release/goodbrat-lab/home-access-client)](https://github.com/goodbrat-lab/home-access-client/releases/tag/v1.0.1)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## 1. Содержимое пакета

* `install.ps1` — автоматизированный скрипт установки (загрузка зависимостей, расшифровка конфига без BOM, настройка прав ACL по SID, установка WireGuard, запуск и проверка туннеля).
* `start-wstunnel.bat` — скрипт ручного запуска wstunnel-клиента через корпоративный прокси.
* `wstunnel.exe` — бинарный файл wstunnel v11.1.0 (`windows_amd64`).
* `config.enc` — зашифрованный файл конфигурации WireGuard (`AES-256-CBC` + `HMAC-SHA256` Encrypt-then-MAC, KDF PBKDF2-HMAC-SHA256 100 000 итераций).
* `config.sha256` — контрольная сумма SHA-256 для проверки целостности `config.enc`.

---

## 2. Быстрая установка на рабочем ПК (в один клик)

Откройте **PowerShell от имени администратора** и выполните:

```powershell
$env:WG_PASS = "ВАШ_ПАРОЛЬ_ШИФРОВАНИЯ"
Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/goodbrat-lab/home-access-client/main/install.ps1" -Proxy "http://10.26.254.42:3128" -UseBasicParsing).Content
```

Пароль шифрования считывается из переменной окружения `$env:WG_PASS` и сразу удаляется из памяти после расшифровки.

---

## 3. Требования к серверной части (домашний сервер)

Для корректной работы туннеля серверная сторона на мини-ПК и роутере должна быть настроена следующим образом:

1. **wstunnel-server:**  
   Служба должна запускаться с явным указанием обоих вариантов loopback в `--restrict-to`:
   ```bash
   wstunnel server \
     --tls-certificate /etc/wstunnel/tls/fullchain.pem \
     --tls-private-key /etc/wstunnel/tls/privkey.pem \
     --restrict-to localhost:51820 \
     --restrict-to 127.0.0.1:51820 \
     --log-lvl INFO "wss://[::]:443"
   ```
   > [!IMPORTANT]
   > Обязательно указывать и `localhost:51820`, и `127.0.0.1:51820`. Если указан только `127.0.0.1`, а клиент запрашивает `localhost`, wstunnel отклонит соединение с ошибкой `400 Bad Request` (`Rejecting connection with not allowed destination`).

2. **Маршрутизация и NAT ядра Linux (мини-ПК):**
   * Включён IP-форвардинг: `net.ipv4.ip_forward = 1`
   * Настроен мягкий режим Reverse Path Filtering: `net.ipv4.conf.wg0.rp_filter = 2` и `net.ipv4.conf.all.rp_filter = 0` / `2`
   * В `iptables` разрешён форвардинг в обе стороны:
     ```bash
     iptables -A FORWARD -i wg0 -j ACCEPT
     iptables -A FORWARD -o wg0 -j ACCEPT
     ```
   * Включён NAT (MASQUERADE) в сторону домашней локальной сети:
     ```bash
     iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o enp2s0 -j MASQUERADE
     ```

3. **Роутер (OpenWrt):**
   * Настроен проброс входящего порта `443/tcp` с WAN-интерфейса на LAN IP мини-ПК (`192.168.1.229:443`).

4. **TLS-сертификат:**
   * Действующий доверенный сертификат Let's Encrypt для домена `home.guseynovia.ru` (выпущенный через DNS-01 challenge).

---

## 4. Обоснование MTU = 1280

В конфигурации клиента по умолчанию установлен **`MTU = 1280`**.

Причина: многоуровневая инкапсуляция пакетов:
$$\text{WireGuard (IP/UDP)} \longrightarrow \text{WebSocket binary frame} \longrightarrow \text{TLS 1.3} \longrightarrow \text{TCP (HTTP CONNECT)} \longrightarrow \text{Корпоративный прокси}$$

При стандартном MTU 1380–1420 служебные заголовки вызывают превышение максимального размера сегмента (MSS), из-за чего рукопожатие (Handshake) WireGuard проходит успешно (пакеты рукопожатия маленькие), но любые реальные данные (TCP-потоки, сессии SSH, ICMP) фрагментируются и отбрасываются корпоративным прокси. Значение `MTU = 1280` гарантирует прохождение трафика через любой прокси и туннель без фрагментации.

---

## 5. Проверка после установки

После завершения установки выполните проверку доступности:

1. **Проверка WireGuard-интерфейса сервера:**
   ```cmd
   ping -n 4 10.10.10.1
   ```
   *(0% потерь. Если пинг блокируется брандмауэром Windows, ориентируйтесь на SSH).*
2. **Проверка SSH к мини-ПК через VPN-адрес:**
   ```cmd
   ssh brat@10.10.10.1
   ```
   *(Успешный вход подтверждает работу туннеля).*
3. **Проверка доступа к веб-интерфейсу роутера OpenWrt (через туннель):**
   ```cmd
   curl -I http://192.168.1.1/
   ```
   *(Ответ: HTTP/1.1 200 OK — подтверждает маршрутизацию в домашнюю LAN).*
4. **Проверка SSH через домашний LAN-адрес мини-ПК:**
   ```cmd
   ssh brat@192.168.1.229
   ```
   *(Подтверждает корректную работу MASQUERADE на стороне сервера).*

---

## 6. Диагностика и устранение проблем

* **`400 Bad Request` от wstunnel-сервера:**
  Несовпадение параметров `--restrict-to` на сервере. Убедитесь, что в сервисе на мини-ПК прописаны оба значения: `--restrict-to localhost:51820` и `--restrict-to 127.0.0.1:51820`.
* **Ошибка WireGuard: `Строка должна быть в секции: "\ufeff[Interface]"`:**
  Файл конфигурации записан с маркером UTF-8 BOM. Скрипт `install.ps1` (v1.0.1) гарантирует запись без BOM через `(New-Object System.Text.UTF8Encoding($false))`.
* **`Access is denied` в логе службы WireGuard:**
  Служба туннеля работает под учетной записью `NT AUTHORITY\SYSTEM` (`S-1-5-18`). Файлу `.conf` требуются права для SYSTEM. В v1.0.1 права назначаются через SID: `*S-1-5-18:(R)` и `*S-1-5-32-544:(F)` (для совместимости с русскоязычными версиями Windows).
* **`certificate verify failed` в wstunnel:**
  Корпоративный прокси производит SSL-инспекцию. Обратите внимание: в wstunnel v11.1.0 проверка валидности сертификатов по умолчанию **отключена**; флаг `--tls-verify-certificate` без аргументов её **включает** — не используйте его в корпоративных сетях.
* **Handshake проходит (`latest handshake` обновляется в `wg show`), но ping и SSH не идут:**
  Уменьшите MTU до `1280` в конфигурации WireGuard. Также убедитесь, что в GUI WireGuard не включён блокирующий переключатель `Block untunneled traffic (kill-switch)`.
* **`Permission denied (publickey,password)` при SSH:**
  Туннель и сеть работают исправно. Проблема на уровне аутентификации sshd (неверный пароль или отсутствие открытого ключа в `~/.ssh/authorized_keys` на сервере).
* **`Ping 10.10.10.1` выдаёт 100% потерь, но SSH работает:**
  Брандмауэр Windows Defender присвоил адаптеру WireGuard профиль «Общедоступная сеть» (Public) и отбрасывает входящие ICMP Echo Reply. Для включения пинга выполните:
  ```powershell
  Set-NetConnectionProfile -InterfaceAlias "wireguard-client" -NetworkCategory Private
  ```

---

## 7. Повседневное использование

* **Ручной запуск:**
  1. Запустите `start-wstunnel.bat` (окно не закрывать).
  2. В GUI WireGuard нажмите **Activate** для туннеля `wireguard-client`.
* **Остановка:**
  1. В GUI WireGuard нажмите **Deactivate**.
  2. Закройте окно wstunnel либо выполните: `taskkill /IM wstunnel.exe /F`.
* **Проверка состояния:**
  ```cmd
  "C:\Program Files\WireGuard\wg.exe" show
  ```

---

## 8. Автозапуск wstunnel через Планировщик задач Windows

Чтобы туннель wstunnel автоматически стартовал при входе пользователя в систему (поскольку служба WireGuard стартует автоматически как служба Windows `WireGuardTunnel$wireguard-client`), выполните в **PowerShell от имени администратора**:

```powershell
$action = New-ScheduledTaskAction -Execute "$env:USERPROFILE\wstunnel\wstunnel.exe" -Argument 'client --log-lvl INFO -L "udp://0.0.0.0:51820:localhost:51820?timeout_sec=0" -p http://10.26.254.42:3128 wss://home.guseynovia.ru:443'
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
Register-ScheduledTask -TaskName "wstunnel-client" -Action $action -Trigger $trigger -Principal $principal -Description "wstunnel client for home access"
```

### Удаление автозапуска:
```powershell
Unregister-ScheduledTask -TaskName "wstunnel-client" -Confirm:$false
```
