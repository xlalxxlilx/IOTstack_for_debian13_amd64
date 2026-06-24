#!/usr/bin/env bash
# Debian 13 amd64 adaptation of the upstream IOTstack menu

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CURRENT_BRANCH=$(git name-rev --name-only HEAD 2>/dev/null || echo "master")

REQ_DOCKER_VERSION=24.0.0
REQ_PYTHON_VERSION=3.9.0

PYTHON_CMD=python3
ENCODING_TYPE=""

command_exists() {
    command -v "$@" >/dev/null 2>&1
}

minimum_version_check() {
    local REQ_MAJOR REQ_MINOR REQ_BUILD
    REQ_MAJOR=$(echo "$1" | cut -d'.' -f1)
    REQ_MINOR=$(echo "$1" | cut -d'.' -f2)
    REQ_BUILD=$(echo "$1" | cut -d'.' -f3)

    local CUR_MAJOR="$2" CUR_MINOR="$3" CUR_BUILD="$4"
    local NUMB_REG='^[0-9]+$'

    for v in "$CUR_MAJOR" "$CUR_MINOR" "$CUR_BUILD" ; do
        if ! [[ "$v" =~ $NUMB_REG ]] ; then
            echo "Unknown"
            return 1
        fi
    done

    if [ "$CUR_MAJOR" -gt "$REQ_MAJOR" ] ; then
        echo "true"
        return 0
    elif [ "$CUR_MAJOR" -lt "$REQ_MAJOR" ] ; then
        echo "false"
        return 1
    fi

    if [ "$CUR_MINOR" -gt "$REQ_MINOR" ] ; then
        echo "true"
        return 0
    elif [ "$CUR_MINOR" -lt "$REQ_MINOR" ] ; then
        echo "false"
        return 1
    fi

    if [ "$CUR_BUILD" -ge "$REQ_BUILD" ] ; then
        echo "true"
        return 0
    fi

    echo "false"
    return 1
}

check_git_updates() {
    local UPSTREAM="${1:-@{u}}"
    local LOCAL REMOTE BASE
    LOCAL=$(git rev-parse @ 2>/dev/null) || { echo "Unknown" ; return ; }
    REMOTE=$(git rev-parse "$UPSTREAM" 2>/dev/null) || { echo "Unknown" ; return ; }
    BASE=$(git merge-base @ "$UPSTREAM" 2>/dev/null) || { echo "Unknown" ; return ; }

    if [ "$LOCAL" = "$REMOTE" ] ; then
        echo "Up-to-date"
    elif [ "$LOCAL" = "$BASE" ] ; then
        echo "Need to pull"
    elif [ "$REMOTE" = "$BASE" ] ; then
        echo "Need to push"
    else
        echo "Diverged"
    fi
}

install_docker() {
    echo "Installing Docker using the official convenience script from https://get.docker.com ..."
    curl -fsSL https://get.docker.com | sudo sh
}

