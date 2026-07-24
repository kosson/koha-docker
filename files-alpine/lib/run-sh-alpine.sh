#!/bin/bash
# Alpine compatibility helpers for files-alpine/run.sh.
# This file is sourced by the Alpine entrypoint to keep distro-specific logic
# out of the main boot flow.

append_if_absent()
{
    local string=$1
    local file=$2

    if ! grep -Fxq "$string" "$file"; then
        printf '%s\n' "$string" >> "$file"
    fi
}

install_os_packages() {
    if [ "$#" -eq 0 ]; then
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$@"
        return $?
    fi

    echo "[packages] No supported package manager found"
    return 1
}

remove_os_packages() {
    if [ "$#" -eq 0 ]; then
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        local installed_packages=()
        local package_name

        for package_name in "$@"; do
            if apk info -e "$package_name" >/dev/null 2>&1; then
                installed_packages+=("$package_name")
            fi
        done

        if [ "${#installed_packages[@]}" -gt 0 ]; then
            apk del "${installed_packages[@]}" || true
        fi
        return 0
    fi

    echo "[packages] No supported package manager found"
    return 1
}

service_status_all() {
    if command -v rc-status >/dev/null 2>&1; then
        rc-status -a || true
        return 0
    fi

    echo "[service] No service status command available"
}

service_control() {
    local action=$1
    local name=$2

    if command -v rc-service >/dev/null 2>&1; then
        rc-service "$name" "$action" || true
        return 0
    fi

    if command -v service >/dev/null 2>&1; then
        service "$name" "$action" || true
        return 0
    fi

    echo "[service] ${name} ${action}: no service manager available"
}

ensure_runtime_dirs() {
    mkdir -p \
        /etc/mysql \
        /etc/koha \
        /etc/koha/zebradb \
        /etc/koha/zebradb/marc_defs \
        /etc/sudoers.d \
        /var/cache/koha \
        /var/lib/koha \
        /var/log/koha \
        /var/run/koha \
        /var/lock/koha
}

run_koha_shell() {
    local instance=$1
    shift

    if command -v koha-shell >/dev/null 2>&1; then
        sudo koha-shell "$instance" -c "$*"
        return 0
    fi

    echo "[koha-shell] WARNING: koha-shell not available; skipping: $*"
}

copy_runtime_files() {
    if [ -x "${BUILD_DIR}/misc4dev/cp_alpine_files.pl" ]; then
        perl "${BUILD_DIR}/misc4dev/cp_alpine_files.pl" \
            --instance          "${KOHA_INSTANCE}" \
            --koha_dir          "${BUILD_DIR}/koha" \
            --gitify_dir        "${BUILD_DIR}/gitify"
        return 0
    fi

    perl "${BUILD_DIR}/misc4dev/cp_debian_files.pl" \
        --instance          "${KOHA_INSTANCE}" \
        --koha_dir          "${BUILD_DIR}/koha" \
        --gitify_dir        "${BUILD_DIR}/gitify"
}

enable_instance_services() {
    if command -v koha-plack >/dev/null 2>&1; then
        if ! koha-plack --enable "${KOHA_INSTANCE}" >/dev/null 2>&1; then
            echo "[INFO] koha-plack not enabled in this profile; continuing with Apache CGI mode"
        fi
    else
        echo "[INFO] koha-plack command not available; continuing"
    fi

    if command -v koha-z3950-responder >/dev/null 2>&1; then
        if ! koha-z3950-responder --enable "${KOHA_INSTANCE}" >/dev/null 2>&1; then
            echo "[INFO] koha-z3950-responder enable skipped; continuing"
        fi
    else
        echo "[INFO] koha-z3950-responder command not available; continuing"
    fi
}

start_koha_service() {
    if command -v koha-plack >/dev/null 2>&1; then
        koha-plack --start "${KOHA_INSTANCE}" >/dev/null 2>&1 || true
    fi

    if command -v koha-worker >/dev/null 2>&1; then
        koha-worker --start "${KOHA_INSTANCE}" >/dev/null 2>&1 || true
    else
        echo "[service] koha-worker command not available; background workers not started"
    fi
}

stop_apache_service() {
    if command -v httpd >/dev/null 2>&1; then
        httpd -k stop >/dev/null 2>&1 || true
    fi
}

start_apache_service() {
    if command -v httpd >/dev/null 2>&1; then
        httpd -k start >/dev/null 2>&1 || true
        return 0
    fi

    echo "[service] httpd not available; apache start skipped"
}

