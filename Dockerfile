# Base image.
FROM php:7.4-fpm

# Arguments.
ARG CADDY_DEBUG=
ARG OPCACHE_ENABLE=1
ARG XDEBUG_ENABLE=0
ARG NETWORK_TOOLS_ENABLE=0
ARG PHP_DISABLE_FUNCTIONS=
ARG WWW_ROOT_PATH=/var/www/sites
ARG WWW_USER=admin
ARG WWW_GROUP=www-data

# Debian bullseye's live apt mirrors (deb.debian.org) no longer serve it;
# switch to the point-in-time snapshot the base image already ships
# commented out, so the build stays reproducible instead of depending on
# current mirror state.
RUN sed -i \
        -e '/^deb http:\/\/deb\.debian\.org/s/^/#/' \
        -e '/^# deb http:\/\/snapshot\.debian\.org/s/^# //' \
        /etc/apt/sources.list \
    && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# Run a lot of commands :)
RUN \
    \
    # Install basic dependencies.
    apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    bind9-dnsutils \
    ca-certificates \
    cron \
    curl \
    debian-archive-keyring \
    debian-keyring \
    default-libmysqlclient-dev \
    dnsutils \
    gettext \
    git \
    gnupg \
    iproute2 \
    iputils-ping \
    jq \
    libc-client-dev \
    libfreetype6-dev \
    libgd-dev \
    libgearman-dev \
    libgmp-dev \
    libicu-dev \
    libjpeg62-turbo-dev \
    libkrb5-dev \
    libmcrypt-dev \
    libmemcached-dev \
    libnss3-tools \
    libonig-dev \
    libpng-dev \
    libpq-dev \
    libsqlite3-dev \
    libxml2-dev \
    libxmlrpc-epi-dev \
    libyaml-dev \
    libzip-dev \
    logrotate \
    lsb-release \
    mutt \
    nano \
    net-tools \
    openssh-server \
    rsync \
    screen \
    sudo \
    supervisor \
    traceroute \
    unzip \
    vim \
    wget \
    zip \
    zlib1g-dev \
    \
    # Install Caddy.
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends caddy \
    && rm -rf /var/lib/apt/lists/* \
    \
    # Install PHP extensions.
    && docker-php-ext-configure gd --with-freetype=/usr/include/ --with-jpeg=/usr/include/ \
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
    && docker-php-ext-install -j$(nproc) \
        bcmath \
        exif \
        gd \
        gettext \
        gmp \
        imap \
        intl \
        mbstring \
        opcache \
        pdo_mysql \
        pdo_pgsql \
        pdo_sqlite \
        soap \
        sockets \
        xml \
        xmlrpc \
        zip \
        && pecl install redis && docker-php-ext-enable redis \
    \
    # Install Gearman, Memcached and YAML.
    && pecl install gearman memcached yaml \
    && docker-php-ext-enable gearman memcached yaml \
    \
    # Install mcrypt extension for PHP 7.4.
    && pecl install mcrypt-1.0.4 \
    && docker-php-ext-enable mcrypt \
    \
    # Install and configure Xdebug.
    && pecl install xdebug-2.9.8 \
    && docker-php-ext-enable xdebug \
    && mkdir -p /var/log/xdebug \
    && chmod 777 /var/log/xdebug \
    \
    # Create PHP socket directory.
    && mkdir -p /var/run/php && chown www-data:www-data /var/run/php \
    \
    # Create SSH directory.
    && mkdir -p /var/run/sshd \
    \
    # Create admin user for SSH access. No password is set here, and sudo
    # is not passwordless: a password must be assigned later, only when
    # actually needed, via `docker exec -u 0 <container> passwd admin`.
    && useradd -m -d /home/${WWW_USER} -s /bin/bash ${WWW_USER} \
    && usermod -aG sudo ${WWW_USER} \
    # The password hash is "*": SSH public-key login works (OpenSSH refuses
    # any login method for a "locked", "!"-prefixed account), while su/sudo
    # can never authenticate against it with any password, blank or not.
    && usermod -p '*' ${WWW_USER} \
    && mkdir -p /home/${WWW_USER}/.ssh \
    && chmod 700 /home/${WWW_USER}/.ssh \
    && ssh-keyscan -t rsa github.com >> /home/${WWW_USER}/.ssh/known_hosts \
    && chmod 600 /home/${WWW_USER}/.ssh/known_hosts \
    && chown ${WWW_USER}: /home/${WWW_USER}/.ssh/known_hosts \
    \
    # Create necessary directories for web content and give admin user access.
    && mkdir -p ${WWW_ROOT_PATH} \
    && chown -R ${WWW_USER}:${WWW_GROUP} ${WWW_ROOT_PATH} \
    && chmod 770 ${WWW_ROOT_PATH} -R \
    && ln -s ${WWW_ROOT_PATH} /home/${WWW_USER}/sites \
    \
    # Add SSH known hosts.
    && mkdir -p /etc/ssh \
    && ssh-keyscan github.com >> /etc/ssh/ssh_known_hosts \
    && chmod 644 /etc/ssh/ssh_known_hosts

# Install network/recon tools (nmap, tcpdump, telnet, whois), off by default.
# Useful for debugging, but also useful to an attacker if the container is
# ever compromised, so they are opt-in.
RUN if [ "${NETWORK_TOOLS_ENABLE}" = "1" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            nmap \
            tcpdump \
            telnet \
            whois \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Add configuration to .bashrc of the user.
COPY config/bash/bashrc /root/add-to-bashrc
RUN cat /root/add-to-bashrc >> /home/${WWW_USER}/.bashrc \
    && rm -f /root/add-to-bashrc

# Configure PHP.
COPY config/php/php.ini /usr/local/etc/php/php.ini
COPY config/php/www.conf /usr/local/etc/php-fpm.d/zz-docker.conf
COPY config/php/xdebug.ini /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini
RUN if [ "${OPCACHE_ENABLE}" = "0" ]; then \
        # Disable OPCache (independent of Caddy's debug mode).
        sed -i 's/^opcache.enable = 1/opcache.enable = 0/' /usr/local/etc/php/php.ini; \
        sed -i 's/^opcache.enable_cli = 1/opcache.enable_cli = 0/' /usr/local/etc/php/php.ini; \
    fi
RUN if [ "${XDEBUG_ENABLE}" = "1" ]; then \
        # Enable Xdebug (independent of Caddy's debug mode; Xdebug 2.x syntax).
        sed -i 's/^;zend_extension=xdebug.so/zend_extension=xdebug.so/' /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini; \
        sed -i 's/^xdebug.remote_enable = 0/xdebug.remote_enable = 1/' /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini; \
    fi
# Fill in which functions to disable for PHP-FPM requests. Empty by default:
# some apps (anything using sowerphp-framework's Controller::shell()/
# shell_exec_async(), e.g. background task launching) need exec() from a web
# request. Only set this for a site confirmed not to need any of them.
RUN sed -i "s/__PHP_DISABLE_FUNCTIONS__/${PHP_DISABLE_FUNCTIONS}/" /usr/local/etc/php-fpm.d/zz-docker.conf

# Install Composer.
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Configure Caddy.
COPY config/caddy/Caddyfile /etc/caddy/Caddyfile

# Configure SSH server.
COPY config/ssh/sshd_config /etc/ssh/sshd_config

# Configure Cron.
COPY config/cron/logrotate /etc/cron.d/logrotate

# Configure Supervisor.
COPY config/supervisor/supervisord.conf /etc/supervisor/supervisord.conf

# Use an entrypoint.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Start supervisor (default process of the container).
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
