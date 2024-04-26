#!/bin/bash
#
# The Test Script, Speedtest Mod for Pi-hole Run Supervisor
# Please run this with the --help option for usage information
#
# shellcheck disable=SC2015
#

declare -r OUT_FILE=/tmp/speedtest.log
declare -r CREATE_TABLE="create table if not exists speedtest (
id integer primary key autoincrement,
start_time text,
stop_time text,
from_server text,
from_ip text,
server text,
server_dist real,
server_ping real,
download real,
upload real,
share_url text
);"
declare START
declare PKG_MANAGER
declare SERVER_ID
START=$(date -u --rfc-3339='seconds')
PKG_MANAGER=$(command -v apt-get || command -v dnf || command -v yum)
SERVER_ID=$(grep 'SPEEDTEST_SERVER' "/etc/pihole/setupVars.conf" | cut -d '=' -f2)
readonly START PKG_MANAGER SERVER_ID

# shellcheck disable=SC2034
SKIP_MOD=true
# shellcheck disable=SC1091
source /opt/pihole/speedtestmod/mod.sh

#######################################
# Run the speedtest
# Globals:
#   SERVER_ID
# Arguments:
#   None
# Returns:
#   None
#######################################
speedtest() {
    if grep -q official <<<"$(/usr/bin/speedtest --version)"; then
        [[ -n "${SERVER_ID}" ]] && /usr/bin/speedtest -s "$SERVER_ID" --accept-gdpr --accept-license -f json || /usr/bin/speedtest --accept-gdpr --accept-license -f json
    else
        [[ -n "${SERVER_ID}" ]] && /usr/bin/speedtest --server "$SERVER_ID" --json --share --secure || /usr/bin/speedtest --json --share --secure
    fi
}

#######################################
# Save the results of the speedtest to the database
# Globals:
#   OUT_FILE
#   CREATE_TABLE
# Arguments:
#   $1: Start time
#   $2: Stop time
#   $3: ISP
#   $4: From IP
#   $5: Server
#   $6: Server Distance
#   $7: Server Ping
#   $8: Download
#   $9: Upload
#   $10: Share URL
# Returns:
#   None
#######################################
savetest() {
    local -r start_time=$1
    local -r stop_time=$2
    local -r isp=${3:-"No Internet"}
    local -r from_ip=${4:-"-"}
    local -r server=${5:-"-"}
    local -r server_dist=${6:-0}
    local -r server_ping=${7:-0}
    local -r download=${8:-0}
    local -r upload=${9:-0}
    local -r share_url=${10:-"#"}
    local -r rm_empty='
  def nonempty: . and length > 0 and (type != "object" or . != {}) and (type != "array" or any(.[]; . != ""));
  if type == "array" then map(walk(if type == "object" then with_entries(select(.value | nonempty)) else . end)) else walk(if type == "object" then with_entries(select(.value | nonempty)) else . end) end
'
    local -r temp_file=$(mktemp)
    local -r json_file="/tmp/speedtest_results"
    jq "$rm_empty" "$json_file" >"$temp_file" && mv -f "$temp_file" "$json_file"
    rm -f "$temp_file"
    chmod 644 /tmp/speedtest_results
    mv -f /tmp/speedtest_results /var/log/pihole/speedtest.log
    \cp -af /var/log/pihole/speedtest.log /etc/pihole/speedtest.log
    rm -f "$OUT_FILE"
    sqlite3 /etc/pihole/speedtest.db "$CREATE_TABLE"
    sqlite3 /etc/pihole/speedtest.db "insert into speedtest values (NULL, '${start_time}', '${stop_time}', '${isp}', '${from_ip}', '${server}', ${server_dist}, ${server_ping}, ${download}, ${upload}, '${share_url}');"
    [[ "$isp" == "No Internet" ]] && exit 1 || exit 0
}

#######################################
# Check if the package is available
# Globals:
#   PKG_MANAGER
# Arguments:
#   $1: Package name
# Returns:
#   0 if available, 1 if not
#######################################
isAvailable() {
    if [[ "$PKG_MANAGER" == "/usr/bin/apt-get" ]]; then
        # Check if there is a candidate and it is not "(none)"
        apt-cache policy "$1" | grep -q "Candidate:" && ! apt-cache policy "$1" | grep -q "Candidate: (none)" && return 0 || return 1
    elif [[ "$PKG_MANAGER" == "/usr/bin/dnf" || "$PKG_MANAGER" == "/usr/bin/yum" ]]; then
        $PKG_MANAGER list available "$1" &>/dev/null && return 0 || return 1
    else
        echo "Unsupported package manager!"
        exit 1
    fi
}

#######################################
# Change between two conflicting packages
# Globals:
#   PKG_MANAGER
# Arguments:
#   $1: Package to install
#   $2: Package to remove
# Returns:
#   None
#######################################
swaptest() {
    if isAvailable "$1"; then
        [[ "$PKG_MANAGER" == "/usr/bin/apt-get" ]] && apt-get install -y "$1" "$2"- || { [[ "$PKG_MANAGER" == "/usr/bin/dnf" ]] && dnf install -y --allowerasing "$1" || yum install -y --allowerasing "$1"; }
    fi
}

