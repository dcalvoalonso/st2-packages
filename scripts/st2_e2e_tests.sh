#!/bin/bash
#
# End-to-end tests run on a package test node after the rspec suite.
#
# Usage: st2_e2e_tests.sh self-check | webui | upgrade
#
#   self-check  Install the built st2 package on a clean node, enable authentication and
#               run st2-self-check (st2tests suite: runners incl. remote SSH, rules,
#               datastore, Orquesta examples).
#   webui       Run after self-check, on the same node. Install nginx with the install
#               script functions and the st2web package from $ST2WEB_DIR, then use the
#               Web UI, auth, API and stream endpoints through nginx over HTTPS, as the
#               browser does.
#   upgrade     Install the latest st2 release from the StackStorm "stable" repository,
#               create some state, upgrade to the built package and check that the state
#               is kept and that st2 still works. Skipped when no release exists for the
#               distribution.
#
# The MongoDB "st2" database should be dropped before each test (done by the workflow).
#
set -eE -o pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/root/build}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ST2_REPO="${ST2_REPO:-stable}"
CONF=/etc/st2/st2.conf
ST2_USER=st2admin
ST2_PYTHON=/opt/stackstorm/st2/bin/python
ST2WEB_DIR="${ST2WEB_DIR:-$ARTIFACT_DIR/st2web}"
WEB_URL=https://127.0.0.1

export MONGODBHOST="${MONGODBHOST:-mongodb}"
export RABBITMQHOST="${RABBITMQHOST:-rabbitmq}"
export REDISHOST="${REDISHOST:-redis}"
export DEBIAN_FRONTEND=noninteractive

source /etc/os-release

platform() {
    [ -f /etc/debian_version ] && echo deb || echo rpm
}

heading() {
    echo
    echo "===> $*"
}

# Show the st2 state when a test fails. Written to stderr so that it is not captured
# when the failure happens inside a command substitution.
on_error() {
    heading "Failure diagnostics"
    st2ctl status || true
    st2 execution list -n 20 || true
    for svc in st2api st2auth st2actionrunner st2workflowengine; do
        journalctl -u "$svc" --no-pager -n 30 || true
    done
    if [ -d /etc/nginx ]; then
        systemctl status nginx --no-pager || true
        tail -n 30 /var/log/nginx/error.log || true
    fi
} >&2

reset_st2() {
    heading "Removing any previous st2 installation"
    if [ "$(platform)" = deb ]; then
        apt-get -y purge st2 || true
    else
        dnf -y remove st2 || true
    fi
    rm -rf /etc/st2 /opt/stackstorm /root/.st2 /home/stanley/.ssh
}

install_built_package() {
    heading "Installing the built st2 package"
    (cd "$ARTIFACT_DIR" && bash "$SCRIPTS_DIR/install_os_packages.sh" st2)
}

# Latest st2 release for this distribution from the StackStorm package repository.
# Returns 1 when the repository has no st2 package for this distribution.
install_released_package() {
    heading "Installing the latest st2 release from packagecloud.io/StackStorm/${ST2_REPO}"
    local base="https://packagecloud.io/StackStorm/${ST2_REPO}"
    if [ "$(platform)" = deb ]; then
        curl -sSfL "${base}/${ID}/dists/${VERSION_CODENAME}/Release" -o /dev/null || return 1
        mkdir -p /etc/apt/keyrings
        curl -sSfL "${base}/gpgkey" -o /etc/apt/keyrings/st2-${ST2_REPO}.asc
        echo "deb [signed-by=/etc/apt/keyrings/st2-${ST2_REPO}.asc] ${base}/${ID}/ ${VERSION_CODENAME} main" \
            > /etc/apt/sources.list.d/st2-${ST2_REPO}.list
        apt-get update
        apt-cache show st2 >/dev/null 2>&1 || return 1
        apt-get install -y st2
    else
        cat <<EOF >/etc/yum.repos.d/st2-${ST2_REPO}.repo
[st2-${ST2_REPO}]
name=st2-${ST2_REPO}
baseurl=${base}/el/${VERSION_ID%%.*}/\$basearch/
repo_gpgcheck=1
gpgcheck=0
gpgkey=${base}/gpgkey
enabled=1
EOF
        rpm --import "${base}/gpgkey"
        dnf -y --repo "st2-${ST2_REPO}" list --available st2 || return 1
        dnf -y install st2
    fi
}

