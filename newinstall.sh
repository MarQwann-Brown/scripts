#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Log
LOG_FILE="/var/log/itflow_install.log"
rm -f "$LOG_FILE"

# Spinner
spin() {
    local pid=$!
    local delay=0.1
    local spinner='|/-\\'
    local message=$1
    while kill -0 $pid 2>/dev/null; do
        for i in $(seq 0 3); do
            printf "\r$message ${spinner:$i:1}"
            sleep $delay
        done
    done
    printf "\r$message... Done!        \n"
}

log() {
    echo "$(date): $1" >> "$LOG_FILE"
}

show_progress() {
    echo -e "${GREEN}$1${NC}"
}

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root.${NC}"
    exit 1
fi

# CLI Args
unattended=false
DEFAULT_LAN_CIDR="192.168.2.0/24"
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)
            domain="$2"
            shift 2
            ;;
        -t|--timezone)
            timezone="$2"
            shift 2
            ;;
        -b|--branch)
            branch="$2"
            shift 2
            ;;
        -s|--ssl)
            ssl_type="$2"
            shift 2
            ;;
        -i|--internal-ip)
            internal_ip="$2"
            shift 2
            ;;
        -u|--unattended)
            unattended=true
            shift
            ;;
        -h|--help)
            echo -e "\nUsage: $0 [options]"
            echo "  -d, --domain DOMAIN        Set the domain name (FQDN)"
            echo "  -t, --timezone ZONE        Set the system timezone"
            echo "  -b, --branch BRANCH        Git branch to use: master or develop"
            echo "  -s, --ssl TYPE             SSL type: letsencrypt, selfsigned, internal-ca, none"
            echo "  -i, --internal-ip IP       Internal IP to bind Apache to (recommended)"
            echo "  -u, --unattended           Run in fully automated mode"
            echo "  -h, --help                 Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option $1${NC}"
            exit 1
            ;;
    esac
done

# Timezone
if [ "$unattended" = true ]; then
    timezone=${timezone:-"America/New_York"}
else
    timezone=${timezone:-$(cat /etc/timezone 2>/dev/null || echo "UTC")}
    read -p "Timezone [${timezone}]: " input_tz
    timezone=${input_tz:-$timezone}
fi

if [ -f "/usr/share/zoneinfo/$timezone" ]; then
    timedatectl set-timezone "$timezone"
else
    echo -e "${RED}Invalid timezone.${NC}"
    exit 1
fi

# Domain
current_fqdn=$(hostname -f 2>/dev/null || echo "")
domain=${domain:-$current_fqdn}
if [ "$unattended" != true ]; then
    read -p "Domain [${domain}]: " input_domain
    domain=${input_domain:-$domain}
fi
if ! [[ $domain =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[a-zA-Z]{2,}$ ]]; then
    echo -e "${RED}Invalid domain.${NC}"
    exit 1
fi

# Internal IP (for binding Apache and firewall rules)
if [ -z "$internal_ip" ]; then
    # try to auto-detect a private IPv4 address
    internal_ip=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | grep -E '^10\.|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-1]\.|^192\.168\.' | head -n1)
fi
if [ "$unattended" != true ]; then
    read -p "Internal IP to bind Apache [${internal_ip}]: " input_ip
    internal_ip=${input_ip:-$internal_ip}
fi
if [ -z "$internal_ip" ]; then
    echo -e "${YELLOW}No internal IP provided or detected. Apache will bind to all interfaces. Be careful to not expose to the Internet.${NC}"
fi

# Branch
branch=${branch:-master}
if [ "$unattended" != true ]; then
    echo -e "Available branches: master, develop"
    read -p "Which branch to use [${branch}]: " input_branch
    branch=${input_branch:-$branch}
fi
if [[ "$branch" != "master" && "$branch" != "develop" ]]; then
    echo -e "${RED}Invalid branch.${NC}"
    exit 1
fi

