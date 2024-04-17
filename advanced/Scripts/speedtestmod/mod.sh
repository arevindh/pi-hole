#!/bin/bash

getVersion() {
    local foundVersion=""

    if [ -d $1 ]; then
        cd $1
        foundVersion=$(git status --porcelain=2 -b | grep branch.oid | awk '{print $3;}')

        if [ -z "${2:-}" ]; then
            local tags=$(git ls-remote -t origin)
            local foundTag=$foundVersion
            ! grep -q "$foundVersion" <<<"$tags" || foundTag=$(grep "$foundVersion" <<<"$tags" | awk '{print $2;}' | cut -d '/' -f 3 | sort -V | tail -n1)
            [ -z "$foundTag" ] || foundVersion=$foundTag
        fi

        cd - &>/dev/null
    elif [ -x "$(command -v pihole)" ]; then
        local versions=$(pihole -v | grep "$1")
        foundVersion=$(cut -d ' ' -f 6 <<<"$versions")

        if [[ "$foundVersion" != *.* ]]; then
            [ "$foundVersion" != "$(git rev-parse --abbrev-ref HEAD)" ] || foundVersion=$(cut -d ' ' -f 7 <<<"$versions")
        fi
    fi

    echo $foundVersion
}

download() {
    local path=$1
    local name=$2
    local url=$3
    local desiredVersion="${4:-}"
    local branch="${5:-master}"
    local snapToTag="${6:-true}"
    local dest=$path/$name
    local aborting=false

    [ -d "$dest" ] && [ ! -d "$dest/.git" ] && mv -f "$dest" "$dest.old" || :
    [ -d "$dest" ] || git clone --depth=1 -b "$branch" "$url" "$dest" -q
    cd "$dest"
    git config --global --add safe.directory "$dest"

    if [ ! -z "$desiredVersion" ] && [[ "$desiredVersion" != *.* ]]; then
        local repos=("Pi-hole" "web" "speedtest")

        for repo in "${repos[@]}"; do
            if [[ "$desiredVersion" == *"$repo"* ]]; then
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

    [[ "$url" == *"ipitio"* ]] && snapToTag=$(grep -q "true" <<<"$snapToTag" && echo "false" || echo "true")
    git fetch origin --depth=1 $branch:refs/remotes/origin/$branch -q
    git reset --hard origin/"$branch" -q
    git checkout -B "$branch" -q
    local currentHash=$(getVersion "$dest" hash)
    local tags=$(git ls-remote -t origin)

    if [ -z "$desiredVersion" ]; then # if empty, get the latest version
        if [ "$snapToTag" == "true" ]; then
            local latestTag=$(awk -F/ '{print $3}' <<<"$tags" | grep '^v[0-9]' | grep -v '\^{}' | sort -V | tail -n1)
            [ ! -z "$latestTag" ] && desiredVersion=$latestTag || desiredVersion=$currentHash
        fi
    elif $aborting; then
        desiredVersion=$(getVersion "$desiredVersion" hash)
    fi

    if [[ "$desiredVersion" == *.* ]]; then
        grep -q "$desiredVersion$" <<<"$tags" && desiredVersion=$(grep "$desiredVersion$" <<<"$tags" | awk '{print $1;}') || desiredVersion=$currentHash
    fi

    if [ "$currentHash" != "$desiredVersion" ]; then
        git fetch origin --depth=1 $desiredVersion -q
        git reset --hard $desiredVersion -q
    fi

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

setCnf() {
    grep -q "^$1=" $3 || echo "$1=$2" >>$3
    [ "${4:-false}" == "true" ] || sed -i "s|^$1=.*|$1=$2|" $3
}

getCnf() {
    local keydir=$(echo $2 | sed 's/^mod-//;s/^org-//')
    local value=$(grep "^$2=" $1 | cut -d '=' -f 2)
    [ ! -z "$value" ] || value=$(getVersion $keydir "${3:-}")

    if [ ! -z "${3:-}" ] && [[ "$value" == *.* ]]; then
        cd $keydir
        local tags=$(git ls-remote -t origin)
        grep -q "$value$" <<<"$tags" && ver=$(grep "$value$" <<<"$tags" | awk '{print $1;}') || value=$(git rev-parse HEAD)
        cd - &>/dev/null
    fi

    echo $value
}

# allow to source the above helper functions without running the whole script
if [[ "${SKIP_MOD:-}" != true ]]; then
    html_dir=/var/www/html
    core_dir=/etc/.pihole
    opt_dir=/opt/pihole
    etc_dir=/etc/pihole
    mod_dir=/etc/pihole-speedtest
    curr_wp=$opt_dir/webpage.sh
    curr_db=$etc_dir/speedtest.db
    last_db=$curr_db.old
    db_table="speedtest"
    st_ver=""
    mod_core_ver=""
    mod_admin_ver=""
    cleanup=true
    aborted=0

    set +u
    SKIP_INSTALL=true
    source "$core_dir/automated install/basic-install.sh"
    set -u

    help() {
        local helpText=(
            "The Mod Script"
            "Usage: sudo bash /path/to/mod.sh [options]"
            "  or: curl -sSLN //link/to/mod.sh | sudo bash [-s -- options]"
            "(Re)install the latest release of the Speedtest Mod, and/or the following options:"
            ""
            "Options:"
            "  -u, --update,    up      also update Pi-hole, unless Systemd is not being used (ie. not in Docker)"
            "  -b, --backup             preserve stock Pi-hole files for faster offline restore"
            "  -o, --online             force online restore of stock Pi-hole files even if a backup exists"
            "  -i, --install            skip restore of stock Pi-hole*"
            "  -r, --reinstall          keep current version of the mod, if installed*"
            "  -t, --testing            install the latest commit"
            "  -n, --uninstall, un      remove the mod and its files, but keep the database"
            "  -d, --database,  db      flush/restore the database if it's not/empty (and exit if this is the only arg given)"
            "  -v, --version            display the version of the mod"
            "  -x, --verbose            show the commands being run"
            "  -c, --continuous         skip check for missing dependencies"
            "  -h, --help               display this help message"
            ""
            "  *for when not updating Pi-hole nor switching repos"
            ""
            "Examples:"
            "  sudo bash /opt/pihole/speedtestmod/mod.sh -ubo"
            "  sudo bash /opt/pihole/speedtestmod/mod.sh -i -r -d"
            "  sudo bash /opt/pihole/speedtestmod/mod.sh --uninstall"
            "  curl -sSLN https://github.com/arevindh/pi-hole/raw/master/advanced/Scripts/speedtestmod/mod.sh | sudo bash -s -- -u"
        )

        printf "%s\n" "${helpText[@]}"
    }

    isEmpty() {
        [ -f $1 ] && sqlite3 "$1" "select * from $db_table limit 1;" &>/dev/null && [ ! -z "$(sqlite3 "$1" "select * from $db_table limit 1;")" ] && return 1 || return 0
    }

    swapScripts() {
        set +u
        installScripts >/dev/null 2>&1
        set -u
    }

    restore() {
        [ -d $1.bak ] || return 1
        [ ! -e $1 ] || rm -rf $1
        mv -f $1.bak $1
        cd $1
        git tag -l | xargs git tag -d >/dev/null 2>&1
        git fetch --tags -f -q
    }

    purge() {
        if [ -f /etc/systemd/system/pihole-speedtest.timer ]; then
            rm -f /etc/systemd/system/pihole-speedtest.service
            rm -f /etc/systemd/system/pihole-speedtest.timer
            systemctl daemon-reload
        fi

        rm -rf $opt_dir/speedtestmod
        rm -rf $core_dir.bak
        rm -rf $html_dir/admin.bak
        rm -rf $core_dir.mod
        rm -rf $html_dir/admin.mod
        rm -f "$curr_db".*
        rm -f $etc_dir/last_speedtest.*
        ! isEmpty $curr_db || rm -f $curr_db
    }

    abort() {
        if $cleanup; then
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

            [ -d $mod_dir ] && [ -d $mod_dir/.git/refs/remotes/old ] && download /etc pihole-speedtest "" speedtest || :
            [ ! -d $html_dir/admin/.git/refs/remotes/old ] || download $html_dir admin "" web
            [ -f $last_db ] && [ ! -f $curr_db ] && mv $last_db $curr_db || :
            [ -f $curr_wp ] && ! cat $curr_wp | grep -q SpeedTest && purge || :
            printf "Please try again before reporting an issue.\n\n$(date)\n"
        fi
    }

    commit() {
        if $cleanup; then
            for dir in $core_dir $html_dir/admin; do
                [ ! -d $dir ] && continue || cd $dir
                ! git remote -v | grep -q "old" || git remote remove old
                git clean -ffdx
            done
            printf "Done!\n\n$(date)\n"
        fi
    }

    main() {
        set -Eeuo pipefail
        trap 'abort' INT TERM
        shopt -s dotglob

        local update=false
        local backup=false
        local online=false
        local install=false
        local reinstall=false
        local stable=true
        local uninstall=false
        local database=false
        local verbose=false
        local chk_dep=true
        local dashes=0
        local SHORT=-uboirtndvxch
        local LONG=update,backup,online,install,reinstall,testing,uninstall,database,version,verbose,continuous,help
        declare -a EXTRA_ARGS
        declare -a POSITIONAL
        PARSED=$(getopt --options ${SHORT} --longoptions ${LONG} --name "$0" -- "$@")
        eval set -- "${PARSED}"

        while [[ $# -gt 0 ]]; do
            case "$1" in
            -u | --update) update=true ;;
            -b | --backup) backup=true ;;
            -o | --online) online=true ;;
            -i | --install) install=true ;;
            -r | --reinstall) reinstall=true ;;
            -t | --testing) stable=false ;;
            -n | --uninstall) uninstall=true ;;
            -d | --database) database=true ;;
            -v | --version)
                getVersion $mod_dir
                cleanup=false
                exit 0
                ;;
            -x | --verbose) verbose=true ;;
            -c | --continuous) chk_dep=false ;;
            -h | --help)
                help
                cleanup=false
                exit 0
                ;;
            --) dashes=1 ;;
            *) [[ $dashes -eq 0 ]] && POSITIONAL+=("$1") || EXTRA_ARGS+=("$1") ;;
            esac
            shift
        done

        set -- "${POSITIONAL[@]}"

        for arg in "$@"; do
            case $arg in
            up) update=true ;;
            un) uninstall=true ;;
            db) database=true ;;
            *)
                help
                cleanup=false
                exit 0
                ;;
            esac
        done

        trap '[ "$?" -eq "0" ] && commit || abort' EXIT
        printf "Thanks for using Speedtest Mod!\nScript by @ipitio\n\n$(date)\n\n"
        ! $verbose || set -x

        if $database; then
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

        if ! $database || [ "$#" -gt 1 ]; then
            local working_dir=$(pwd)
            cd ~

            if [ -f $curr_wp ] && cat $curr_wp | grep -q SpeedTest; then
                if $reinstall; then
                    for repo in $core_dir $html_dir/admin $mod_dir; do
                        if [ -d $repo ]; then
                            local hashTag=$(getVersion $repo) # if hashes are the same, we may be on an older tag
                            [ "$(getVersion $repo hash)" != "$(getCnf $mod_dir/cnf mod-$repo hash)" ] || hashTag=$(getCnf $mod_dir/cnf mod-$repo)

                            case "$repo" in
                            "$core_dir") mod_core_ver=$hashTag ;;
                            "$html_dir/admin") mod_admin_ver=$hashTag ;;
                            "$mod_dir") st_ver=$hashTag ;;
                            esac
                        fi
                    done
                fi

                if ! $install; then
                    echo "Restoring Pi-hole$($online && echo " online..." || echo "...")"
                    pihole -a -s -1

                    local core_ver=""
                    local admin_ver=""
                    if [ -f $mod_dir/cnf ]; then
                        core_ver=$(getCnf $mod_dir/cnf org-$core_dir)
                        admin_ver=$(getCnf $mod_dir/cnf org-$html_dir/admin)
                    fi

                    ! $online && restore $html_dir/admin || download $html_dir admin https://github.com/pi-hole/AdminLTE "$admin_ver"
                    ! $online && restore $core_dir || download /etc .pihole https://github.com/pi-hole/pi-hole "$core_ver"
                    [ ! -d $mod_dir ] || rm -rf $mod_dir
                    swapScripts
                fi
            fi

            if ! $install && $update; then
                if [ -d /run/systemd/system ]; then
                    echo "Updating Pi-hole..."
                    PIHOLE_SKIP_OS_CHECK=true sudo -E pihole -up
                else
                    echo "Systemd not found. Skipping Pi-hole update..."
                fi
            fi

            if ! $install && $uninstall; then
                echo "Purging Mod..."
                purge
            else
                if $chk_dep; then
                    if [ ! -f /usr/local/bin/pihole ]; then
                        echo "Installing Pi-hole..."
                        curl -sSL https://install.pi-hole.net | sudo bash
                    fi

                    echo "Checking Dependencies..."
                    local PHP_VERSION=$(php -v | head -n 1 | awk '{print $2}' | cut -d "." -f 1,2)
                    local PKG_MANAGER=$(command -v apt-get || command -v dnf || command -v yum)
                    local PKGS=(bc sqlite3 jq tar tmux wget "php$PHP_VERSION-sqlite3")
                    local missingPkgs=()

                    for pkg in "${PKGS[@]}"; do
                        ! notInstalled "$pkg" || missingPkgs+=("$pkg")
                    done

                    if [ ${#missingPkgs[@]} -gt 0 ]; then
                        [[ "$PKG_MANAGER" != *"apt-get"* ]] || apt-get update >/dev/null
                        echo "Installing Missing..."
                        $PKG_MANAGER install -y "${missingPkgs[@]}"
                    fi
                fi

                if $backup; then
                    echo "Backing up Pi-hole..."
                    download /etc .pihole.mod https://github.com/arevindh/pi-hole "$mod_core_ver" master $stable
                    download $html_dir admin.mod https://github.com/arevindh/AdminLTE "$mod_admin_ver" master $stable
                fi

                $reinstall && echo "Reinstalling Mod..." || echo "Installing Mod..."
                download /etc pihole-speedtest https://github.com/arevindh/pihole-speedtest "$st_ver" master $stable
                [ -f $mod_dir/cnf ] || touch $mod_dir/cnf
                setCnf mod-$mod_dir "$(getVersion $mod_dir)" $mod_dir/cnf $reinstall

                for repo in $core_dir $html_dir/admin; do
                    if [ -d $repo ]; then
                        local stockTag=$(getVersion $repo)
                        setCnf org-$repo $stockTag $mod_dir/cnf

                        if $backup; then
                            if [ ! -d $repo.bak ] || [ "$(getVersion $repo.bak)" != "$stockTag" ]; then
                                rm -rf $repo.bak
                                mv -f $repo $repo.bak
                            fi

                            rm -rf $repo
                            mv -f $repo.mod $repo
                        fi
                    fi
                done

                $backup || download /etc .pihole https://github.com/arevindh/pi-hole "$mod_core_ver" master $stable
                swapScripts
                \cp -af $core_dir/advanced/Scripts/speedtestmod/. $opt_dir/speedtestmod/
                pihole -a -s
                $backup || download $html_dir admin https://github.com/arevindh/AdminLTE "$mod_admin_ver" master $stable
                setCnf mod-$core_dir "$(getVersion $core_dir)" $mod_dir/cnf $reinstall
                setCnf mod-$html_dir/admin "$(getVersion $html_dir/admin)" $mod_dir/cnf $reinstall
            fi

            pihole updatechecker
            [ -d $working_dir ] && cd $working_dir
        fi

        exit 0
    }

    if [ $EUID != 0 ]; then
        sudo "$0" "$@"
        exit $?
    fi

    rm -f /tmp/pimod.log
    touch /tmp/pimod.log
    main "$@" 2>&1 | tee -a /tmp/pimod.log
    $cleanup && mv -f /tmp/pimod.log /var/log/pihole/mod.log || rm -f /tmp/pimod.log
    exit $aborted
fi