remove_released_repository() {
    rm -f /etc/apt/sources.list.d/st2-${ST2_REPO}.list /etc/yum.repos.d/st2-${ST2_REPO}.repo
}

# Random password for this run only; the flat file backend accepts $2y$ bcrypt hashes.
set_password() {
    ST2_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
    ST2_PASSWORD="$ST2_PASSWORD" "$ST2_PYTHON" -c '
import bcrypt, os
h = bcrypt.hashpw(os.environ["ST2_PASSWORD"].encode(), bcrypt.gensalt()).decode()
print("%s:$2y$%s" % ("'"$ST2_USER"'", h[4:]))' >/etc/st2/htpasswd
}

# Configure st2 like a standard installation: services, authentication with a flat file
# backend, datastore encryption and the stanley system user for the remote runners.
configure_st2() {
    heading "Configuring st2"
    bash "$SCRIPTS_DIR/generate_st2_config.sh" >/dev/null
    sed -i '/^\[auth\]/,/^\[/ s/^enable *=.*/enable = True/' "$CONF"
    cat <<EOF >>"$CONF"

[keyvalue]
encryption_key_path = /etc/st2/keys/datastore_key.json
EOF
    mkdir -p /etc/st2/keys
    st2-generate-symmetric-crypto-key --key-path /etc/st2/keys/datastore_key.json

    set_password

    mkdir -p /home/stanley/.ssh
    chmod 0700 /home/stanley/.ssh
    ssh-keygen -q -t rsa -b 4096 -N '' -f /home/stanley/.ssh/stanley_rsa
    cp /home/stanley/.ssh/stanley_rsa.pub /home/stanley/.ssh/authorized_keys
    chown -R stanley:stanley /home/stanley/.ssh
    echo 'stanley ALL=(ALL) NOPASSWD: SETENV: ALL' >/etc/sudoers.d/st2-e2e
    chmod 0440 /etc/sudoers.d/st2-e2e
    sed -i -r 's/^Defaults\s+\+?requiretty/# Defaults +requiretty/g' /etc/sudoers
}

start_st2() {
    heading "Starting st2"
    st2ctl restart
    st2ctl reload --register-all --register-fail-on-failure
    login
}

login() {
    local _
    unset ST2_AUTH_TOKEN
    for _ in $(seq 1 30); do
        if ST2_AUTH_TOKEN="$(st2 auth "$ST2_USER" -p "$ST2_PASSWORD" -t 2>/dev/null)" && [ -n "$ST2_AUTH_TOKEN" ]; then
            export ST2_AUTH_TOKEN
            st2 action list --pack=core >/dev/null && return 0
        fi
        sleep 2
    done
    echo "Could not log in to st2" >&2
    return 1
}

# json_field KEY [KEY...]: print a (nested) field of the JSON document on stdin.
json_field() {
    "$ST2_PYTHON" -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1:]:
    value = value[key]
print(value)' "$@"
}

json_length() {
    "$ST2_PYTHON" -c 'import json, sys; print(len(json.load(sys.stdin)))'
}

# Run an action and fail unless it succeeds. Prints the execution id.
run_action() {
    local out status
    out="$(st2 run -j "$@")" || true
    status="$(echo "$out" | json_field status)"
    if [ "$status" != succeeded ]; then
        echo "$out" >&2
        echo "Action '$*' finished with status '$status'" >&2
        return 1
    fi
    echo "$out" | json_field id
}

check_equal() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name: expected '$expected', got '$actual'" >&2
        return 1
    fi
    echo "OK: $name"
}

st2_version() {
    st2 --version 2>&1 | sed -nE 's/^st2 ([^ ,]+).*/\1/p'
}

built_version() {
    local f
    f="$(ls -1 "$ARTIFACT_DIR"/st2[_-][0-9]*."$(platform)" | head -n1)"
    basename "$f" | sed -E 's/^st2[_-]([0-9][^-_]*).*/\1/'
}

test_self_check() {
    reset_st2
    install_built_package
    configure_st2
    start_st2

    heading "Running st2-self-check"
    # st2-self-check only exits non-zero on failure under GitHub Actions, where it also
    # expects the st2 repository checkout; check its result line instead.
    local log=/tmp/st2-self-check.log
    st2-self-check 2>&1 | tee "$log"
    grep -q '^SELF CHECK SUCCEEDED!' "$log"
}