# SSL
ssl_type=${ssl_type:-internal-ca}
if [ "$unattended" != true ]; then
    echo -e "SSL options: letsencrypt, selfsigned, internal-ca, none"
    read -p "SSL type [${ssl_type}]: " input_ssl
    ssl_type=${input_ssl:-$ssl_type}
fi
if [[ "$ssl_type" != "letsencrypt" && "$ssl_type" != "selfsigned" && "$ssl_type" != "internal-ca" && "$ssl_type" != "none" ]]; then
    echo -e "${RED}Invalid SSL option.${NC}"
    exit 1
fi

# Prevent accidental Let's Encrypt on private/internal names
if [[ "$ssl_type" == "letsencrypt" ]]; then
    if [[ "$domain" =~ \.local$|\.internal$|\.lan$ ]]; then
        echo -e "${RED}Let's Encrypt cannot issue certificates for private/internal names. Choose internal-ca or selfsigned.${NC}"
        exit 1
    fi
fi

# HTTPS config flag
config_https_only="TRUE"
if [[ "$ssl_type" == "none" ]]; then
    config_https_only="FALSE"
fi

# Passwords
MARIADB_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
mariadbpwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

# Install packages
show_progress "Installing packages..."
{
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get -y upgrade
    apt-get install -y apache2 mariadb-server \
        php libapache2-mod-php php-intl php-mysqli php-gd \
        php-curl php-mbstring php-zip php-xml \
        certbot python3-certbot-apache git sudo whois cron dnsutils openssl ufw
} & spin "Installing packages"

# PHP config
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHP_INI_PATH="/etc/php/${PHP_VERSION}/apache2/php.ini"
sed -i 's/^;\?upload_max_filesize =.*/upload_max_filesize = 500M/' "$PHP_INI_PATH"
sed -i 's/^;\?post_max_size =.*/post_max_size = 500M/' "$PHP_INI_PATH"
sed -i 's/^;\?max_execution_time =.*/max_execution_time = 300/' "$PHP_INI_PATH"

