#!/bin/bash
#
# The Library Script, Speedtest Mod for Pi-hole Helper Functions
#
# shellcheck disable=SC2015
#

declare PKG_MANAGER
PKG_MANAGER=$(command -v apt-get || command -v dnf || command -v yum)
readonly PKG_MANAGER

#######################################
# Get the version of a repository, either from a local clone or from the installed package
# Globals:
#   None
# Arguments:
#   $1: The path to, or name of, the repository
#   $2: Non-empty string to get the hash, empty string to get the tag if it exists
# Returns:
#   The version of the repository
#######################################
getVersion() {
    local found_version=""

    if [[ -d "$1" && -d "$1/.git" ]]; then
        pushd "$1" &>/dev/null || exit 1
        found_version=$(git status --porcelain=2 -b | grep branch.oid | awk '{print $3;}')
        [[ $found_version != *"("* ]] || found_version=$(git rev-parse HEAD 2>/dev/null)

        if [[ -z "${2:-}" ]]; then
            local tags
            local found_tag=$found_version
            tags=$(git ls-remote -t origin || git show-ref --tags)
            ! grep -q "$found_version" <<<"$tags" || found_tag=$(grep "$found_version" <<<"$tags" | awk '{print $2;}' | cut -d '/' -f 3 | sort -V | tail -n1)
            [[ -z "$found_tag" ]] || found_version=$found_tag
        fi

        popd &>/dev/null || exit 1
    elif [[ -x "$(command -v pihole)" ]]; then
        local versions
        versions=$(pihole -v | grep "$1")
        found_version=$(cut -d ' ' -f 6 <<<"$versions")
        [[ "$found_version" == *.* || ${#found_version} -ge 40 ]] || found_version=$(cut -d ' ' -f 7 <<<"$versions")
    fi

    echo "$found_version"
}

#######################################
# Fetch a repository, optionally a specific version
# Globals:
#   None
# Arguments:
#   $1: The path to download the repository to
#   $2: The name of the repository
#   $3: The URL of the repository
#   $4: The desired version, hash or tag, to download (optional, none by default)
#   $5: The branch to download (optional, master by default)
#   $6: Whether to snap to the tag (optional, true by default)
# Outputs:
#   The repository at the desired version
#######################################
download() {
    local path=$1
    local name=$2
    local url=$3
    local desired_version="${4:-}"
    local branch="${5:-master}"
    local snap_to_tag="${6:-true}"
    local dest=$path/$name
    local aborting=false

    [[ ! -d "$dest" || -d "$dest/.git" ]] || mv -f "$dest" "$dest.old"
    [[ -d "$dest" ]] || git clone --depth=1 -b "$branch" "$url" "$dest" -q
    pushd "$dest" &>/dev/null || exit 1
    git config --global --add safe.directory "$dest"

    if [[ -n "$desired_version" && "$desired_version" != *.* ]]; then
        local repos=("Pi-hole" "web" "speedtest")

        for repo in "${repos[@]}"; do
            if [[ "$desired_version" == *"$repo"* ]]; then
                aborting=true
                break
            fi
        done
    fi

    if ! $aborting; then
        ! git remote -v | grep -q "old" && git remote -v | grep -q "origin" && git remote rename origin old || :
        ! git remote -v | grep -q "origin" || git remote remove origin
        git remote add -t "$branch" origin "$url"
    elif git remote -v | grep -q "old"; then
        ! git remote -v | grep -q "origin" || git remote remove origin
        git remote rename old origin
        url=$(git remote get-url origin)
    fi

    [[ "$url" != *"ipitio"* ]] || snap_to_tag=$(grep -q "true" <<<"$snap_to_tag" && echo "false" || echo "true")
    git fetch origin --depth=1 "$branch":refs/remotes/origin/"$branch" -q
    git reset --hard origin/"$branch" -q
    git checkout -B "$branch" -q
    local current_hash
    local tags
    current_hash=$(getVersion "$dest" hash)
    tags=$(git ls-remote -t origin || git show-ref --tags)

    if [[ -z "$desired_version" ]]; then # if empty, get the latest version
        local latest_tag=""
        [[ "$snap_to_tag" != "true" ]] || latest_tag=$(awk -F/ '{print $3}' <<<"$tags" | grep '^v[0-9]' | grep -v '\^{}' | sort -V | tail -n1)
        [[ -n "$latest_tag" ]] && desired_version=$latest_tag || desired_version=$current_hash
    elif $aborting; then
        desired_version=$(getVersion "$desired_version" hash)
    fi

    if [[ "$desired_version" == *.* ]]; then
        grep -q "$desired_version$" <<<"$tags" && desired_version=$(grep "$desired_version$" <<<"$tags" | awk '{print $1;}') || desired_version=$current_hash
    fi

    if [[ "$current_hash" != "$desired_version" ]]; then
        git fetch origin --depth=1 "$desired_version" -q
        git reset --hard "$desired_version" -q
    fi

    popd &>/dev/null || exit 1
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
    if [[ "$PKG_MANAGER" == *"apt"* ]]; then
        # Check if there is a candidate and it is not "(none)"
        apt-cache policy "$1" | grep -q "Candidate:" && ! apt-cache policy "$1" | grep -q "Candidate: (none)" && return 0 || return 1
    elif [[ "$PKG_MANAGER" == *"dnf"* || "$PKG_MANAGER" == *"yum"* ]]; then
        $PKG_MANAGER list available "$1" &>/dev/null && return 0 || return 1
    else
        echo "Unsupported package manager!"
        exit 1
    fi
}

#######################################
# Check if a package is installed, only used below when --continuous is not
# Globals:
#   None
# Arguments:
#   $1: The package to check
# Returns:
#   0 if the package is not installed, 1 if it is
#######################################
notInstalled() {
    if [[ "$PKG_MANAGER" == *"apt"* ]]; then
        dpkg -s "$1" &>/dev/null || return 0
    elif [[ "$PKG_MANAGER" == *"dnf"* || "$PKG_MANAGER" == *"yum"* ]]; then
        rpm -q "$1" &>/dev/null || return 0
    else
        echo "Unsupported package manager!"
        exit 1
    fi

    return 1
}

#######################################
# Set a key-value pair in a configuration file, used below for --reinstall
# Globals:
#   None
# Arguments:
#   $1: The key to set
#   $2: The value to set
#   $3: The configuration file to set the key-value pair in
#   $4: Whether to replace the value if it already exists
# Outputs:
#   The configuration file with the key-value pair set
#######################################
setCnf() {
    grep -q "^$1=" "$3" || echo "$1=$2" >>"$3"
    [[ "${4:-false}" == "true" ]] || sed -i "s|^$1=.*|$1=$2|" "$3"
}

#######################################
# Get a key-value pair from a configuration file, used below for --reinstall
# Globals:
#   None
# Arguments:
#   $1: The configuration file to get the key-value pair from
#   $2: The key to get the value of
#   $3: Non-empty string to get the hash, empty string to get the tag if it exists
# Returns:
#   The value of the key-value pair
#######################################
getCnf() {
    local keydir
    local value
    keydir=$(echo "$2" | sed 's/^mod-//;s/^org-//')
    value=$(grep "^$2=" "$1" | cut -d '=' -f 2)
    [[ -n "$value" ]] || value=$(getVersion "$keydir" "${3:-}")
    echo "$value"
}

#######################################
# Download and install librespeed
# Globals:
#   PKG_MANAGERsetupVars
# Arguments:
#   None
# Returns:
#   0 if the installation was successful, 1 if it was not
#######################################
libreSpeed() {
    echo "Installing librespeed-cli..."
    $PKG_MANAGER remove -y speedtest-cli speedtest >/dev/null 2>&1

    if notInstalled golang; then
        if grep -q "Raspbian" /etc/os-release; then
            if [[ ! -f /etc/apt/sources.list.d/testing.list ]] && ! grep -q "testing" /etc/apt/sources.list; then
                echo "Adding testing repo to sources.list.d"
                echo "deb http://archive.raspbian.org/raspbian/ testing main" >/etc/apt/sources.list.d/testing.list
                printf "Package: *\nPin: release a=testing\nPin-Priority: 50" >/etc/apt/preferences.d/limit-testing
                $PKG_MANAGER update -y &>/dev/null
            fi

            isAvailable golang || $PKG_MANAGER update -y &>/dev/null
            $PKG_MANAGER install -y -t testing golang >/dev/null 2>&1
        else
            [[ $PKG_MANAGER == *"apt"* ]] && ! isAvailable golang && $PKG_MANAGER update -y &>/dev/null || :
            $PKG_MANAGER install -y golang >/dev/null 2>&1
        fi
    fi

    download /etc/pihole librespeed https://github.com/librespeed/speedtest-cli
    pushd /etc/pihole/librespeed &>/dev/null || return 1
    [[ ! -d out ]] || rm -rf out
    ./build.sh
    rm -f /usr/bin/speedtest
    mv -f out/* /usr/bin/speedtest
    popd &>/dev/null || return 1
    chmod +x /usr/bin/speedtest

    if [[ -x /usr/bin/speedtest ]]; then
        echo "Installed librespeed-cli"
        return 0
    fi

    echo "Installation of $candidate Failed!"
    return 1
}

#######################################
# Install a package, removing a conflicting package if necessary
# Globals:
#   PKG_MANAGER
# Arguments:
#   None
# Outputs:
#   The installed package
#######################################
swivelSpeed() {
    local candidate="${1:-speedtest-cli}"
    local target="${2:-speedtest}"
    [[ ! -f /usr/bin/speedtest ]] || rm -f /usr/bin/speedtest
    echo "Installing $candidate..."

    case "$PKG_MANAGER" in
    /usr/bin/apt-get)
        ! isAvailable "$candidate" && echo "And Updating Package Cache..." && $PKG_MANAGER update -y &>/dev/null || :
        "$PKG_MANAGER" install -y "$candidate" "$target"- &>/dev/null
        ;;
    /usr/bin/dnf) "$PKG_MANAGER" install -y --allowerasing "$candidate" &>/dev/null ;;
    /usr/bin/yum) "$PKG_MANAGER" install -y --allowerasing "$candidate" &>/dev/null ;;
    esac

    if ! notInstalled "$candidate" && [[ -x /usr/bin/speedtest ]]; then
        printf "Installed "
        local version=
        version=$(/usr/bin/speedtest --version) || return 1
        echo "${version%%$'\n'*}"
        return 0
    fi

    echo "Installation of $candidate Failed!"
    return 1
}

#######################################
# Add the Ookla speedtest CLI source and install the package
# Globals:
#   PKG_MANAGER
# Arguments:
#   None
# Outputs:
#   The source for the speedtest CLI and the package
#######################################
ooklaSpeed() {
    if [[ "$PKG_MANAGER" == *"yum"* || "$PKG_MANAGER" == *"dnf"* && ! -f /etc/yum.repos.d/ookla_speedtest-cli.repo ]]; then
        echo "Adding speedtest source for RPM..."
        curl -sSLN https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | sudo bash
    elif [[ "$PKG_MANAGER" == *"apt"* && ! -f /etc/apt/sources.list.d/ookla_speedtest-cli.list ]]; then
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
            os=$os dist=$dist /tmp/script.deb.sh >/dev/null 2>&1
            rm -f /tmp/script.deb.sh
        else
            curl -sSLN https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash >/dev/null 2>&1
        fi

        sed -i 's/g]/g allow-insecure=yes trusted=yes]/' /etc/apt/sources.list.d/ookla_speedtest-cli.list
        apt-get update -y &>/dev/null
    fi

    swivelSpeed speedtest speedtest-cli
}

#######################################
# Use an interval to generate a systemd calendar
# Globals:
#   None
# Arguments:
#   $1: The interval in hours, down to the minute
# Outputs:
#   The systemd unit and timer files
#######################################
generate_systemd_service() {
    local interval_hours="$1"
    local freq_entries=()
    local total_seconds
    total_seconds=$(echo "$interval_hours * 3600" | bc)

    if (($(echo "$total_seconds < 60" | bc -l))); then # less than a minute
        total_seconds=60
        addOrEditKeyValPair "/etc/pihole/setupVars.conf" "SPEEDTESTSCHEDULE" "0.017"
    fi

    if (($(echo "$total_seconds >= 60 && $total_seconds < 3600" | bc -l))); then # less than an hour
        local minute_interval
        minute_interval=$(echo "$total_seconds / 60" | bc)
        freq_entries+=("*-*-* *:00/$minute_interval:00")
    elif (($(echo "$total_seconds == 3600" | bc -l))); then # exactly an hour
        freq_entries+=("*-*-* *:00:00")
    elif (($(echo "$total_seconds < 86400" | bc -l))); then                  # less than a day
        if (($(awk "BEGIN {print ($total_seconds / 3600) % 1}") == 0)); then # divides evenly into an hour
            local hour_interval
            hour_interval=$(echo "$total_seconds / 3600" | bc)
            freq_entries+=("*-*-* 00/$hour_interval:00:00")
        else # does not divide evenly into an hour
            local current_second=0

            while (($(echo "$current_second < 86400" | bc -l))); do
                local hour
                hour=$(echo "$current_second / 3600" | bc)
                local minute
                minute=$(awk "BEGIN {print ($current_second % 3600) / 60}")
                hour=${hour%.*}
                minute=${minute%.*}
                freq_entries+=("*-*-* $(printf "%02d:%02d:00" "$hour" "$minute")")
                current_second=$(echo "$current_second + $total_seconds" | bc)
            done
        fi
    else # more than a day
        local full_days
        local remaining_hours
        full_days=$(echo "$interval_hours / 24" | bc)
        remaining_hours=$(echo "$interval_hours - ($full_days * 24)" | bc)

        if (($(echo "$full_days > 0" | bc -l))); then
            freq_entries+=("*-*-1/$(printf "%02.0f" "$full_days")")
        fi

        if (($(echo "$remaining_hours > 0" | bc -l))); then # partial day
            local remaining_minutes
            remaining_minutes=$(echo "($remaining_hours - ($remaining_hours / 1)) * 60" | bc)
            remaining_hours=${remaining_hours%.*}
            remaining_minutes=${remaining_minutes%.*}
            freq_entries+=("*-*-* $(printf "%02d:%02d:00" "$remaining_hours" "$remaining_minutes")")
        fi
    fi

    sudo bash -c 'cat > /etc/systemd/system/pihole-speedtest.service << EOF
[Unit]
Description=Pi-hole Speedtest
After=network.target

[Service]
User=root
Type=forking
ExecStart=/usr/local/bin/pihole -a -sn

[Install]
WantedBy=multi-user.target
EOF'
    sudo bash -c 'cat > /etc/systemd/system/pihole-speedtest.timer << EOF
[Unit]
Description=Pi-hole Speedtest Timer

[Install]
WantedBy=timers.target

[Timer]
Persistent=true
EOF'

    for freq in "${freq_entries[@]}"; do
        sudo bash -c "echo 'OnCalendar=$freq' >> /etc/systemd/system/pihole-speedtest.timer"
    done

    systemctl daemon-reload
    systemctl reenable pihole-speedtest.timer &>/dev/null
    systemctl restart pihole-speedtest.timer
}

#######################################
# Save the interval to a file that is run by cron every minute
# Globals:
#   None
# Arguments:
#   $1: The interval in hours
# Outputs:
#   The interval in a file and the cron job
#######################################
generate_cron_job() {
    local total_seconds="nan"
    local schedule_script="/opt/pihole/speedtestmod/schedule_check.sh"

    if [[ "$1" != "nan" ]] && [[ "$1" =~ ^([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]] && (($(echo "$1 > 0" | bc -l))); then
        total_seconds=$(echo "$1 * 3600" | bc)
        if (($(echo "$total_seconds < 60" | bc -l))); then
            total_seconds=60
        fi

        local remainder
        remainder=$(awk "BEGIN {print $total_seconds % 60}")

        if (($(echo "$remainder < 30" | bc -l))); then
            total_seconds=$(echo "$total_seconds - $remainder" | bc -l)
        else
            total_seconds=$(echo "$total_seconds + (60 - $remainder)" | bc -l)
        fi

        addOrEditKeyValPair "/etc/pihole/setupVars.conf" "SPEEDTESTSCHEDULE" "$(echo "scale=3; $total_seconds / 3600" | bc)"
    fi

    [ -d /opt/pihole/speedtestmod ] || return
    sudo bash -c "cat > $(printf %q "$schedule_script")" <<EOF
#!/bin/bash
#
# The Cron Script, Speedtest Mod for Pi-hole Job Scheduler
# Don't run this script manually; it's called by cron
#

declare -r LAST_RUN_FILE="/etc/pihole/last_speedtest"
declare -r INTERVAL_SECONDS=$total_seconds
declare schedule
declare current_time
schedule=\$(grep "SPEEDTESTSCHEDULE" "/etc/pihole/setupVars.conf" | cut -f2 -d"=")
current_time=\$(date +%s)

# if schedule is set and interval is "nan", set the speedtest interval to the schedule
if [[ "\$INTERVAL_SECONDS" == "nan" ]]; then
    [[ ! "\${schedule:-}" =~ ^([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]] || /usr/local/bin/pihole -a -s "\$schedule"
    exit 0
fi

(( \$(echo "\$INTERVAL_SECONDS > 0" | bc -l) )) || exit 0

if [[ -f "\$LAST_RUN_FILE" ]]; then
    declare last_run
    last_run=\$(<"\$LAST_RUN_FILE")
    current_time=\$(date +%s)
    (( \$(echo "\$current_time - \$last_run >= \$INTERVAL_SECONDS" | bc -l) )) || exit 0
fi

[[ \$(/usr/bin/tmux list-sessions 2>/dev/null | grep -c pimodtest) -eq 0 ]] || exit 0
echo "\$current_time" > "\$LAST_RUN_FILE"
/usr/bin/tmux new-session -d -s pimodtest "sudo bash /opt/pihole/speedtestmod/speedtest.sh"
EOF
    sudo chmod +x "$schedule_script"

    crontab -l 2>/dev/null | grep -v "$schedule_script" | crontab -

    if [[ "$total_seconds" == "nan" ]] || (($(echo "$total_seconds > 0" | bc -l))); then
        crontab -l &>/dev/null || crontab -l 2>/dev/null | {
            cat
            echo ""
        } | crontab -
        (
            crontab -l
            echo "* * * * * /bin/bash $schedule_script"
        ) | crontab -
    fi
}
