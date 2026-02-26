#!/usr/bin/env bash
set -euo pipefail

# Script: install-ssh-restrict.sh
# Purpose: install OpenSSH server and configure UFW so only 192.168.2.0/24 can SSH
# Usage: sudo ./install-ssh-restrict.sh

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Use sudo." >&2
  exit 1
fi

SUBNET="192.168.2.0/24"
SSH_PORT=22

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG_INSTALL="apt-get update && apt-get install -y openssh-server ufw"
elif command -v dnf >/dev/null 2>&1; then
  PKG_INSTALL="dnf install -y openssh-server firewalld"
elif command -v yum >/dev/null 2>&1; then
  PKG_INSTALL="yum install -y openssh-server firewalld"
else
  echo "Unsupported distro: no apt/yum/dnf found." >&2
  exit 2
fi

echo "Installing SSH and firewall packages..."
eval "$PKG_INSTALL"

# Enable and start SSH service
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now ssh || systemctl enable --now sshd || true
else
  service ssh start || service sshd start || true
fi

# Configure UFW if available
if command -v ufw >/dev/null 2>&1; then
  echo "Configuring UFW rules..."

  # Backup current UFW status and rules
  mkdir -p /root/ufw-backup
  ufw status numbered > /root/ufw-backup/status.txt || true
  cp /etc/ufw/user.rules /root/ufw-backup/user.rules 2>/dev/null || true
  cp /etc/ufw/user6.rules /root/ufw-backup/user6.rules 2>/dev/null || true

  # Remove any existing generic allow for SSH (non-interactive)
  # We attempt to delete any rule that allows 22/tcp anywhere.
  # Use numbered deletion if present.
  if ufw status | grep -qE '22/tcp.*ALLOW'; then
    # iterate numbered rules and delete matches
    while ufw status numbered | grep -q '22/tcp.*Anywhere'; do
      NUM=$(ufw status numbered | nl -ba | sed -n '1,200p' | grep '22/tcp.*Anywhere' | awk '{print $1}' | tr -d '[]' | head -n1)
      if [ -n "$NUM" ]; then
        # ufw delete expects the rule number in brackets; use non-interactive echo
        yes | ufw delete "$NUM" >/dev/null 2>&1 || break
      else
        break
      fi
    done
  fi

  # Add allow rule for the subnet
  ufw allow from "$SUBNET" to any port "$SSH_PORT" proto tcp

  # Explicitly deny other SSH attempts (this is safe because the subnet allow exists)
  # If a deny rule already exists, this will be idempotent.
  ufw deny in "$SSH_PORT"/tcp || true

  # Enable UFW if not enabled
  if ufw status | grep -q "Status: inactive"; then
    echo "Enabling UFW (this may interrupt existing connections)..."
    ufw --force enable
  else
    ufw reload || true
  fi

  echo "UFW rules applied:"
  ufw status verbose

# If UFW not present but firewalld is, configure firewalld
elif command -v firewall-cmd >/dev/null 2>&1; then
  echo "Configuring firewalld rules..."

  # Ensure firewalld running
  systemctl enable --now firewalld

  # Create a rich rule to allow SSH from the subnet
  firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${SUBNET}' service name='ssh' accept"
  # Add a rule to reject SSH from other sources
  firewall-cmd --permanent --add-rich-rule="rule family='ipv4' service name='ssh' reject"
  firewall-cmd --reload

  echo "firewalld rules applied:"
  firewall-cmd --list-all

else
  echo "No supported firewall (ufw or firewalld) found. SSH installed but not restricted." >&2
  exit 3
fi

echo "Done. SSH installed and firewall configured to allow only ${SUBNET}."