# Apache setup
show_progress "Configuring Apache..."
{
    a2enmod ssl rewrite
    mkdir -p /var/www/${domain}

    # Choose Listen directive and vhost binding
    if [ -n "$internal_ip" ]; then
        # ensure Apache listens on the internal IP and localhost explicitly
        sed -i '/^Listen /d' /etc/apache2/ports.conf
        echo "Listen ${internal_ip}:80" >> /etc/apache2/ports.conf
        echo "Listen ${internal_ip}:443" >> /etc/apache2/ports.conf
        echo "Listen 127.0.0.1:80" >> /etc/apache2/ports.conf
        echo "Listen 127.0.0.1:443" >> /etc/apache2/ports.conf
        
        bind_vhost_80="${internal_ip}:80 127.0.0.1:80"
        bind_vhost_443="${internal_ip}:443 127.0.0.1:443"
    else
        bind_vhost_80="*:80"
        bind_vhost_443="*:443"
    fi

    # Handle Redirection correctly so it doesn't break if SSL is none
    if [[ "$ssl_type" != "none" ]]; then
        REDIRECT_LINE="Redirect permanent / https://${domain}/"
    else
        REDIRECT_LINE=""
    fi

    cat <<EOF > /etc/apache2/sites-available/${domain}.conf
<VirtualHost ${bind_vhost_80}>
    ServerName ${domain}
    ServerAlias localhost 127.0.0.1
    DocumentRoot /var/www/${domain}
    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined
    ${REDIRECT_LINE}
</VirtualHost>
EOF

    a2ensite ${domain}.conf
    a2dissite 000-default.conf
    systemctl reload apache2

    # SSL handling
    if [[ "$ssl_type" == "letsencrypt" ]]; then
        # Use certonly to avoid automatic apache misconfigurations, we will write the config explicitly
        certbot certonly --apache --non-interactive --agree-tos --register-unsafely-without-email --domains ${domain}
        CERT_FILE="/etc/letsencrypt/live/${domain}/fullchain.pem"
        KEY_FILE="/etc/letsencrypt/live/${domain}/privkey.pem"

    elif [[ "$ssl_type" == "selfsigned" || "$ssl_type" == "internal-ca" ]]; then
        mkdir -p /etc/ssl/private /etc/ssl/certs
        CERT_FILE="/etc/ssl/certs/${domain}.crt"
        KEY_FILE="/etc/ssl/private/${domain}.key"

        if [[ "$ssl_type" == "selfsigned" ]]; then
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "${KEY_FILE}" \
                -out "${CERT_FILE}" \
                -subj "/C=US/ST=State/L=City/O=Org/OU=IT/CN=${domain}" \
                -addext "subjectAltName=DNS:${domain},DNS:localhost,IP:127.0.0.1"
        else
            # internal-ca
            CA_KEY="/root/local-ca.key"
            CA_CERT="/root/local-ca.crt"
            SERVER_CSR="/tmp/${domain}.csr"
            EXTFILE="/tmp/${domain}_ext.cnf"

            if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CERT" ]; then
                openssl genrsa -out "$CA_KEY" 4096
                openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
                    -subj "/C=US/ST=State/L=City/O=MarQwann/OU=IT/CN=MarQwann Local CA" \
                    -out "$CA_CERT"
                log "Created local CA at $CA_CERT"
            fi

            openssl genrsa -out "${KEY_FILE}" 2048
            openssl req -new -key "${KEY_FILE}" -subj "/C=US/ST=State/L=City/O=MarQwann/OU=IT/CN=${domain}" -out "$SERVER_CSR"

            # Added Localhost and 127.0.0.1 to SANs
            cat > "$EXTFILE" <<EOFEXT
subjectAltName = DNS:${domain}, DNS:$(echo ${domain} | cut -d. -f1), DNS:localhost, IP:127.0.0.1
EOFEXT

            openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
                -out "${CERT_FILE}" -days 825 -sha256 -extfile "$EXTFILE"
            rm -f "$SERVER_CSR" "$EXTFILE"
            log "Signed server cert ${CERT_FILE} with local CA $CA_CERT"
        fi
    fi

    # Write SSL config explicitly regardless of type
    if [[ "$ssl_type" != "none" ]]; then
        cat <<EOFSSL > /etc/apache2/sites-available/${domain}-ssl.conf
<VirtualHost ${bind_vhost_443}>
    ServerName ${domain}
    ServerAlias localhost 127.0.0.1
    DocumentRoot /var/www/${domain}

    SSLEngine on
    SSLCertificateFile ${CERT_FILE}
    SSLCertificateKeyFile ${KEY_FILE}

    ErrorLog \${APACHE_LOG_DIR}/${domain}_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_ssl_access.log combined
</VirtualHost>
EOFSSL
        a2ensite ${domain}-ssl.conf
        systemctl reload apache2
    else
        echo -e "${YELLOW}No SSL will be configured. HTTPS will not be available.${NC}"
    fi
} & spin "Apache setup and SSL"

# Git clone
show_progress "Cloning ITFlow..."
{
    git clone --branch ${branch} https://github.com/itflow-org/itflow.git /var/www/${domain} || true
    chown -R www-data:www-data /var/www/${domain}
} & spin "Cloning ITFlow"

# Cron jobs
PHP_BIN=$(command -v php)
cat <<EOF > /etc/cron.d/itflow
0 2 * * * www-data ${PHP_BIN} /var/www/${domain}/cron/cron.php
* * * * * www-data ${PHP_BIN} /var/www/${domain}/cron/ticket_email_parser.php
* * * * * www-data ${PHP_BIN} /var/www/${domain}/cron/mail_queue.php
0 3 * * * www-data ${PHP_BIN} /var/www/${domain}/cron/domain_refresher.php
0 4 * * * www-data ${PHP_BIN} /var/www/${domain}/cron/certificate_refresher.php
EOF
chmod 644 /etc/cron.d/itflow
chown root:root /etc/cron.d/itflow

