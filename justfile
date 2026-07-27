# Shows available recipes
default:
    @{{ just_executable() }} --list --justfile {{ justfile() }}

# Applies all host configuration (Docker DNS, sysctl, /etc/hosts, fail2ban)
install-all *extra_args:
    ansible-playbook -i inventory/hosts playbook.yml {{ extra_args }}

# Dry-run — shows what would change without applying it
check *extra_args:
    ansible-playbook -i inventory/hosts playbook.yml --check --diff {{ extra_args }}
