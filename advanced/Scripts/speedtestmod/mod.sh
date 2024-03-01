#!/bin/bash
admin_dir=/var/www/html
core_dir=/etc/.pihole
opt_dir=/opt/pihole
etc_dir=/etc/pihole
curr_wp=$opt_dir/webpage.sh
curr_db=$etc_dir/speedtest.db
last_db=$curr_db.old
db_table="speedtest"

help() {
    echo "(Re)install Latest Speedtest Mod."
    echo "Usage: sudo $0 [up] [un] [db]"
    echo "up - update Pi-hole (along with the Mod)"
    echo "un - remove the mod (including all backups)"
    echo "db - flush database (restore for a short while after)"
    echo "If no option is specified, the latest version of the Mod will be (re)installed."
}

setTags() {
    local path=${1:-}
    local name=${2:-}
    local branch="${3:-master}"

    if [ ! -z "$path" ]; then
        cd "$path"
        git fetch origin $branch:refs/remotes/origin/$branch -q
        git fetch --tags -f -q
        latestTag=$(git describe --tags $(git rev-list --tags --max-count=1))
    fi
    if [ ! -z "$name" ]; then
        localTag=$(pihole -v | grep "$name" | cut -d ' ' -f 6)
        if [ "$localTag" == "HEAD" ]; then
            localTag=$(pihole -v | grep "$name" | cut -d ' ' -f 7)
        fi
    fi
}

download() {
    local path=$1
    local name=$2
    local url=$3
    local src=${4:-}
    local branch="${5:-master}"
    local dest=$path/$name

    if [ ! -d "$dest" ]; then # replicate
        cd "$path"
        rm -rf "$name"
        git clone --depth=1 -b "$branch" "$url" "$name"
        git config --global --add safe.directory "$dest"
        setTags "$name" "${src:-}" "$branch"
        if [ ! -z "$src" ]; then
            if [[ "$localTag" == *.* ]] && [[ "$localTag" < "$latestTag" ]]; then
                latestTag=$localTag
                git fetch --unshallow
            fi
        fi
    else # replace
        git config --global --add safe.directory "$dest"
        cd "$dest"
        if [ ! -z "$src" ]; then
            if [ "$url" != "old" ]; then
                git remote -v | grep -q "old" || git remote rename origin old
                git remote -v | grep -q "origin" && git remote remove origin
                git remote add -t "$branch" origin "$url"
            elif [ -d .git/refs/remotes/old ]; then
                git remote remove origin
                git remote rename old origin
                git clean -ffdx
            fi
        fi
        setTags "$dest" "${src:-}" "$branch"
        git reset --hard origin/"$branch"
        git checkout -B "$branch"
        if git rev-parse --verify "$branch" >/dev/null 2>&1; then
            git branch -u "origin/$branch" "$branch"
        else
            git checkout --track "origin/$branch"
        fi
    fi

    if [ "$(git rev-parse HEAD)" != "$(git rev-parse $latestTag)" ]; then
        git -c advice.detachedHead=false checkout "$latestTag"
    fi
    cd ..
}

isEmpty() {
    db=$1
    if [ -f $db ]; then
        if ! sqlite3 "$db" "select * from $db_table limit 1;" >/dev/null 2>&1 || [ -z "$(sqlite3 "$db" "select * from $db_table limit 1;")" ]; then
            return 0
        fi
    fi
    return 1
}

manageHistory() {
    if [ "${1:-}" == "db" ]; then
        if [ -f $curr_db ] && ! isEmpty $curr_db; then
            echo "Flushing Database..."
            mv -f $curr_db $last_db
            if [ -f $etc_dir/last_speedtest ]; then
                mv -f $etc_dir/last_speedtest $etc_dir/last_speedtest.old
            fi
            if [ -f /var/log/pihole/speedtest.log ]; then
                mv -f /var/log/pihole/speedtest.log /var/log/pihole/speedtest.log.old
                rm -f $etc_dir/speedtest.log
            fi
        elif [ -f $last_db ]; then
            echo "Restoring Database..."
            mv -f $last_db $curr_db
            if [ -f $etc_dir/last_speedtest.old ]; then
                mv -f $etc_dir/last_speedtest.old $etc_dir/last_speedtest
            fi
            if [ -f /var/log/pihole/speedtest.log.old ]; then
                mv -f /var/log/pihole/speedtest.log.old /var/log/pihole/speedtest.log
                cp -af /var/log/pihole/speedtest.log $etc_dir/speedtest.log
            fi
        fi
    fi
}

notInstalled() {
    if [ -x "$(command -v apt-get)" ]; then
        dpkg -s "$1" &>/dev/null || return 0
    elif [ -x "$(command -v dnf)" ] || [ -x "$(command -v yum)" ]; then
        rpm -q "$1" &>/dev/null || return 0
    else
        echo "Unsupported package manager!"
        exit 1
    fi

    return 1
}

