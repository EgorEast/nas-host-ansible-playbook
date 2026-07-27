# nas-host

Ansible-роль для хостовых настроек NAS. MASH/MDAD ставят Docker-контейнеры,
но не трогают уровень ОС. Всё что нужно на самом хосте — здесь.

## Что делает

- **`/etc/docker/daemon.json`** — фиксирует upstream DNS для контейнеров.
  Без этого после ребута контейнеры получают пустой resolv.conf и твои домены перестают резолвиться → федерация, LiveKit, push ломаются с `server misbehaving`.
- **`/etc/sysctl.d/99-livekit.conf`** — UDP-буферы 16MB для Element Call.
- **`/etc/hosts`** — split-DNS страховка. Основной split-DNS на роутере, здесь дубль на случай его перезапуска.
- **fail2ban** — защита от брутфорса. Три jail: SSH, Nextcloud, Synapse. LAN whitelisted.

## Что НЕ делает

- **`/etc/fstab`** — `nofail,x-systemd.device-timeout=30s` для `/mnt/data` правь руками. Автоматизация fstab через ansible слишком рискованна на живой системе.
- **UPS / pwrstatd, BIOS, SMART тесты** — разово, см. страницу 18.

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
