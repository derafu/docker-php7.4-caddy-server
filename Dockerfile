#
# Stage 1: a patched PHP 7.4, built from PHP's own security backport branch
# for CVE-2026-109618/CVE-2026-109619 instead of the (unpatched, for this
# CVE) official php:7.4-fpm image. PHP 7.4 is end-of-life, so php.net never
# publishes this as an official release; the backport exists only as a git
# branch. This follows the exact build recipe docker-library/php used for
# php:7.4-fpm on bullseye (base image, build flags, ./configure options),
# swapping only how the source is obtained: a pinned commit on that branch
# (reviewed in full before pinning it), not the 7.4.33 release tarball, so
# there's no PGP signature to verify here the way an official release has.
# PHP_EXTRA_VERSION marks the resulting build as non-official.
#
FROM debian:bullseye-slim AS derafu-php-74-fpm

# Debian bullseye's live apt mirrors (deb.debian.org) no longer serve it;
# switch to the point-in-time snapshot the base image already ships
# commented out, so the build stays reproducible instead of depending on
# current mirror state.
RUN sed -i \
        -e '/^deb http:\/\/deb\.debian\.org/s/^/#/' \
        -e '/^# deb http:\/\/snapshot\.debian\.org/s/^# //' \
        /etc/apt/sources.list \
    && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

# Prevent Debian's own PHP packages from being installed.
RUN set -eux; \
    { \
        echo 'Package: php*'; \
        echo 'Pin: release *'; \
        echo 'Pin-Priority: -1'; \
    } > /etc/apt/preferences.d/no-debian-php