installMod() {
    echo "Installing Mod..."

    if [ ! -f /usr/local/bin/pihole ]; then
        echo "Installing Pi-hole..."
        curl -sSL https://install.pi-hole.net | sudo bash
    fi

    local PHP_VERSION=$(php -v | head -n 1 | awk '{print $2}' | cut -d "." -f 1,2)
    local PKG_MANAGER=$(command -v apt-get || command -v dnf || command -v yum)
    local PKGS=(bc sqlite3 jq tmux wget "php$PHP_VERSION-sqlite3")

    local missingPkgs=()
    for pkg in "${PKGS[@]}"; do
        if notInstalled "$pkg"; then
            missingPkgs+=("$pkg")
        fi
    done

    if [ ${#missingPkgs[@]} -gt 0 ]; then
        if [[ "$PKG_MANAGER" == *"apt-get"* ]]; then
            apt-get update
        fi
        $PKG_MANAGER install -y "${missingPkgs[@]}"
    fi

    download /etc .pihole https://github.com/arevindh/pi-hole Pi-hole
    SKIP_INSTALL=true
    source "$core_dir/automated install/basic-install.sh"
    installScripts
    cp -af $core_dir/advanced/Scripts/speedtestmod/. $opt_dir/speedtestmod/

    download $etc_dir speedtest https://github.com/arevindh/pihole-speedtest
    download $admin_dir admin https://github.com/arevindh/AdminLTE web
    pihole -a -s
    pihole updatechecker
}

uninstall() {
    if [ -f $curr_wp ] && cat $curr_wp | grep -q SpeedTest; then
        echo "Restoring Pi-hole..."

        pihole -a -s -1
        if [ ! -d $core_dir/.git ]; then
            mv -f $core_dir $core_dir.old
        fi
        download /etc .pihole https://github.com/pi-hole/pi-hole Pi-hole
        download $admin_dir admin https://github.com/pi-hole/AdminLTE web

        SKIP_INSTALL=true
        source "$core_dir/automated install/basic-install.sh"
        installScripts
    fi

    manageHistory ${1:-}
}

purge() {
    rm -rf "$admin_dir"/*_admin
    rm -rf $opt_dir/speedtestmod
    rm -rf $etc_dir/speedtest
    rm -rf $etc_dir/mod
    if [ -f /etc/systemd/system/pihole-speedtest.timer ]; then
        rm -f /etc/systemd/system/pihole-speedtest.service
        rm -f /etc/systemd/system/pihole-speedtest.timer
        systemctl daemon-reload
    fi

    rm -f "$curr_wp".*
    rm -f "$curr_db".*
    rm -f "$curr_db"_*
    rm -f $etc_dir/last_speedtest.*
    if isEmpty $curr_db; then
        rm -f $curr_db
    fi

    pihole updatechecker
}

update() {
    if [[ -d /run/systemd/system ]]; then
        echo "Updating Pi-hole..."
        PIHOLE_SKIP_OS_CHECK=true sudo -E pihole -up
    else
        echo "Systemd not found. Skipping Pi-hole update..."
    fi
    if [ "${1:-}" == "un" ]; then
        purge
        exit 0
    fi
}

abort() {
    echo "Process Aborting..."

    if [ -d $admin_dir/admin/.git/refs/remotes/old ]; then
        download $admin_dir admin old web
    fi
    if [ -d $core_dir/.git/refs/remotes/old ]; then
        download /etc .pihole old Pi-hole
        source "$core_dir/automated install/basic-install.sh"
        installScripts
    fi
    if [ ! -f $curr_wp ] || ! cat $curr_wp | grep -q SpeedTest; then
        purge
    fi
    if [ -f $last_db ] && [ ! -f $curr_db ]; then
        mv $last_db $curr_db
    fi

    pihole restartdns
    aborted=1
    printf "Please try again before reporting an issue.\n\n$(date)\n"
}

commit() {
    cd $core_dir
    git remote -v | grep -q "old" && git remote remove old
    cd $admin_dir/admin
    git remote -v | grep -q "old" && git remote remove old
    pihole restartdns
    printf "Done!\n\n$(date)\n"
}

main() {
    printf "Thanks for using Speedtest Mod!\nScript by @ipitio\n\n$(date)\n\n"
    local op=${1:-}
    if [ "$op" == "-h" ] || [ "$op" == "--help" ]; then
        help
        exit 0
    fi
    if [ $EUID != 0 ]; then
        sudo "$0" "$@"
        exit $?
    fi
    set -Eeo pipefail
    trap '[ "$?" -eq "0" ] && commit || abort' EXIT
    trap 'abort' INT TERM
    shopt -s dotglob

    local db=$([ "$op" == "up" ] && echo "${3:-}" || [ "$op" == "un" ] && echo "${2:-}" || echo "$op")
    case $op in
    db)
        manageHistory $db
        ;;
    un)
        uninstall $db
        purge
        ;;
    up)
        uninstall $db
        update ${2:-}
        installMod
        ;;
    *)
        uninstall $db
        installMod
        ;;
    esac
    exit 0
}

aborted=0
rm -f /tmp/pimod.log
touch /tmp/pimod.log
main "$@" 2>&1 | tee -a /tmp/pimod.log
mv -f /tmp/pimod.log /var/log/pihole/mod.log
exit $aborted
