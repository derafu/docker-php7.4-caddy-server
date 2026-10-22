#!/bin/bash
set -e

# Expose select container environment variables to interactive shells.
# SSH sessions don't inherit the container's own environment, so this makes
# them available to config/bash/bashrc without needing sudo to read them
# from /proc/1/environ.
cat > /etc/container-env.sh <<EOF
export EDITOR="${EDITOR:-vim}"
export VISUAL="${VISUAL:-vim}"
export SITES_DIR="${SITES_DIR:-/home/admin/sites}"
EOF
chmod 644 /etc/container-env.sh

# Fix ownership/permissions on an optionally mounted ~/.ssh for WWW_USER.
# No keys are baked into the image: SSH access only works if authorized_keys
# (and optionally a client id_rsa/id_rsa.pub) are mounted there from the
# host. SSH is strict about ownership/mode, which a host bind mount won't
# generally match, so this re-applies them on every container start. If
# files are added or changed after the container is already running,
# restart it to have this run again.
SSH_HOME="/home/${WWW_USER:-admin}/.ssh"
if [ -d "${SSH_HOME}" ]; then
    chown -R "${WWW_USER:-admin}:${WWW_USER:-admin}" "${SSH_HOME}"
    chmod 700 "${SSH_HOME}"
    [ -f "${SSH_HOME}/authorized_keys" ] && chmod 600 "${SSH_HOME}/authorized_keys"
    [ -f "${SSH_HOME}/id_rsa" ] && chmod 600 "${SSH_HOME}/id_rsa"
    [ -f "${SSH_HOME}/id_rsa.pub" ] && chmod 644 "${SSH_HOME}/id_rsa.pub"
fi

# Show the current user.
echo "Current user: $(whoami)"

# Run the main process (by default supervisord).
exec "$@"
