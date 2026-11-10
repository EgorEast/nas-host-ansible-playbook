# Shows available recipes
default:
    @{{ just_executable() }} --list --justfile {{ justfile() }}

# Applies all host configuration (Docker DNS, sysctl, /etc/hosts, fallback DNS, fail2ban, UPS)
install-all *extra_args:
    ansible-playbook -i inventory/hosts playbook.yml {{ extra_args }}

# Alias for install-all — nas-host has no separate setup/install stages, unlike mash-playbook/mdad
setup-all *extra_args: (install-all extra_args)

# Dry-run — shows what would change without applying it
check *extra_args:
    ansible-playbook -i inventory/hosts playbook.yml --check --diff {{ extra_args }}

# Runs the playbook with the given list of comma-separated tags and optional arguments
run-tags tags *extra_args:
    ansible-playbook -i inventory/hosts playbook.yml --tags={{ tags }} {{ extra_args }}

# Configures /etc/docker/daemon.json upstream DNS (restarts docker — see README)
docker-dns *extra_args: (run-tags "docker-dns" extra_args)

# Configures sysctl UDP buffers for LiveKit
sysctl *extra_args: (run-tags "sysctl" extra_args)

# Configures the /etc/hosts split-DNS safety net
hosts *extra_args: (run-tags "hosts" extra_args)

# Configures fallback DNS resolvers (resolv.conf.tail + live file; restarts the runner only if idle)
dns-fallback *extra_args: (run-tags "dns-fallback" extra_args)

# Configures fail2ban jails (sshd, nextcloud, synapse)
fail2ban *extra_args: (run-tags "fail2ban" extra_args)

# Configures the CyberPower UPS (pwrstatd) — requires PowerPanel installed manually, see README
ups *extra_args: (run-tags "ups" extra_args)