# MariaDB
show_progress "Configuring MariaDB..."
{
    until mysqladmin ping --silent; do sleep 1; done

    # ensure MariaDB binds to localhost by default
    MYSQL_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
    if [ -f "$MYSQL_CONF" ]; then
        sed -i 's/^bind-address.*/bind-address = 127.0.0.1/' "$MYSQL_CONF" || echo "bind-address = 127.0.0.1" >> "$MYSQL_CONF"
        systemctl restart mariadb
    fi

    mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS itflow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'itflow'@'localhost' IDENTIFIED BY '${mariadbpwd}';
GRANT ALL PRIVILEGES ON itflow.* TO 'itflow'@'localhost';
FLUSH PRIVILEGES;
SQL
} & spin "MariaDB setup"

# Import SQL
SQL_DUMP="/var/www/${domain}/db.sql"
if [ -f "$SQL_DUMP" ]; then
    show_progress "Importing database..."
    log "Importing database from $SQL_DUMP"
    mysql -u itflow -p"${mariadbpwd}" itflow < "$SQL_DUMP"
else
    echo -e "${YELLOW}Database dump not found at $SQL_DUMP${NC}"
    log "Database dump not found at $SQL_DUMP"
fi

# Config.php
INSTALL_ID=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c ${#mariadbpwd})
# set base URL with scheme if HTTPS enabled
if [[ "${config_https_only}" == "TRUE" ]]; then
    base_url="https://${domain}"
else
    base_url="http://${domain}"
fi

cat <<EOF > /var/www/${domain}/config.php
<?php
\$dbhost = 'localhost';
\$dbusername = 'itflow';
\$dbpassword = '${mariadbpwd}';
\$database = 'itflow';
\$mysqli = mysqli_connect(\$dbhost, \$dbusername, \$dbpassword, \$database) or die('Database Connection Failed');
\$config_app_name = 'ITFlow';
\$config_base_url = '${base_url}';
\$config_https_only = ${config_https_only};
\$repo_branch = '${branch}';
\$installation_id = '${INSTALL_ID}';
EOF
chown www-data:www-data /var/www/${domain}/config.php
chmod 640 /var/www/${domain}/config.php

# UFW firewall (restrict to LAN)
show_progress "Configuring UFW firewall..."
if command -v ufw >/dev/null 2>&1; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # allow SSH from anywhere (optional) - keep if you need remote admin
    ufw allow OpenSSH

    # allow HTTP/HTTPS only from LAN
    if [ -n "$internal_ip" ]; then
        # derive network from DEFAULT_LAN_CIDR or try to infer /24 from internal_ip
        lan_cidr="${DEFAULT_LAN_CIDR}"
        # if DEFAULT_LAN_CIDR is default and internal_ip is in a different subnet, try /24
        if ! ipcalc -c ${internal_ip} ${lan_cidr} >/dev/null 2>&1; then
            # fallback to /24
            lan_cidr="$(echo ${internal_ip} | awk -F. '{print $1"."$2"."$3".0/24"}')"
        fi
        ufw allow from ${lan_cidr} to any port 80 proto tcp
        ufw allow from ${lan_cidr} to any port 443 proto tcp
    else
        # if no internal_ip, restrict to RFC1918 ranges
        ufw allow from 192.168.0.0/16 to any port 80,443 proto tcp
        ufw allow from 10.0.0.0/8 to any port 80,443 proto tcp
        ufw allow from 172.16.0.0/12 to any port 80,443 proto tcp
    fi

    ufw --force enable
    ufw status verbose | tee -a "$LOG_FILE"
else
    echo -e "${YELLOW}ufw not installed; skipping firewall configuration.${NC}"
fi

# Done
show_progress "Installation Complete!"
if [[ "${config_https_only}" == "TRUE" ]]; then
    echo -e "Visit: ${GREEN}https://${domain}${NC}"
else
    echo -e "Visit: ${GREEN}http://${domain}${NC}"
fi
echo -e "Log: ${GREEN}${LOG_FILE}${NC}"
if [[ "$ssl_type" == "internal-ca" ]]; then
    echo -e "${YELLOW}You selected internal-ca. Copy /root/local-ca.crt to client machines and add to their trust stores.${NC}"
fi