# Dependencies required for running "phpize" (kept installed: the main
# stage's extensions need them again later), plus git (to fetch the patched
# source) and bison (building from a git checkout, unlike from a release
# tarball, requires regenerating the parser/lexer and configure script).
ENV PHPIZE_DEPS \
        autoconf \
        bison \
        dpkg-dev \
        file \
        g++ \
        gcc \
        git \
        libc-dev \
        make \
        pkg-config \
        re2c

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        $PHPIZE_DEPS \
        ca-certificates \
        curl \
    ; \
    rm -rf /var/lib/apt/lists/*

ENV PHP_INI_DIR /usr/local/etc/php
RUN set -eux; \
    mkdir -p "$PHP_INI_DIR/conf.d"; \
    [ ! -d /var/www/html ]; \
    mkdir -p /var/www/html; \
    chown www-data:www-data /var/www/html; \
    chmod 777 /var/www/html

# Same hardening flags docker-library/php uses for this image.
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -pie"

# The pinned commit on php/php-src's PHP-7.4-CVE-2026-109618-109619 branch.
ENV PHP_SRC_REPO="https://github.com/php/php-src.git"
ENV PHP_SRC_COMMIT="712e60f9edfd03f0960fc4fc3c2c375f42b90aa2"
ENV PHP_VERSION="7.4.34-derafu"

RUN set -eux; \
    mkdir -p /usr/src/php; \
    cd /usr/src/php; \
    git init -q; \
    git remote add origin "$PHP_SRC_REPO"; \
    git fetch -q --depth 1 origin "$PHP_SRC_COMMIT"; \
    git checkout -q FETCH_HEAD; \
    rm -rf .git; \
    # php.net never released this as an official version; mark the build
    # as not that. Matches whatever version string configure.ac's AC_INIT
    # line actually has (not a hardcoded one), and fails the build loudly,
    # instead of silently changing nothing, if that line's shape ever
    # changes (e.g. a future revision of this patch bumps its own version).
    grep -q '^AC_INIT(\[PHP\],\[[^]]*\],' configure.ac; \
    sed -i -E "s/^(AC_INIT\(\[PHP\],\[)[^]]*(\],)/\1${PHP_VERSION}\2/" configure.ac; \
    grep -q "^AC_INIT(\[PHP\],\[${PHP_VERSION}\]," configure.ac

RUN set -eux; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libargon2-dev \
        libcurl4-openssl-dev \
        libonig-dev \
        libreadline-dev \
        libsodium-dev \
        libsqlite3-dev \
        libssl-dev \
        libxml2-dev \
        zlib1g-dev \
    ; \
    \
    export \
        CFLAGS="$PHP_CFLAGS" \
        CPPFLAGS="$PHP_CPPFLAGS" \
        LDFLAGS="$PHP_LDFLAGS" \
    ; \
    cd /usr/src/php; \
    ./buildconf --force; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
    debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
# https://bugs.php.net/bug.php?id=74125
    if [ ! -d /usr/include/curl ]; then \
        ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl; \
    fi; \
    ./configure \
        --build="$gnuArch" \
        --with-config-file-path="$PHP_INI_DIR" \
        --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
        --enable-option-checking=fatal \
        --with-mhash \
        --with-pic \
        --enable-ftp \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-sodium=shared \
        --with-pdo-sqlite=/usr \
        --with-sqlite3=/usr \
        --with-curl \
        --with-iconv \
        --with-openssl \
        --with-readline \
        --with-zlib \
        --disable-phpdbg \
        --with-pear \
        $(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
        --with-libdir="lib/$debMultiarch" \
        --disable-cgi \
        --enable-fpm \
        --with-fpm-user=www-data \
        --with-fpm-group=www-data \
    ; \
    make -j "$(nproc)"; \
    find -type f -name '*.a' -delete; \
    make install; \
    find \
        /usr/local \
        -type f \
        -perm '/0111' \
        -exec sh -euxc ' \
            strip --strip-all "$@" || : \
        ' -- '{}' + \
    ; \
    make clean; \
# copy default example "php.ini" files somewhere easily discoverable
    cp -v php.ini-* "$PHP_INI_DIR/"; \
    \
    cd /; \
    \
# docker-php-ext-install (used in the next stage, e.g. for gd/imap) relies
# on docker-php-source extract, which expects a cached /usr/src/php.tar.xz
# to re-extract from. We built from a git checkout, not a tarball, so there
# is none; keep the already-built tree instead and mark it as already
# extracted, which is the same thing docker-php-source itself checks for.
    touch /usr/src/php/.docker-extracted; \
    \
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
    apt-mark auto '.*' > /dev/null; \
    [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
    find /usr/local -type f -executable -exec ldd '{}' ';' \
        | awk '/=>/ { print $(NF-1) }' \
        | sort -u \
        | xargs -r dpkg-query --search \
        | cut -d: -f1 \
        | sort -u \
        | xargs -r apt-mark manual \
    ; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*; \
    \
    pecl update-channels; \
    rm -rf /tmp/pear ~/.pearrc; \
    \
# smoke test
    php --version

# Same helper scripts the official image ships, taken from our own
# (trusted, already-pulled) unpatched php:7.4-fpm image rather than fetched
# again from elsewhere.
COPY --from=php:7.4-fpm \
    /usr/local/bin/docker-php-ext-configure \
    /usr/local/bin/docker-php-ext-enable \
    /usr/local/bin/docker-php-ext-install \
    /usr/local/bin/docker-php-source \
    /usr/local/bin/docker-php-entrypoint \
    /usr/local/bin/

# sodium was built as a shared module, so let's enable it too.
RUN docker-php-ext-enable sodium

WORKDIR /var/www/html

RUN set -eux; \
    cd /usr/local/etc; \
    if [ -d php-fpm.d ]; then \
        sed 's!=NONE/!=!g' php-fpm.conf.default | tee php-fpm.conf > /dev/null; \
        cp php-fpm.d/www.conf.default php-fpm.d/www.conf; \
    fi; \
    { \
        echo '[global]'; \
        echo 'error_log = /proc/self/fd/2'; \
        echo; echo 'log_limit = 8192'; \
        echo; \
        echo '[www]'; \
        echo 'access.log = /proc/self/fd/2'; \
        echo; \
        echo 'clear_env = no'; \
        echo; \
        echo 'catch_workers_output = yes'; \
        echo 'decorate_workers_output = no'; \
    } | tee php-fpm.d/docker.conf; \
    { \
        echo '[global]'; \
        echo 'daemonize = no'; \
        echo; \
        echo '[www]'; \
        echo 'listen = 9000'; \
    } | tee php-fpm.d/zz-docker.conf

STOPSIGNAL SIGQUIT

# These make this stage runnable on its own (e.g. when published and used
# standalone, as `ghcr.io/derafu/php:7.4.34-derafu-fpm`); stage 2 always
# overrides both with its own, so this has no effect on the full image.
ENTRYPOINT ["docker-php-entrypoint"]
EXPOSE 9000
CMD ["php-fpm"]

#
# Stage 2: unchanged from before this patched-PHP work — same Caddy/sudo/
# SSH/PHP-FPM hardening, just built on the patched PHP above instead of the
# official (unpatched for this CVE) php:7.4-fpm image.
#
FROM derafu-php-74-fpm

# Arguments.
ARG CADDY_DEBUG=
ARG OPCACHE_ENABLE=1
ARG XDEBUG_ENABLE=0
ARG NETWORK_TOOLS_ENABLE=0
ARG PHP_DISABLE_FUNCTIONS=
ARG WWW_ROOT_PATH=/var/www/sites
ARG WWW_USER=admin
ARG WWW_GROUP=www-data

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