update_docker() {
    echo "Updating Docker using apt ..."
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

update_project() {
    git pull origin "$CURRENT_BRANCH"
    git status
}

install_python3_and_deps() {
    local CURR_PYTHON_VER="${1:-Unknown}"
    local CURR_VIRTUALENV="${2:-Unknown}"
    if whiptail \
            --title "Python 3 and virtualenv" \
            --yesno "Python ${REQ_PYTHON_VERSION} or later (Current = ${CURR_PYTHON_VER}) and virtualenv (Installed = ${CURR_VIRTUALENV}) are required for IOTstack. Install/update now?" \
            20 78 ; then
        sudo apt update
        sudo apt install -y python3-dev python3-virtualenv
    fi
}

should_add_user_to_group() {
    grep -q "^$1:" /etc/group || return 1
    groups | grep -q "\\b$1\\b" && return 1
    return 0
}

do_required_groups_checks() {
    local DESIRED_GROUPS="docker bluetooth dialout"
    local LOGOUT_REQUIRED=false
    local GROUP
    for GROUP in $DESIRED_GROUPS ; do
        if should_add_user_to_group "$GROUP" ; then
            echo "Adding $USER to group $GROUP" >&2
            sudo /usr/sbin/usermod -G "$GROUP" -a "$USER"
            LOGOUT_REQUIRED=true
        fi
    done
    if [ "$LOGOUT_REQUIRED" = "true" ] ; then
        echo "You will need to log out and log back in for group changes to take effect."
    fi
}

do_python3_checks() {
    VIRTUALENV_GOOD="false"
    if command_exists virtualenv ; then
        VIRTUALENV_GOOD="true"
        echo "Python virtualenv found." >&2
    fi

    PYTHON_VERSION_GOOD="false"
    if command_exists "$PYTHON_CMD" ; then
        local PYTHON_VERSION MAJ MIN BLD
        PYTHON_VERSION=$($PYTHON_CMD --version 2>/dev/null)
        MAJ=$(echo "$PYTHON_VERSION" | cut -d' ' -f2 | cut -d'.' -f1)
        MIN=$(echo "$PYTHON_VERSION" | cut -d' ' -f2 | cut -d'.' -f2)
        BLD=$(echo "$PYTHON_VERSION" | cut -d' ' -f2 | cut -d'.' -f3)

        printf "Python Version: '%s'. " "${PYTHON_VERSION:-Unknown}"
        if [ "$(minimum_version_check "$REQ_PYTHON_VERSION" "$MAJ" "$MIN" "$BLD")" = "true" ] && \
           [ "$VIRTUALENV_GOOD" = "true" ] ; then
            PYTHON_VERSION_GOOD="true"
            echo "Python and virtualenv are up to date." >&2
        else
            echo "Python is outdated or virtualenv is missing." >&2
            install_python3_and_deps "${MAJ}.${MIN}.${BLD}" "$VIRTUALENV_GOOD"
            return 1
        fi
    else
        install_python3_and_deps
        return 1
    fi
}

do_docker_checks() {
    DOCKER_VERSION_GOOD="false"
    if command_exists docker ; then
        local DOCKER_VERSION MAJ MIN BLD
        DOCKER_VERSION=$(docker version -f "{{.Server.Version}}" 2>&1)

        if [[ "$DOCKER_VERSION" == *"Cannot connect to the Docker daemon"* ]] ; then
            echo "Cannot connect to Docker daemon. Is dockerd running?" >&2
            if whiptail --title "Docker" --yesno \
                    "Cannot connect to the Docker daemon.\n\nCheck that dockerd is running.\n\nExit?" \
                    12 78 ; then
                exit 1
            fi
            return 0
        fi

        if [[ "$DOCKER_VERSION" == *"permission denied"* ]] ; then
            echo "Permission denied when querying Docker. Try: ./menu.sh --run-env-setup" >&2
            if whiptail --title "Docker" --yesno \
                    "Permission denied querying Docker.\n\nRe-run with: ./menu.sh --run-env-setup\n\nExit?" \
                    12 78 ; then
                exit 1
            fi
            return 0
        fi

        MAJ=$(echo "$DOCKER_VERSION" | cut -d'.' -f1)
        MIN=$(echo "$DOCKER_VERSION" | cut -d'.' -f2)
        BLD=$(echo "$DOCKER_VERSION" | cut -d'.' -f3 | cut -d'-' -f1 | cut -d'+' -f1)

        if [ "$(minimum_version_check "$REQ_DOCKER_VERSION" "$MAJ" "$MIN" "$BLD")" = "true" ] ; then
            rm -f .docker_outofdate
            DOCKER_VERSION_GOOD="true"
            echo "Docker version ${DOCKER_VERSION} >= ${REQ_DOCKER_VERSION}. OK." >&2
        else
            if [ ! -f .docker_outofdate ] ; then
                if whiptail --title "Docker version" --yesno \
                        "Docker ${DOCKER_VERSION} is older than the required ${REQ_DOCKER_VERSION}.\n\nAttempt to upgrade now?" \
                        12 78 ; then
                    update_docker
                else
                    touch .docker_outofdate
                fi
            fi
        fi
    else
        rm -f .docker_outofdate
        echo "Docker not installed." >&2
        if [ ! -f .docker_notinstalled ] ; then
            if whiptail --title "Docker" --yesno \
                    "Docker is not installed. Install it now using the official get.docker.com script?" \
                    10 78 ; then
                rm -f .docker_notinstalled
                do_required_groups_checks
                install_docker
            else
                touch .docker_notinstalled
            fi
        fi
    fi
}

do_project_checks() {
    echo "Checking for project update ..." >&2
    git fetch origin "$CURRENT_BRANCH" 2>/dev/null

    if [ "$(check_git_updates)" = "Need to pull" ] ; then
        echo "An update is available for IOTstack." >&2
        if [ ! -f .project_outofdate ] ; then
            if whiptail --title "Project update" --yesno \
                    "An update is available for IOTstack.\nYou will not be reminded again until you update.\nUpdate now?" \
                    10 78 ; then
                update_project
            else
                touch .project_outofdate
            fi
        fi
    else
        rm -f .project_outofdate
        echo "Project is up to date." >&2
    fi
}

do_installer_checks() {
    local INSTALLER_SCRIPT="${PWD}/install.sh"
    [ -x "$INSTALLER_SCRIPT" ] || return

    if [ "$("$INSTALLER_SCRIPT" should_run_installer)" = "true" ] ; then
        if whiptail --title "Installer Update" \
                --yesno "The IOTstack installer has been updated. Re-run it now?" \
                7 78 3>&1 1>&2 2>&3 ; then
            "$INSTALLER_SCRIPT"
        fi
    fi
}

SKIP_CHECKS=false

for arg in "$@" ; do
    case "$arg" in
        --no-check) SKIP_CHECKS=true ;;
        --run-env-setup) echo "Setting up environment:" ; do_required_groups_checks ;;
    esac
