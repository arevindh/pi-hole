#!/bin/bash
aborted=0

download() {
    local path=$1
    local name=$2
    local url=$3
    local localVersion=${4:-}
    local branch="${5:-master}"
    local dest=$path/$name

    [ -d "$dest" ] && [ ! -d "$dest/.git" ] && mv -f "$dest" "$dest.old" || :
    [ -d "$dest" ] || git clone --depth=1 -b "$branch" "$url" "$dest" -q
    cd "$dest"
    git config --global --add safe.directory "$dest"

    if [ "$aborted" == "0" ]; then
        git remote -v | grep -q "old" || git remote rename origin old
        git remote -v | grep -q "origin" && git remote remove origin
        git remote add -t "$branch" origin "$url"
    elif [ -d .git/refs/remotes/old ]; then
        git remote remove origin
        git remote rename old origin
        url=$(git remote get-url origin)
    fi

    local tags=$(git ls-remote --tags "$url" | awk -F/ '{print $3}' | grep '^v[0-9]' | grep -v '\^{}' | sort -V)
    local latestTag=$(tail -n1 <<<"$tags")
    local localTag=$latestTag

    if [[ "$localVersion" == *.* ]]; then
        latestTag=$localVersion
        localTag=$latestTag
    elif [ ! -z "$localVersion" ]; then
        localTag=$(pihole -v | grep "$localVersion" | cut -d ' ' -f 6)
        [ "$localTag" != "HEAD" ] || localTag=$(pihole -v | grep "$localVersion" | cut -d ' ' -f 7)
    fi

    git fetch origin --depth=1 $branch:refs/remotes/origin/$branch -q
    git reset --hard origin/"$branch" -q
    git checkout -B "$branch" -q
    [ "$aborted" == "0" ] && { [[ "$url" != *"arevindh"* ]] && [[ "$url" != *"ipitio"* ]] && ! git remote -v | grep -q "old.*ipitio" && [[ "$localTag" < "$latestTag" ]] && latestTag=$(awk -v lv="$localTag" '$1 <= lv' <<<"$tags" | tail -n1) || :; } || latestTag=$localTag
    [ "$branch" == "master" ] && [[ "$url" != *"ipitio"* ]] && [ "$(git rev-parse HEAD)" != "$(git rev-parse $latestTag 2>/dev/null)" ] && git fetch origin tag $latestTag --depth=1 -q && git -c advice.detachedHead=false checkout "$latestTag" -q || :
    cd ..
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

# allow to source the above helper functions without running the whole script
if [[ "${SKIP_MOD:-}" != true ]]; then
    html_dir=/var/www/html
    core_dir=/etc/.pihole
    opt_dir=/opt/pihole
    etc_dir=/etc/pihole
    curr_wp=$opt_dir/webpage.sh
    curr_db=$etc_dir/speedtest.db
    last_db=$curr_db.old
    db_table="speedtest"
    st_ver=$db_table

    help() {
        echo "(Re)install Latest Speedtest Mod."
        echo "Usage: sudo $0 [up] [un] [db]"
        echo "up - update the mod (and Pi-hole if not in Docker)"
        echo "un - remove the mod (and any database backups)"
        echo "db - flush the database (if it's not empty, otherwise restore it)"
        echo "If no option is specified, the latest version of the Mod will be (re)installed."
    }

    isEmpty() {
        db=$1
        [ -f $db ] && sqlite3 "$db" "select * from $db_table limit 1;" &>/dev/null && [ ! -z "$(sqlite3 "$db" "select * from $db_table limit 1;")" ] && return 1 || return 0
    }

    swapScripts() {
        SKIP_INSTALL=true
        set +u
        source "$core_dir/automated install/basic-install.sh"
        installScripts
        set -u
    }

    abort() {
        echo "Process Aborting..."
        aborted=1

        if [ -d $core_dir/.git/refs/remotes/old ]; then
            download /etc .pihole "" Pi-hole
            swapScripts

            if [ -d $core_dir/advanced/Scripts/speedtestmod ]; then
                \cp -af $core_dir/advanced/Scripts/speedtestmod/. $opt_dir/speedtestmod/
                pihole -a -s
            fi
        fi

        [ -d $etc_dir/speedtest ] && [ -d $etc_dir/speedtest/.git/refs/remotes/old ] && download $etc_dir speedtest "" $st_ver || :
        [ ! -d $html_dir/admin/.git/refs/remotes/old ] || download $html_dir admin "" web
        [ -f $curr_wp ] && ! cat $curr_wp | grep -q SpeedTest && purge || :
        [ -f $last_db ] && [ ! -f $curr_db ] && mv $last_db $curr_db || :
        printf "Please try again before reporting an issue.\n\n$(date)\n"
    }

    commit() {
        for dir in $core_dir $html_dir/admin $etc_dir/speedtest; do
            [ ! -d $dir ] && continue || cd $dir
            ! git remote -v | grep -q "old" || git remote remove old
            git clean -ffdx
        done
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

        set -Eeuo pipefail
        trap '[ "$?" -eq "0" ] && commit || abort' EXIT
        trap 'abort' INT TERM
        shopt -s dotglob

        local up=false
        local un=false
        local db=false

        for arg in "$@"; do
            case $arg in
            up) up=true ;;
            un) un=true ;;
            db) db=true ;;
            esac
        done

        if $db; then
            if [ -f $curr_db ] && ! isEmpty $curr_db; then
                echo "Flushing Database..."
                mv -f $curr_db $last_db
                [ ! -f $etc_dir/last_speedtest ] || mv -f $etc_dir/last_speedtest $etc_dir/last_speedtest.old

                if [ -f /var/log/pihole/speedtest.log ]; then
                    mv -f /var/log/pihole/speedtest.log /var/log/pihole/speedtest.log.old
                    rm -f $etc_dir/speedtest.log
                fi
            elif [ -f $last_db ]; then
                echo "Restoring Database..."
                mv -f $last_db $curr_db
                [ ! -f $etc_dir/last_speedtest.old ] || mv -f $etc_dir/last_speedtest.old $etc_dir/last_speedtest

                if [ -f /var/log/pihole/speedtest.log.old ]; then
                    mv -f /var/log/pihole/speedtest.log.old /var/log/pihole/speedtest.log
                    \cp -af /var/log/pihole/speedtest.log $etc_dir/speedtest.log
                fi
            fi
        fi

        if $up || $un || [ "$#" -eq 0 ]; then
            local working_dir=$(pwd)
            cd ~

            if [ -f $curr_wp ] && cat $curr_wp | grep -q SpeedTest; then
                echo "Restoring Pi-hole..."
                pihole -a -s -1

                if $un && [ -d $html_dir/admin.bak ]; then
                    [ -e $html_dir/admin ] && rm -rf $html_dir/admin
                    mv -f $html_dir/admin.bak $html_dir/admin
                else
                    download $html_dir admin https://github.com/pi-hole/AdminLTE web
                fi

                if $un && [ -d $core_dir.bak ]; then
                    [ -e $core_dir ] && rm -rf $core_dir
                    mv -f $core_dir.bak $core_dir
                else
                    download /etc .pihole https://github.com/pi-hole/pi-hole Pi-hole
                fi

                [ ! -d $etc_dir/speedtest ] || rm -rf $etc_dir/speedtest
                st_ver=$(pihole -v -s | cut -d ' ' -f 6)
                [ "$st_ver" != "HEAD" ] || st_ver=$(pihole -v -s | cut -d ' ' -f 7)
                swapScripts
            fi

            if $up; then
                if [ -d /run/systemd/system ]; then
                    echo "Updating Pi-hole..."
                    PIHOLE_SKIP_OS_CHECK=true sudo -E pihole -up
                else
                    echo "Systemd not found. Skipping Pi-hole update..."
                fi
            fi

            if $un; then
                if [ -f /etc/systemd/system/pihole-speedtest.timer ]; then
                    rm -f /etc/systemd/system/pihole-speedtest.service
                    rm -f /etc/systemd/system/pihole-speedtest.timer
                    systemctl daemon-reload
                fi

                rm -rf $opt_dir/speedtestmod
                rm -f "$curr_db".*
                rm -f $etc_dir/last_speedtest.*
                ! isEmpty $curr_db || rm -f $curr_db
            else
                if [ ! -f /usr/local/bin/pihole ]; then
                    echo "Installing Pi-hole..."
                    curl -sSL https://install.pi-hole.net | sudo bash
                fi

                echo "Installing Mod..."
                local PHP_VERSION=$(php -v | head -n 1 | awk '{print $2}' | cut -d "." -f 1,2)
                local PKG_MANAGER=$(command -v apt-get || command -v dnf || command -v yum)
                local PKGS=(bc sqlite3 jq tmux wget "php$PHP_VERSION-sqlite3")
                local missingPkgs=()

                for pkg in "${PKGS[@]}"; do
                    ! notInstalled "$pkg" || missingPkgs+=("$pkg")
                done

                if [ ${#missingPkgs[@]} -gt 0 ]; then
                    [[ "$PKG_MANAGER" != *"apt-get"* ]] || apt-get update >/dev/null
                    $PKG_MANAGER install -y "${missingPkgs[@]}" &>/dev/null
                fi

                [ ! -d $core_dir ] || \cp -af $core_dir $core_dir.bak
                [ ! -d $html_dir/admin ] || \cp -af $html_dir/admin $html_dir/admin.bak
                download $etc_dir speedtest https://github.com/arevindh/pihole-speedtest
                touch $etc_dir/speedtest/updated
                download /etc .pihole https://github.com/arevindh/pi-hole Pi-hole
                swapScripts
                \cp -af $core_dir/advanced/Scripts/speedtestmod/. $opt_dir/speedtestmod/
                pihole -a -s
                download $html_dir admin https://github.com/arevindh/AdminLTE web
            fi

            pihole updatechecker
            [ -d $working_dir ] && cd $working_dir
        fi

        exit 0
    }

    rm -f /tmp/pimod.log
    touch /tmp/pimod.log
    main "$@" 2>&1 | tee -a /tmp/pimod.log
    mv -f /tmp/pimod.log /var/log/pihole/mod.log
    exit $aborted
fi