test_upgrade() {
    reset_st2
    if ! install_released_package; then
        echo "::notice::No st2 release for ${ID} ${VERSION_ID} in packagecloud.io/StackStorm/${ST2_REPO}; upgrade test skipped."
        remove_released_repository
        return 0
    fi
    remove_released_repository
    configure_st2
    start_st2

    local old_version exec_id
    old_version="$(st2_version)"
    heading "Creating state with st2 ${old_version}"
    exec_id="$(run_action core.local cmd='echo before-upgrade')"
    st2 key set e2e_plain kept-across-upgrade >/dev/null
    st2 key set e2e_secret secret-across-upgrade --encrypt >/dev/null
    st2 pack install hubot

    heading "Upgrading st2 ${old_version} to the built package"
    if [ "$(platform)" = deb ]; then
        # Keep the modified st2.conf instead of prompting.
        apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            "$(ls -1 "$ARTIFACT_DIR"/st2_*.deb | head -n1)"
    else
        dnf -y install "$(ls -1 "$ARTIFACT_DIR"/st2-[0-9]*.rpm | head -n1)"
    fi
    start_st2

    heading "Checking st2 after the upgrade"
    check_equal "st2 version" "$(built_version)" "$(st2_version)"
    check_equal "execution from ${old_version}" succeeded "$(st2 execution get "$exec_id" -j | json_field status)"
    check_equal "datastore value" kept-across-upgrade "$(st2 key get e2e_plain -j | json_field value)"
    check_equal "encrypted datastore value" secret-across-upgrade "$(st2 key get e2e_secret --decrypt -j | json_field value)"
    check_equal "installed pack" hubot "$(st2 pack get hubot -j | json_field name)"
    run_action core.local cmd='echo after-upgrade' >/dev/null && echo "OK: local runner"
    run_action core.remote hosts=localhost cmd=hostname >/dev/null && echo "OK: remote runner (SSH)"
    run_action packs.list >/dev/null && echo "OK: python runner"
    # packs.install is an Orquesta workflow; reinstalling rebuilds the pack virtualenv.
    st2 pack install hubot && echo "OK: pack install (Orquesta)"
}

# Print the functions of the install script for this distribution without its main
# section, so that they can be run one by one. The os-release variables are loaded with a
# stricter pattern than the script's own, which fails on os-release files with blank lines.
# There is no el10 script: use the el9 one with the nginx repository for this EL version.
install_script_functions() {
    local script=st2bootstrap-deb.sh
    [ "$(platform)" = rpm ] && script=st2bootstrap-el9.sh
    sed -n 's/^\([A-Z_]\+=\)/OS_\1/p' /etc/os-release
    sed -e '/^set -e -u +x$/d' \
        -e '/^source <(sed .*\/etc\/os-release)$/d' \
        -e '/^trap .fail. EXIT/,$d' \
        -e "s#/packages/mainline/rhel/9/#/packages/mainline/rhel/${VERSION_ID%%.*}/#" \
        "$SCRIPTS_DIR/$script"
}

install_nginx() {
    heading "Installing nginx with the install script functions"
    test -f /usr/share/doc/st2/conf/nginx/st2.conf
    # nginx_install needs openssl for the self-signed certificate and, on deb, gnupg for the
    # repository key (both installed earlier by the install script).
    local prereqs='pkg_install openssl'
    [ "$(platform)" = deb ] && prereqs='pkg_meta_update; pkg_install gnupg openssl'
    bash -e <(install_script_functions; printf '%s\n' "$prereqs" nginx_install)
    nginx -v
}

install_st2web() {
    heading "Installing the st2web package from ${ST2WEB_DIR}"
    if [ "$(platform)" = deb ]; then
        apt-get install -y "$(ls -1 "$ST2WEB_DIR"/st2web_*.deb | head -n1)"
        dpkg-query -W st2web
    else
        dnf -y install "$(ls -1 "$ST2WEB_DIR"/st2web-*.rpm | head -n1)"
        rpm -q st2web
    fi
    test -f /opt/stackstorm/static/webui/index.html
}

