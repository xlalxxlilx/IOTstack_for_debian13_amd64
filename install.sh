#!/usr/bin/env bash

# version - keep exactly 7 chars for compatibility with upstream tooling
UPDATE="2026d13"

# The installer should be safe to run repeatedly.
[ "$EUID" -eq 0 ] && echo "This script should NOT be run using sudo" && exit 1

SCRIPT=$(basename "${0}")
WHERE=$(dirname "$(realpath "$0")")

[ -d "$WHERE/.templates" ] && [ -d "$WHERE/docs" ] && PROJECT="$WHERE" || PROJECT="$HOME/IOTstack"
IOTSTACK=${IOTSTACK:-"$PROJECT"}

IOTSTACK_ENV="$IOTSTACK/.env"
IOTSTACK_MENU_REQUIREMENTS="$IOTSTACK/requirements-menu.txt"
IOTSTACK_MENU_VENV_DIR="$IOTSTACK/.virtualenv-menu"
IOTSTACK_INSTALLER_HINT="$IOTSTACK/.new_install"

COMPOSE_PLUGIN_CANDIDATES="/usr/libexec/docker/cli-plugins/docker-compose /usr/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose"
COMPOSE_SYMLINK_PATH="/usr/local/bin/docker-compose"

APT_DEPENDENCIES="ca-certificates curl git jq pwgen python3-pip python3-dev python3-virtualenv rsync sqlite3 uuid-runtime whiptail"

DOCKER_VERSION_MINIMUM="24"
COMPOSE_VERSION_MINIMUM="2.20"
PYTHON_VERSION_MINIMUM="3.9"

DESIRED_GROUPS="docker bluetooth dialout"

REBOOT_REQUIRED=false
LOGOUT_REQUIRED=false

version_json() {
    local commitID
    commitID=$(git -C "${IOTSTACK}" log -n 1 --pretty=format:%H -- "${SCRIPT}" 2>/dev/null)
    echo "{\"version\": \"${UPDATE}\", \"commit\": \"${commitID}\", \"exitCode\": ${1}}"
}

should_run_installer() {
    if [ -s "${IOTSTACK_INSTALLER_HINT}" ] ; then
        if [ "$(cat "${IOTSTACK_INSTALLER_HINT}")" = "$(version_json 0)" ] ; then
            echo "false"
            return
        fi
    fi
    echo "true"
}

if [ $# -gt 0 ] ; then
    case "${1}" in
        "version" )
            echo "$(version_json 0)"
        ;;
        "should_run_installer" )
            echo "$(should_run_installer)"
        ;;
        * )
            cat <<HELP

                Usage:
                  ${SCRIPT} (with no arguments runs the installer)
                  ${SCRIPT} version - returns JSON version string
                  ${SCRIPT} should_run_installer - returns "false" or "true"
                  ${SCRIPT} help - displays this menu

HELP
        ;;
    esac
    exit 0
fi

handle_exit() {
    [ -d "$IOTSTACK" ] && echo "$(version_json $1)" >"$IOTSTACK_INSTALLER_HINT"

    echo -n "${SCRIPT} completed"
    [ "$1" -ne 0 ] && echo -n " - but should be re-run"

    if [ "$REBOOT_REQUIRED" = "true" ] ; then
        echo " - a reboot is required."
        sleep 2
        sudo reboot
    elif [ "$LOGOUT_REQUIRED" = "true" ] ; then
        echo " - a logout is required."
        sleep 2
        for ANCESTOR in $(ps -o ppid=) ; do
            if [ "$(ps -p "$ANCESTOR" -o user= 2>/dev/null)" = "$USER" ] ; then
                kill -HUP "$ANCESTOR" 2>/dev/null
                break
            fi
        done
        sleep 2
    fi

    echo ""
    exit "$1"
}

