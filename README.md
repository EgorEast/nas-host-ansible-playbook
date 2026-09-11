# nas-host

Ansible-роль для хостовых настроек NAS. MASH/MDAD ставят Docker-контейнеры,
но не трогают уровень ОС. Всё что нужно на самом хосте — здесь.

## Что делает

- **`/etc/docker/daemon.json`** — фиксирует upstream DNS для контейнеров.
  Без этого после ребута контейнеры получают пустой resolv.conf и твои домены перестают резолвиться → федерация, LiveKit, push ломаются с `server misbehaving`.
- **`/etc/sysctl.d/99-livekit.conf`** — UDP-буферы 16MB для Element Call.
- **`/etc/hosts`** — split-DNS страховка. Основной split-DNS на роутере, здесь дубль на случай его перезапуска.
- **fail2ban** — защита от брутфорса. Три jail: SSH, Nextcloud, Synapse. LAN whitelisted.
- **CyberPower UPS (pwrstatd)** — пороги отключения (`/etc/pwrstatd.conf`) и
  скрипты событий Power Failure / Battery Low. Опционально (`nas_ups_manage`),
  выключено по умолчанию — не у всех хостов есть UPS.

## Что НЕ делает

- **`/etc/fstab`** — `nofail,x-systemd.device-timeout=30s` для `/mnt/data` правь руками. Автоматизация fstab через ansible слишком рискованна на живой системе.
- **Установка PowerPanel for Linux** (пакет `powerpanel`, демон `pwrstatd`) —
  .deb с сайта CyberPower, не в apt-репозиториях. Ставь вручную один раз,
  роль только конфигурирует уже установленный пакет (тег `ups` упадёт с
  понятной ошибкой, если бинарник не найден).
- **BIOS, SMART тесты** — разово, см. страницу 18.

## Секреты (ansible-vault)

Пароль для `/root/.netrc` (ntfy-уведомления UPS) хранится в
`inventory/host_vars/nas/vars.yml` зашифрованным через ansible-vault.
Соглашение: зашифрованное значение лежит в переменной с префиксом
`secret_` (`secret_nas_ups_ntfy_password`), а обычная переменная роли
(`nas_ups_ntfy_password`) на неё лишь ссылается:

```yaml
nas_ups_ntfy_password: "{{ secret_nas_ups_ntfy_password | default('') }}"

secret_nas_ups_ntfy_password: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  ...
```

Так по имени переменной сразу видно, что она из vault, а не открытым
текстом — удобно при grep по инвентарю.

Зашифровать пароль (не появится в истории шелла благодаря `read -s`):

```bash
read -s -p "ntfy password: " NTFY_PASS; echo
ansible-vault encrypt_string --ask-vault-pass "$NTFY_PASS" --name secret_nas_ups_ntfy_password
unset NTFY_PASS
```

Вставь результат (`secret_nas_ups_ntfy_password: !vault |...`) в
`inventory/host_vars/nas/vars.yml`. Дальше при каждом запуске плейбука,
пока в переменных есть `!vault`, нужен флаг `--ask-vault-pass` (или
`--vault-password-file`):

```bash
ansible-playbook -i inventory/hosts playbook.yml --ask-vault-pass
```

## Бэкапы (postgres_backup, mash + mdad)

Бэкап БД для сервисов mash/mdad настраивается **не здесь**, а в приватных
`inventory/host_vars/*/vars.yml` самих плейбуков (`mash-playbook`,
`matrix-docker-ansible-deploy`) — роль `postgres_backup`
(docker-postgres-backup-local, только Postgres, без файлов сервисов) там
уже включена и пишет в `/mnt/data/backups/{mash,matrix}-postgres` на
RAID1. Расписание — каждый день в 04:00, retention 7 ежедневных + 4
недельных + 6 месячных дампов. Роль сама создаёт нужные каталоги с
правильными правами — ручной подготовки на хосте не требуется.

## Использование

`inventory/` — отдельный **приватный** git-репозиторий, в `.gitignore`
этого (публичного) репозитория целиком. Все реальные домены/IP/порты —
только там, наружу через nas-host они не уходят.

Первый запуск на новой машине (URL приватного inventory-репозитория —
свой, не хранится в этом публичном репозитории):

```bash
cd ~/playbooks/nas-host
git clone <URL твоего приватного inventory-репозитория> inventory
```

Если разворачиваешь плейбук с нуля (без готового inventory-репозитория) —
создай `inventory/hosts` (INI, группа `[nas]`) и
`inventory/host_vars/nas/vars.yml` по переменным ниже — так же, как
устроены inventory в mash-playbook и matrix-docker-ansible-deploy.

```bash
# Dry-run — покажет что изменится, ничего не применит:
ansible-playbook -i inventory/hosts playbook.yml --check --diff

# Применить всё:
ansible-playbook -i inventory/hosts playbook.yml

# Точечно:
ansible-playbook -i inventory/hosts playbook.yml --tags docker-dns
ansible-playbook -i inventory/hosts playbook.yml --tags sysctl
ansible-playbook -i inventory/hosts playbook.yml --tags hosts
ansible-playbook -i inventory/hosts playbook.yml --tags fail2ban
ansible-playbook -i inventory/hosts playbook.yml --tags ups
```