done

while [ $# -gt 0 ] ; do
    case "$1" in
        --branch) CURRENT_BRANCH="${2:-$(git name-rev --name-only HEAD)}" ; shift ;;
        --encoding) ENCODING_TYPE="$2" ; shift ;;
        --no-check) ;;
        --run-env-setup) ;;
        --*) echo "Unknown option: $1" ;;
    esac
    shift
done

if [ "$SKIP_CHECKS" = "false" ] ; then
    do_project_checks
    do_required_groups_checks
    do_python3_checks
    echo "Please enter your sudo password if prompted."
    do_docker_checks
    do_installer_checks

    if [ "$DOCKER_VERSION_GOOD" = "true" ] && [ "$PYTHON_VERSION_GOOD" = "true" ] ; then
        echo "Project dependencies up to date."
        echo ""
    else
        echo "Project dependencies not up to date. Menu may crash."
        echo "To be prompted to update again, run:"
        echo "  rm -f .docker_notinstalled .docker_outofdate .project_outofdate"
        echo ""
    fi
fi

if [ ! -s .new_install ] ; then
    if [ -f docker-compose.yml ] ; then
        echo "Warning: existing docker-compose.yml found on a first run."
        sleep 1
        if whiptail --title "Existing installation" \
                --yesno "An existing docker-compose.yml was found.\nWe recommend backing up your IOTstack instance before continuing.\n\nContinue?" \
                12 78 ; then
            true
        else
            exit 0
        fi
    fi
    touch .new_install
fi

set -e

if cmp -s requirements-menu.txt .virtualenv-menu/requirements.txt 2>/dev/null ; then
    echo "Using existing python virtualenv for menu."
    source .virtualenv-menu/bin/activate
else
    rm -rf .virtualenv-menu
    echo "Creating python virtualenv for menu ..."
    virtualenv -q --seed pip .virtualenv-menu
    source .virtualenv-menu/bin/activate
    echo "Installing menu requirements into the virtualenv ..."
    pip3 install -q -r requirements-menu.txt
    cp requirements-menu.txt .virtualenv-menu/requirements.txt
fi

$PYTHON_CMD ./scripts/menu_main.py $ENCODING_TYPE