resolve_compose_plugin_path() {
    local p
    for p in $COMPOSE_PLUGIN_CANDIDATES ; do
        if [ -f "$p" ] ; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

should_add_user_to_group() {
    grep -q "^$1:" /etc/group || return 1
    groups | grep -q "\\b$1\\b" && return 1
    return 0
}

is_python_script() {
    [ "$(file -b "$1" 2>/dev/null | grep -c "^Python script")" -gt 0 ] && return 0
    return 1
}

echo "IOTstack installer (${UPDATE}) for Debian 13 amd64"

echo -e -n "\nChecking operating-system environment - "
if ! command -v apt >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1 ; then
    echo "fail"
    echo "This script requires Debian tooling (apt + dpkg)."
    exit 1
fi

if [ ! -f /etc/os-release ] ; then
    echo "fail"
    echo "Unable to verify OS version because /etc/os-release is missing."
    exit 1
fi

. /etc/os-release
ARCHITECTURE="$(dpkg --print-architecture 2>/dev/null)"

if [ "$ID" != "debian" ] ; then
    echo "fail"
    echo "This installer targets Debian 13 only. Detected ID=$ID."
    exit 1
fi

if [ "${VERSION_ID}" != "13" ] ; then
    echo "fail"
    echo "This installer targets Debian 13 only. Detected VERSION_ID=${VERSION_ID}."
    exit 1
fi

if [ "$ARCHITECTURE" != "amd64" ] ; then
    echo "fail"
    echo "This installer targets amd64 only. Detected architecture=${ARCHITECTURE}."
    exit 1
fi
echo "pass"

echo -e "\nUpdating Advanced Package Tool (apt) caches"
sudo apt update

echo -e "\nInstalling/updating IOTstack dependencies"
sudo apt install -y $APT_DEPENDENCIES

if ! command -v docker >/dev/null 2>&1 ; then
    echo -e "\nInstalling docker and compose plugin from https://get.docker.com ..."
    curl -fsSL https://get.docker.com | sudo sh
    if [ $? -eq 0 ] ; then
        echo -e "\nInstallation of Docker completed normally."
        REBOOT_REQUIRED=true
    else
        echo -e "\nThe Docker convenience script returned an error."
        handle_exit 1
    fi
else
    echo -e -n "\nDocker is already installed - checking your version - "
    DOCKER_VERSION_INSTALLED="$(docker version -f "{{.Server.Version}}" 2>/dev/null)"
    if [ -z "$DOCKER_VERSION_INSTALLED" ] ; then
        echo "fail"
        echo "Unable to read Docker version. Is dockerd running?"
        handle_exit 1
    fi
    if dpkg --compare-versions "$DOCKER_VERSION_MINIMUM" gt "$DOCKER_VERSION_INSTALLED" ; then
        echo "fail"
        echo "Minimum required Docker version: $DOCKER_VERSION_MINIMUM"
        echo "Installed Docker version: $DOCKER_VERSION_INSTALLED"
        handle_exit 1
    fi
    echo "pass"
fi

echo -e -n "\nChecking group memberships"
for GROUP in $DESIRED_GROUPS ; do
    echo -n " - $GROUP "
    if should_add_user_to_group "$GROUP" ; then
        echo -n "adding $USER"
        sudo /usr/sbin/usermod -G "$GROUP" -a "$USER"
        LOGOUT_REQUIRED=true
    else
        echo -n "pass"
    fi
done
echo ""

COMPOSE_INSTALLED_CORRECTLY=false
COMPOSE_CMD_PATH="$(command -v docker-compose 2>/dev/null)"
COMPOSE_PLUGIN_PATH="$(resolve_compose_plugin_path)"

echo -e -n "\nChecking whether docker-compose is installed correctly - "
if [ -n "$COMPOSE_CMD_PATH" ] ; then
    if [ -L "$COMPOSE_CMD_PATH" ] && [ -f "$COMPOSE_CMD_PATH" ] && [ -n "$COMPOSE_PLUGIN_PATH" ] ; then
        COMPOSE_CMD_INODE="$(stat -c "%i" -L "$COMPOSE_CMD_PATH")"
        COMPOSE_PLUGIN_INODE="$(stat -c "%i" "$COMPOSE_PLUGIN_PATH")"
        if [ "$COMPOSE_CMD_INODE" -eq "$COMPOSE_PLUGIN_INODE" ] ; then
            COMPOSE_INSTALLED_CORRECTLY=true
        fi
    fi
else
    if [ -n "$COMPOSE_PLUGIN_PATH" ] ; then
        sudo ln -sf "$COMPOSE_PLUGIN_PATH" "$COMPOSE_SYMLINK_PATH"
        COMPOSE_INSTALLED_CORRECTLY=true
        COMPOSE_CMD_PATH="$COMPOSE_SYMLINK_PATH"
    fi
fi

if [ "$COMPOSE_INSTALLED_CORRECTLY" = "true" ] ; then
    echo "pass"
    echo -e -n "\nChecking your version of docker compose - "
    COMPOSE_VERSION_INSTALLED="$(docker compose version --short 2>/dev/null)"
    if [ -z "$COMPOSE_VERSION_INSTALLED" ] ; then
        COMPOSE_VERSION_INSTALLED="$(docker-compose version --short 2>/dev/null)"
    fi

    if [ -z "$COMPOSE_VERSION_INSTALLED" ] ; then
        echo "fail"
        echo "Unable to determine docker compose version."
        handle_exit 1
    fi

    if dpkg --compare-versions "$COMPOSE_VERSION_MINIMUM" gt "$COMPOSE_VERSION_INSTALLED" ; then
        echo "fail"
        echo "Minimum required compose version: $COMPOSE_VERSION_MINIMUM"
        echo "Installed compose version: $COMPOSE_VERSION_INSTALLED"
        handle_exit 1
    fi
    echo "pass"
else
    echo "fail"
    echo "docker-compose is not installed correctly."
    if [ -n "$COMPOSE_CMD_PATH" ] && is_python_script "$COMPOSE_CMD_PATH" ; then
        echo "Try removing pip docker-compose first:"
        echo "   export PIP_BREAK_SYSTEM_PACKAGES=1"
        echo "   pip3 uninstall -y docker-compose"
        echo "   sudo pip3 uninstall -y docker-compose"
    else
        echo "Try: sudo apt install -y docker-compose-plugin"
    fi
    handle_exit 1
fi

if [ ! -d "$IOTSTACK" ] ; then
    echo -e "\nCloning IOTstack repository from GitHub"
    git clone https://github.com/SensorsIot/IOTstack.git "$IOTSTACK"
    if [ $? -eq 0 ] && [ -d "$IOTSTACK" ] ; then
        echo "IOTstack cloned successfully into $IOTSTACK"
    else
        echo "Unable to clone IOTstack (likely git or network error)"
        handle_exit 1
    fi
else
    echo -e "\n$IOTSTACK already exists - no need to clone"
fi

mkdir -p "$IOTSTACK/backups" "$IOTSTACK/services"
sudo chown -R "$USER:$USER" "$IOTSTACK/backups" "$IOTSTACK/services"
[ -d "$IOTSTACK/backups/influxdb" ] && sudo chown -R "root:root" "$IOTSTACK/backups/influxdb"

if command -v timedatectl >/dev/null 2>&1 ; then
    TZ_VALUE="$(timedatectl show --value --property=Timezone 2>/dev/null)"
else
    TZ_VALUE="${TZ:-Etc/UTC}"
fi

if [ ! -f "$IOTSTACK_ENV" ] || [ "$(grep -c "^TZ=" "$IOTSTACK_ENV")" -eq 0 ] ; then
    echo "TZ=${TZ_VALUE:-Etc/UTC}" >>"$IOTSTACK_ENV"
fi

PYTHON_INVOKES="$(update-alternatives --list python 2>/dev/null)"
PYTHON3_PATH="$(command -v python3)"
if [ "$PYTHON_INVOKES" != "$PYTHON3_PATH" ] ; then
    echo -e "\nMaking python3 the default"
    sudo update-alternatives --install /usr/bin/python python "$PYTHON3_PATH" 1
fi

echo -e -n "\nChecking your version of Python - "
PYTHON_VERSION_INSTALLED="$(python --version 2>/dev/null)"
PYTHON_VERSION_INSTALLED="${PYTHON_VERSION_INSTALLED#*Python }"
if [ -z "$PYTHON_VERSION_INSTALLED" ] ; then
    echo "fail"
    echo "Unable to run python."
    handle_exit 1
fi

if dpkg --compare-versions "$PYTHON_VERSION_MINIMUM" gt "$PYTHON_VERSION_INSTALLED" ; then
    echo "fail"
    echo "Minimum required Python version: $PYTHON_VERSION_MINIMUM"
    echo "Installed Python version: $PYTHON_VERSION_INSTALLED"
    handle_exit 1
fi
echo "pass"

if [ -e "$IOTSTACK_MENU_REQUIREMENTS" ] ; then
    echo -e "\nChecking and updating IOTstack dependencies (pip)"
    echo "Note: pip3 installs bypass externally-managed environment check"
    PIP_BREAK_SYSTEM_PACKAGES=1 pip3 install -U -r "$IOTSTACK_MENU_REQUIREMENTS"
fi

sudo rm -rf "$IOTSTACK_MENU_VENV_DIR"

handle_exit 0