#######################################
# Check if a package is installed
# Globals:
#   PKG_MANAGER
#   OUT_FILE
# Arguments:
#   $1: The package to check
# Returns:
#   0 if the package is not installed, 1 if it is
#######################################
notInstalled() {
    if [[ "$PKG_MANAGER" == "/usr/bin/apt-get" ]]; then
        dpkg -s "$1" &>/dev/null || return 0
    elif [[ "$PKG_MANAGER" == "/usr/bin/dnf" || "$PKG_MANAGER" == "/usr/bin/yum" ]]; then
        rpm -q "$1" &>/dev/null || return 0
    else
        echo "Unsupported package manager!"
        mv -f "$OUT_FILE" /var/log/pihole/speedtest.log
        exit 1
    fi

    return 1
}

#######################################
# Download and install librespeed
# Globals:
#   PKG_MANAGER
# Arguments:
#   None
# Returns:
#   None
#######################################
librespeed() {
    if notInstalled golang; then
        if grep -q "Raspbian" /etc/os-release; then
            if [[ ! -f /etc/apt/sources.list.d/testing.list ]] && ! grep -q "testing" /etc/apt/sources.list; then
                echo "Adding testing repo to sources.list.d"
                echo "deb http://archive.raspbian.org/raspbian/ testing main" >/etc/apt/sources.list.d/testing.list
                printf "Package: *\nPin: release a=testing\nPin-Priority: 50" >/etc/apt/preferences.d/limit-testing
                $PKG_MANAGER update
            fi

            $PKG_MANAGER install -y -t testing golang
        else
            $PKG_MANAGER install -y golang
        fi
    fi
    download /etc/pihole librespeed https://github.com/librespeed/speedtest-cli
    cd librespeed || exit
    [[ ! -d out ]] || rm -rf out
    ./build.sh
    mv -f out/* /usr/bin/speedtest
    chmod +x /usr/bin/speedtest
}

#######################################
# Add the Ookla speedtest CLI source
# Globals:
#   PKG_MANAGER
# Arguments:
#   None
# Returns:
#   None
#######################################
addSource() {
    if [[ "$PKG_MANAGER" == *"yum"* || "$PKG_MANAGER" == *"dnf"* ]]; then
        if [[ ! -f /etc/yum.repos.d/ookla_speedtest-cli.repo ]]; then
            echo "Adding speedtest source for RPM..."
            curl -sSLN https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | sudo bash
        fi

        yum list speedtest | grep -q "Available Packages" && $PKG_MANAGER install -y speedtest || :
    elif [[ "$PKG_MANAGER" == *"apt-get"* ]]; then
        if [[ ! -f /etc/apt/sources.list.d/ookla_speedtest-cli.list ]]; then
            echo "Adding speedtest source for DEB..."
            if [[ -e /etc/os-release ]]; then
                # shellcheck disable=SC1091
                source /etc/os-release
                local -r base="ubuntu debian"
                local os=${ID}
                local dist=${VERSION_CODENAME}
                # shellcheck disable=SC2076
                if [[ -n "${ID_LIKE:-}" && "${base//\"/}" =~ "${ID_LIKE//\"/}" && "${os}" != "ubuntu" ]]; then
                    os=${ID_LIKE%% *}
                    [[ -z "${UBUNTU_CODENAME:-}" ]] && UBUNTU_CODENAME=$(/usr/bin/lsb_release -cs)
                    dist=${UBUNTU_CODENAME}
                    [[ -z "$dist" ]] && dist=${VERSION_CODENAME}
                fi
                wget -O /tmp/script.deb.sh https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh >/dev/null 2>&1
                chmod +x /tmp/script.deb.sh
                os=$os dist=$dist /tmp/script.deb.sh
                rm -f /tmp/script.deb.sh
            else
                curl -sSLN https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
            fi

            sed -i 's/g]/g allow-insecure=yes trusted=yes]/' /etc/apt/sources.list.d/ookla_speedtest-cli.list
            apt-get update
        fi
    else
        echo "Unsupported package manager!"
        exit 1
    fi
}

#######################################
# Run the speedtest and save the results
# Globals:
#   PKG_MANAGER
#   START
# Arguments:
#   $1: Number of attempts (optional, 3 by default)
#   $2: Current attempt (optional, 0 by default)
# Returns:
#   None
#######################################
run() {
    speedtest | jq . >/tmp/speedtest_results || echo "Attempt ${2:-1} Failed!" >/tmp/speedtest_results
    local -r stop=$(date -u --rfc-3339='seconds')
    if jq -e '.server' /tmp/speedtest_results &>/dev/null; then
        local -r res=$(</tmp/speedtest_results)
        local -r server_id=$(jq -r '.server.id' <<<"$res")
        local -r servers="$(curl 'https://www.speedtest.net/api/js/servers' --compressed -H 'Upgrade-Insecure-Requests: 1' -H 'DNT: 1' -H 'Sec-GPC: 1')"
        local server_dist
        server_dist=$(jq --arg id "$server_id" '.[] | select(.id == $id) | .distance' <<<"$servers")

        if grep -q official <<<"$(/usr/bin/speedtest --version)"; then
            local -r server_name=$(jq -r '.server.name' <<<"$res")
            local -r download=$(jq -r '.download.bandwidth' <<<"$res" | awk '{$1=$1*8/1000/1000; print $1;}' | sed 's/,/./g')
            local -r upload=$(jq -r '.upload.bandwidth' <<<"$res" | awk '{$1=$1*8/1000/1000; print $1;}' | sed 's/,/./g')
            local -r isp=$(jq -r '.isp' <<<"$res")
            local -r from_ip=$(jq -r '.interface.externalIp' <<<"$res")
            local -r server_ping=$(jq -r '.ping.latency' <<<"$res")
            local -r share_url=$(jq -r '.result.url' <<<"$res")
            [[ -n "$server_dist" ]] || server_dist="-1"
        else # speedtest-cli
            local -r server_name=$(jq -r '.server.sponsor' <<<"$res")
            local -r download=$(jq -r '.download' <<<"$res" | awk '{$1=$1/1000/1000; print $1;}' | sed 's/,/./g')
            local -r upload=$(jq -r '.upload' <<<"$res" | awk '{$1=$1/1000/1000; print $1;}' | sed 's/,/./g')
            local -r isp=$(jq -r '.client.isp' <<<"$res")
            local -r from_ip=$(jq -r '.client.ip' <<<"$res")
            local -r server_ping=$(jq -r '.ping' <<<"$res")
            local -r share_url=$(jq -r '.share' <<<"$res")
            [[ -n "$server_dist" ]] || server_dist=$(jq -r '.server.d' <<<"$res")
        fi

        savetest "$START" "$stop" "$isp" "$from_ip" "$server_name" "$server_dist" "$server_ping" "$download" "$upload" "$share_url"
    elif jq -e '.[].server' /tmp/speedtest_results &>/dev/null; then # librespeed
        local -r res=$(</tmp/speedtest_results)
        local -r server_name=$(jq -r '.[].server.name' <<<"$res")
        local -r download=$(jq -r '.[].download' <<<"$res")
        local -r upload=$(jq -r '.[].upload' <<<"$res")
        local -r isp="Unknown"
        local -r from_ip=$(curl -sSL https://ipv4.icanhazip.com)
        local -r server_ping=$(jq -r '.[].ping' <<<"$res")
        local -r share_url=$(jq -r '.[].share' <<<"$res")
        local -r server_dist="-1"
        savetest "$START" "$stop" "$isp" "$from_ip" "$server_name" "$server_dist" "$server_ping" "$download" "$upload" "$share_url"
    elif [[ "${1}" == "${2:-}" || "${1}" -le 1 ]]; then
        echo "Test Failed!" >/tmp/speedtest_results
        savetest "$START" "$stop"
    else
        if notInstalled speedtest && notInstalled speedtest-cli; then
            [[ ! -f /usr/bin/speedtest ]] || rm -f /usr/bin/speedtest
            addSource
            isAvailable speedtest && $PKG_MANAGER install -y speedtest || :
        elif ! notInstalled speedtest; then
            swaptest speedtest-cli speedtest
        else
            $PKG_MANAGER remove -y speedtest-cli
            librespeed
        fi

        run $1 $((${2:-0} + 1))
    fi
}

#######################################
# Display the help message
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
help() {
    echo "Usage: $0 [attempts]"
    echo "  attempts: Number of attempts to run the speedtest, cycling through the packages (default: 3)"
    exit 1
}

#######################################
# Main function
# Globals:
#   PKG_MANAGER
# Arguments:
#   None
# Returns:
#   None
#######################################
main() {
    local -r short_opts=-h
    local -r long_opts=help
    local -r parsed_opts=$(getopt --options ${short_opts} --longoptions ${long_opts} --name "$0" -- "$@")
    local POSITIONAL=()
    local attempts="3"
    eval set -- "${parsed_opts}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help) help ;;
        *) POSITIONAL+=("$1") ;;
        esac
        shift
    done

    set -- "${POSITIONAL[@]}"

    if [[ "$1" != "--" ]]; then
        [[ "$1" =~ ^[0-9]+$ ]] && attempts="$1" || help
    fi

    if [[ $EUID != 0 ]]; then
        sudo "$0" "$@"
        exit $?
    fi

    if [[ ! -f /usr/bin/speedtest ]]; then
        addSource
        isAvailable speedtest && $PKG_MANAGER install -y speedtest || { isAvailable speedtest-cli && $PKG_MANAGER install -y speedtest-cli || librespeed; }
    fi

    echo "Running Test..."
    run $attempts
}

main "$@" >"$OUT_FILE"