bootstrap_koha_instance() {
    if command -v koha-create >/dev/null 2>&1; then
        local koha_create_mode
        koha_create_mode=${KOHA_CREATE_MODE:---create-db}

        if [ -n "${DB_NAME:-}" ] \
            && command -v mysql >/dev/null 2>&1 \
            && [ -f /etc/mysql/koha-common.cnf ] \
            && mysql --defaults-extra-file=/etc/mysql/koha-common.cnf -Nse "SHOW DATABASES LIKE '${DB_NAME}'" 2>/dev/null | grep -qx "${DB_NAME}"; then
            koha_create_mode="--use-db"
            echo "[koha-create] Detected existing database ${DB_NAME}; using --use-db"
        fi

        if ! koha-create "${koha_create_mode}" "${KOHA_INSTANCE}" \
            --memcached-servers memcached:11211 \
            --mb-host "${MESSAGE_BROKER_HOST}" \
            --mb-port "${MESSAGE_BROKER_PORT}" \
            --mb-user "${MESSAGE_BROKER_USER}" \
            --mb-pass "${MESSAGE_BROKER_PASS}" \
            --mb-vhost "${MESSAGE_BROKER_VHOST}"; then
            echo "[koha-create] WARNING: bootstrap failed in Alpine compatibility mode; continuing to surface downstream blockers"
        fi
        return 0
    fi

    echo "[koha-create] WARNING: koha-create not available; skipping instance bootstrap"
}

sync_l10n() {
    if [ "${SKIP_L10N}" = "yes" ]; then
        echo "[koha-l10n] Skipping"
        return 0
    fi

    local l10n_branch
    if [[ ! -z "$KOHA_IMAGE" && ! "$KOHA_IMAGE" =~ ^main ]]; then
        l10n_branch=${KOHA_IMAGE:0:5}
    else
        l10n_branch="main"
    fi

    set +e

    echo "[koha-l10n] Handling koha-l10n as requested"

    if [ ! -d "$BUILD_DIR/koha/misc/translator/po" ]; then
        echo "    [*] Cloning koha-l10n into misc/translator/po"
        run_koha_shell "${KOHA_INSTANCE}" "git clone --depth 1 --branch ${l10n_branch} https://gitlab.com/koha-community/koha-l10n.git $BUILD_DIR/koha/misc/translator/po"
    elif [ -d "$BUILD_DIR/koha/misc/translator/po/.git" ]; then
        echo "    [*] Chowning po files (safety measure)"
        chown -R "${KOHA_INSTANCE}-koha" "$BUILD_DIR/koha/misc/translator/po"
        echo "    [*] Fetching koha-l10n"
        run_koha_shell "${KOHA_INSTANCE}" "git config --global --add safe.directory $BUILD_DIR/koha/misc/translator/po ; git -C $BUILD_DIR/koha/misc/translator/po fetch origin ; git -C $BUILD_DIR/koha/misc/translator/po checkout -B ${l10n_branch} origin/${l10n_branch}"
    fi

    set -e
}

setup_git_workflow() {
    echo "[git] Setting up Git on the instance user"
    echo "    [*] Generating /var/lib/koha/${KOHA_INSTANCE}/.gitconfig"
    run_koha_shell "${KOHA_INSTANCE}" "cp ${BUILD_DIR}/templates/gitconfig /var/lib/koha/${KOHA_INSTANCE}/.gitconfig"

    echo "    [*] General setup"
    run_koha_shell "${KOHA_INSTANCE}" "cd ${BUILD_DIR}/koha ; git config --global --add safe.directory ${BUILD_DIR}/koha ; git config --global user.name \"${GIT_USER_NAME}\" ; git config --global user.email \"${GIT_USER_EMAIL}\" ; git config bz.default-tracker bugs.koha-community.org ; git config bz.default-product Koha ; git config --global bz-tracker.bugs.koha-community.org.path /bugzilla3 ; git config --global bz-tracker.bugs.koha-community.org.https true ; git config --global core.whitespace trailing-space,space-before-tab ; git config --global apply.whitespace fix ; git config --global bz-tracker.bugs.koha-community.org.bz-user \"${GIT_BZ_USER}\" ; git config --global bz-tracker.bugs.koha-community.org.bz-password \"${GIT_BZ_PASSWORD}\" "
}

install_git_hooks() {
    local git_base_dir=$1

    if [ "${GIT_WORKTREE_SOURCE}" != "" ]; then
        echo "    [!] Detected worktree: pointing to '${GIT_WORKTREE_SOURCE}'"
        git_base_dir=${GIT_WORKTREE_SOURCE}
        run_koha_shell "${KOHA_INSTANCE}" "cd ${BUILD_DIR}/koha ; git config --global --add safe.directory ${GIT_WORKTREE_SOURCE}"
        echo "    [*] Added '${GIT_WORKTREE_SOURCE}' to safe directories"
    fi

    if [ "${GIT_WORKTREE_SOURCE}" != "" ]; then
        echo "    [!] Skipping hooks setup"
    else
        echo "    [*] Installing and setting hooks (${git_base_dir})"
        run_koha_shell "${KOHA_INSTANCE}" "mkdir -p ${git_base_dir}/.git/hooks/ktd ; cp ${BUILD_DIR}/git_hooks/* ${git_base_dir}/.git/hooks/ktd ; cd ${git_base_dir} ; git config --local core.hooksPath .git/hooks/ktd"
    fi
}