Те же команды короче через [`just`](https://github.com/casey/just) (см. `justfile`, рецепты как в
mash-playbook/mdad — `setup-all` там же, что и `install-all`, отдельных стадий
setup/install в nas-host нет):

```bash
just check                # dry-run всего
just install-all          # применить всё (алиас: just setup-all)
just docker-dns           # точечно, по тегу
just sysctl
just hosts
just fail2ban
just ups
# extra_args пробрасываются как есть, например:
just ups --ask-vault-pass
```

**⚠️ Осторожно с `docker-dns`**: изменение `daemon.json` триггерит `systemd restart docker`, кладёт все контейнеры на ~1 минуту. Если не хочешь автоматом:

```bash
# Записать файл, docker не рестартить (руками потом):
ansible-playbook -i inventory/hosts playbook.yml --tags docker-dns --skip-tags never
ssh root@nas 'systemctl restart docker'   # в удобное время
```

## Проверки после применения

```bash
# DNS в контейнерах:
docker exec matrix-synapse cat /etc/resolv.conf | grep ExtServers
# должно быть: # ExtServers: [<твои nas_docker_dns>]

# sysctl:
sysctl net.core.rmem_max net.core.wmem_max
# оба должны быть 16777216

# /etc/hosts:
grep 'nas-host:' /etc/hosts
# должен быть блок BEGIN/END

# fail2ban:
fail2ban-client status
# должно быть: Jail list: sshd, nextcloud, synapse

# Кто забанен сейчас (по jail):
fail2ban-client status sshd
fail2ban-client status nextcloud

# Разбанить IP (если случайно себя):
fail2ban-client set sshd unbanip 1.2.3.4

# UPS:
pwrstat -status
# должно показать State: Normal (или On Battery при отключении питания)

systemctl is-active pwrstatd
```

## Переменные

Два слоя, чтобы плейбук можно было публиковать не спалив свою инфраструктуру:

- **`roles/nas-host/defaults/main.yml`** — безопасные общие дефолты
  (публичные DNS, generic bantime/maxretry). Не содержит ничьих
  реальных доменов/IP/портов — коммитится как есть в публичный
  nas-host репозиторий.
- **`inventory/hosts`** — адрес и порт SSH хоста `nas` (формат INI,
  как в mash-playbook/mdad).
- **`inventory/host_vars/nas/vars.yml`** — остальные реальные данные
  (DNS, домены, fail2ban whitelist).

Оба живут в отдельном приватном git-репозитории `inventory/` (см.
«Использование» выше), в публичный nas-host не попадают.

Переменные (переопределяй в `inventory/host_vars/nas/vars.yml` или
через `-e "имя=значение"`):

- `nas_docker_dns` — список upstream DNS-серверов
- `nas_lan_ip` — IP NAS в LAN (обнови при смене DHCP)
- `nas_lightnode_domains` — список доменов для /etc/hosts
- `nas_udp_buffer_size` — размер UDP-буферов LiveKit
- `nas_fail2ban_ignoreip` — сети/IP не банить никогда (LAN, VPN)
- `nas_fail2ban_bantime` — длительность бана (`1h`, `24h`)
- `nas_fail2ban_findtime` — окно наблюдения (`10m`)
- `nas_fail2ban_maxretry` — порог по умолчанию
- `nas_fail2ban_sshd_port` — порт системного SSH (в дефолтах `22`)
- `nas_fail2ban_nextcloud_log` — путь к `nextcloud.log` на хосте
- `nas_ups_manage` — включить конфигурирование UPS (по умолчанию `false`)
- `nas_ups_powerfail_delay` — задержка перед реакцией на Power Failure, сек
- `nas_ups_powerfail_shutdown` — выключать систему по одному факту Power Failure (без ожидания порога заряда)
- `nas_ups_lowbatt_threshold` — порог заряда батареи (%) для Battery Low
- `nas_ups_runtime_threshold` — порог оставшегося времени работы (сек) для Battery Low
- `nas_ups_lowbatt_shutdown` — выключать систему при Battery Low
- `nas_ups_shutdown_sustain` — сколько сек ждать graceful shutdown, прежде чем UPS отключит питание
- `nas_ups_ntfy_url` — URL ntfy-топика для уведомлений о событиях UPS (пусто — уведомление через `wall`)
- `nas_ups_ntfy_netrc_file` — путь к netrc с учёткой ntfy (по умолчанию `/root/.netrc`)
- `nas_ups_ntfy_powerfail_message` / `nas_ups_ntfy_lowbatt_message` — текст уведомлений
- `nas_ups_ntfy_machine` / `nas_ups_ntfy_login` — хост и логин для netrc (пусто — netrc не создаётся)
- `nas_ups_ntfy_password` — пароль для netrc; в host_vars ссылается на `secret_nas_ups_ntfy_password` из ansible-vault (см. «Секреты» выше)
