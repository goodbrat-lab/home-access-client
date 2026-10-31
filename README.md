# Secure Remote Access Client Bundle (v1.0.3)

Клиентский пакет для защищённого удалённого доступа к домашней инфраструктуре из корпоративной сети через корпоративный HTTP-прокси (`10.26.254.42:3128`) с маскировкой под HTTPS/WebSocket (`wstunnel`) и туннелированием WireGuard.

[![Release](https://img.shields.io/github/v/release/goodbrat-lab/home-access-client)](https://github.com/goodbrat-lab/home-access-client/releases/tag/v1.0.3)
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

> **Примечание к релизу v1.0.3 (Ротация ключей):**  
> В версии **v1.0.3** проведена плановая ротация ключей WireGuard для рабочего ПК (`PrivateKey`, `PublicKey`, `PresharedKey`). Файл `config.enc` перевыпущен и зашифрован новым мастер-паролем, а контрольная сумма `config.sha256` обновлена. Предыдущие пароли дешифрования больше не действуют.

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

## 5. Маршрутизация Full-Tunnel и исключение корпоративной сети (10.0.0.0/8)

В релизе **v1.0.2** клиент WireGuard настроен в режиме **Full-Tunnel**: весь внешний интернет-трафик рабочего ПК маршрутизируется через домашнюю сеть и далее в VPN-инфраструктуру OpenWrt (`sirin-client` Нидерланды и `sing-box` TPROXY).

### Обоснование разбиения AllowedIPs
В синтаксисе WireGuard для Windows отсутствует оператор исключения (отрицания `!`). Запись вида `AllowedIPs = 0.0.0.0/0, !10.0.0.0/8` не поддерживается драйвером `wireguard.exe` и вызывает фатальную ошибку конфигурации.

Чтобы направить **весь интернет в туннель**, но гарантировать, что корпоративный трафик (включая прокси-сервер `10.26.254.42`) пойдёт напрямую через физическую сеть офиса, адресное пространство `0.0.0.0/0` математически разбито на смежные подсети без диапазона `10.0.0.0/8`:

```ini
AllowedIPs = 0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/1, 10.10.10.0/24
```

| CIDR-блок | Диапазон адресов | Назначение / Примечание |
| :--- | :--- | :--- |
| `0.0.0.0/5` | `0.0.0.0` – `7.255.255.255` | В интернет через туннель |
| `8.0.0.0/7` | `8.0.0.0` – `9.255.255.255` | В интернет через туннель (DNS 8.8.8.8) |
| — | `10.0.0.0` – `10.255.255.255` | **ИСКЛЮЧЕНО** (корпоративная сеть и прокси `10.26.254.42` напрямую) |
| `11.0.0.0/8` | `11.0.0.0` – `11.255.255.255` | В интернет через туннель |
| `12.0.0.0/6` | `12.0.0.0` – `15.255.255.255` | В интернет через туннель |
| `16.0.0.0/4` | `16.0.0.0` – `31.255.255.255` | В интернет через туннель |
| `32.0.0.0/3` | `32.0.0.0` – `63.255.255.255` | В интернет через туннель |
| `64.0.0.0/2` | `64.0.0.0` – `127.255.255.255` | В интернет через туннель |
| `128.0.0.0/1` | `128.0.0.0` – `255.255.255.255` | В интернет (включая домашнюю LAN `192.168.1.0/24` и DNS `1.1.1.1`) |
| `10.10.10.0/24` | `10.10.10.0` – `10.10.10.255` | **Явное включение** подсети WireGuard-сервера с маской `/24` |

### 5.1. Настройка ProxyOverride для браузеров (Chrome, Edge)
По умолчанию Windows и браузеры на базе Chromium перенаправляют все HTTP/HTTPS-запросы на системный корпоративный прокси (`10.26.254.42:3128`), игнорируя системные маршруты WireGuard. Поскольку корпоративный прокси не знает о домашних адресах (`192.168.1.*`, `10.10.10.*`) и блокирует YouTube, трафик к ним должен идти в обход прокси — напрямую через интерфейс WireGuard.

Начиная с **v1.0.2**, скрипт `install.ps1` автоматически конфигурирует исключения в реестре Windows с сохранением резервной копии исходного значения в `$env:USERPROFILE\wstunnel\proxy-override-backup.txt`:

* **Ручная настройка исключений в PowerShell:**
  ```powershell
  $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
  $currentOverride = (Get-ItemProperty -Path $regKey).ProxyOverride
  $add = "192.168.1.*;10.10.10.*;*.youtube.com;*.googlevideo.com;*.ytimg.com"
  $newOverride = if ([string]::IsNullOrWhiteSpace($currentOverride)) { $add } else { "$currentOverride;$add" }
  Set-ItemProperty -Path $regKey -Name ProxyOverride -Value $newOverride
  ```

* **Откат ProxyOverride к исходному состоянию (до установки):**
  ```powershell
  $backupPath = "$env:USERPROFILE\wstunnel\proxy-override-backup.txt"
  if (Test-Path $backupPath) {
      $original = Get-Content $backupPath -Raw
      Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyOverride -Value $original
      Write-Host "ProxyOverride восстановлен из бэкапа." -ForegroundColor Green
  }
  ```

### 5.2. Настройки браузера: YouTube, FakeIP и отключение QUIC
1. **Отключение протокола QUIC (HTTP/3):**
   * Браузеры по умолчанию пытаются открывать YouTube и сервисы Google по протоколу QUIC поверх UDP/443. В корпоративных сетях исходящий UDP/443 часто фильтруется или дропается прокси/файрволом, что приводит к долгой буферизации или ошибке загрузки видео.
   * **Решение:** Откройте в Chrome / Edge страницу `chrome://flags/#enable-quic`, переведите флаг **Experimental QUIC protocol** в положение **Disabled** и перезапустите браузер (кнопка *Relaunch*). Браузер переключится на TCP TLS (HTTP/2), который прозрачно обрабатывается TPROXY `sing-box` на домашнем роутере.
2. **Разрешение доступа к локальной сети (Chrome 142+):**
   * В последних версиях Chromium включена защита *Private Network Access (Local Network Access)*. При первом открытии веб-интерфейса домашнего роутера (`http://192.168.1.1/`) браузер может запросить явное подтверждение доступа во всплывающем окне — нажмите **Allow** (Разрешить).

---

## 6. Проверка после установки

После завершения установки выполните проверку доступности:

### Таблица верификации маршрутизации

| Тест / Команда | Ожидаемый результат | Что проверяется |
| :--- | :--- | :--- |
| `ping -n 2 10.26.254.42` | **0% потерь** | Корпоративный прокси доступен напрямую в обход туннеля |
| `curl.exe -x http://10.26.254.42:3128 -I https://home.guseynovia.ru` | **HTTP 200 / 400** | Соединение с внешним wstunnel через прокси работает |
| `curl.exe -s https://ifconfig.me` | **`94.183.159.114`** | Внешний интернет идет через VPN (Нидерланды / sirin0) |
| `curl.exe -s -o NUL -w "%{http_code}" https://www.google.com` | **200** | Google доступен через туннель sirin0 |
| `curl.exe -s -o NUL -w "%{http_code}" https://www.youtube.com` | **200** | YouTube доступен через туннель и TPROXY sing-box |
| `curl.exe -s -o NUL -w "%{http_code}" https://www.sberbank.ru` | **200** | Российские ресурсы маршрутизируются напрямую (`ru_direct`) |
| `curl.exe -s -o NUL -w "%{http_code}" https://chatgpt.com` | **200** или **403** | sing-box (403 — Cloudflare anti-bot для CLI, не сетевой таймаут) |
| `ping -n 4 10.10.10.1` | **0% потерь** | WireGuard-сервер (мини-ПК) |
| `ssh brat@10.10.10.1` | **SSH_OK (MicroITX-PC)** | Доступ к консоли мини-ПК по VPN IP |
| `curl -I http://192.168.1.1/` | **HTTP 200 OK** | Доступ к веб-интерфейсу OpenWrt (домашняя LAN) |
| `ssh brat@192.168.1.229` | **SSH_OK** | Доступ по домашнему LAN IP (проверка MASQUERADE) |

---

## 7. Диагностика и устранение проблем

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

## 8. Повседневное использование

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

## 9. Автозапуск wstunnel через Планировщик задач Windows

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

---

## 10. Регламент ротации секретов и безопасность

Для обеспечения долгосрочной безопасности инфраструктуры после тестирования и отладки рекомендуется выполнить плановую ротацию ключевых учетных данных:

1. **Пароль PPPoE провайдера (Ростелеком):**
   * Расположение: `/etc/config/network` (секция `config interface 'wan'`) на роутере OpenWrt.
   * Процедура: смените пароль в личном кабинете провайдера и обновите опцию `option password` через LuCI (`Сеть -> Интерфейсы -> WAN`) либо `uci set network.wan.password='...' && uci commit network && /etc/init.d/network restart`.
2. **Пароль клиента Sirin VPN (sing-box outbound):**
   * Расположение: `/etc/sirin/client.toml` и конфигурация `sing-box` на роутере OpenWrt.
   * Процедура: сгенерируйте новый токен/пароль на внешнем сервере выхода (Нидерланды) и синхронизируйте его на роутере с перезапуском сервиса `sirin-client` (`service sirin restart`).
3. **UUID для VLESS / Shadowsocks:**
   * Расположение: конфигурация upstream-прокси (`media.guseynovia.ru`).
   * Процедура: сгенерируйте новый UUID (`uuidgen` в Linux / `[Guid]::NewGuid()` в PowerShell) на стороне VLESS-сервера и обновите клиентский outbound в `/etc/sing-box/config.json`.
4. **Пароль панели управления CRP:**
   * Расположение: веб-интерфейс панели управления на `crp.guseynovia.ru`.
   * Процедура: смените пароль учетной записи администратора в настройках безопасности панели.
5. **Приватные ключи WireGuard (`client.key`, `server.key`):**
   * Расположение: `~/wg-keys/` на мини-ПК, `/etc/wireguard/wg0.conf`.
   * Процедура: при компрометации клиента сгенерируйте новую пару ключей (`wg genkey | tee client.key | wg pubkey > client.pub`), обновите `PublicKey` пира на сервере и перевыпустите зашифрованный `config.enc`.
6. **Пароль расшифровки конфигурации (`WG_PASS`):**
   * Не передавайте пароль шифрования в открытом виде по незащищённым каналам. Переменная окружения `$env:WG_PASS` автоматически выгружается из памяти скриптом `install.ps1` сразу после расшифровки.