# curl through nginx, which uses the self-signed certificate of the install script.
web_curl() {
    curl -sS -k --max-time 30 "$@"
}

http_code() {
    web_curl -o /dev/null -w '%{http_code}' "$@"
}

# The checks follow what the browser does: load the page and its assets, log in, call the
# API with the token and listen to the stream.
check_webui() {
    local page asset out token exec_id status i stream_pid
    local stream_log=/tmp/st2-e2e-stream.log

    heading "Checking the Web UI through nginx"
    check_equal "HTTP to HTTPS redirect" "308 ${WEB_URL}/" \
        "$(web_curl -o /dev/null -w '%{http_code} %{redirect_url}' http://127.0.0.1/)"
    page="$(web_curl -f "$WEB_URL/")"
    if ! grep -q '<title>StackStorm Web UI</title>' <<<"$page"; then
        echo "FAIL: / is not the st2web index.html" >&2
        return 1
    fi
    echo "OK: index.html"
    for asset in $(grep -oE '(src|href)="[^":]+"' <<<"$page" | cut -d'"' -f2 | sort -u); do
        out="$(web_curl -o /dev/null -w '%{http_code} %{size_download}' "$WEB_URL/$asset")"
        check_equal "GET /$asset" 200 "${out% *}"
        [ "${out#* }" -gt 0 ] || { echo "FAIL: /$asset is empty" >&2; return 1; }
    done

    heading "Checking login and the API through nginx"
    check_equal "login with a wrong password" 401 \
        "$(http_code -X POST -u "${ST2_USER}:wrong-${ST2_PASSWORD}" "$WEB_URL/auth/v1/tokens")"
    token="$(web_curl -f -X POST -u "${ST2_USER}:${ST2_PASSWORD}" "$WEB_URL/auth/v1/tokens" | json_field token)"
    echo "OK: login"
    check_equal "API without a token" 401 "$(http_code "$WEB_URL/api/v1/actions")"
    for i in actions packs rules runnertypes triggertypes executions; do
        check_equal "GET /api/v1/$i" 200 "$(http_code -H "X-Auth-Token: $token" "$WEB_URL/api/v1/$i?limit=5")"
    done
    out="$(web_curl -f -H "X-Auth-Token: $token" "$WEB_URL/api/v1/actions?pack=core" | json_length)"
    [ "$out" -gt 0 ] || { echo "FAIL: no core actions listed" >&2; return 1; }
    echo "OK: core actions listed ($out)"

    heading "Running an action through nginx and listening to the stream"
    web_curl -N --max-time 120 "$WEB_URL/stream/v1/stream?x-auth-token=$token" >"$stream_log" &
    stream_pid=$!
    sleep 3
    exec_id="$(web_curl -f -X POST -H "X-Auth-Token: $token" -H 'Content-Type: application/json' \
        -d '{"action": "core.local", "parameters": {"cmd": "echo st2web-e2e"}}' \
        "$WEB_URL/api/v1/executions" | json_field id)"
    for i in $(seq 1 60); do
        out="$(web_curl -f -H "X-Auth-Token: $token" "$WEB_URL/api/v1/executions/$exec_id")"
        status="$(json_field status <<<"$out")"
        case "$status" in requested | scheduled | running | delayed) sleep 2 ;; *) break ;; esac
    done
    check_equal "execution status" succeeded "$status"
    check_equal "execution output" st2web-e2e "$(json_field result stdout <<<"$out")"
    sleep 3
    kill "$stream_pid" 2>/dev/null || true
    wait "$stream_pid" || true
    if ! grep -q '^event: st2\.execution' "$stream_log" || ! grep -q "$exec_id" "$stream_log"; then
        echo "FAIL: no stream event for execution $exec_id" >&2
        head -c 2000 "$stream_log" >&2
        return 1
    fi
    echo "OK: stream events for execution $exec_id"
}

test_webui() {
    # st2 is still running from the self-check; the password of that run is not kept.
    set_password
    st2ctl restart-component st2auth
    login
    install_nginx
    install_st2web
    check_webui
}

trap on_error ERR

case "$1" in
    self-check) test_self_check ;;
    webui) test_webui ;;
    upgrade) test_upgrade ;;
    *) echo "usage: $0 self-check | webui | upgrade" >&2; exit 2 ;;
esac
