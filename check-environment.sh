#!/bin/sh

set -e

REQ_DOCKER_CLIENT_VERSION=24.0.6
REQ_DOCKER_SERVER_VERSION=24.0.6
REQ_COMPOSE_VERSION=2.21.0
REQ_ADDR_POOL='{"base":"fd00:0:1:1f::/64","size":64}'

TAG_JQ="latest"
CURRENT_USER="$(id -u ${USER}):$(id -g ${USER})"

JQ_IMAGE="stedolan/jq:$TAG_JQ"

if [ "$1" = "--skip-version-check" ]; then
    SKIP_VERSION_CHECK=1
    shift
fi

jq() {
    (docker run -i --rm --user "$CURRENT_USER" \
        -v "$PWD:/workdir" \
        $JQ_IMAGE "$@")
}

docker inspect --type=image "$JQ_IMAGE" >/dev/null 2>&1 || docker pull --quiet "$JQ_IMAGE"

checkMinVersion() {
    if [ "$1" = "$2" ] || [ "$1" = "$(printf '%s\n' "$1" "$2" | sort --version-sort | head -n 1)" ]; then
        return 0
    fi
    return 1
}

checkVersion() {
    local TITLE="$1"
    local EXPECTED="$2"
    local CMD="$3"
    local CURRENT

    if ! CURRENT="$($CMD 2>&1)"; then
        echo "ERROR: Failed to check version for: $TITLE" >&2
        echo "$CURRENT"
    else
        if checkMinVersion "$EXPECTED" "$CURRENT"; then
            echo "Version check[$TITLE]: OK (expected: $EXPECTED; current: $CURRENT)"
            return 0
        fi
        echo "ERROR: Failed to check version for: $TITLE" >&2
        echo "Expected version: $EXPECTED" >&2
        echo "Current version: $CURRENT" >&2
    fi

    if [ -z "$SKIP_VERSION_CHECK" ]; then
        echo >&2
        echo "Use --skip-version-check parameter to ignore this error." >&2
        exit 1
    fi
}

error() {
    echo >&2
    echo "ERROR: $1" >&2
    exit 1
}

echo "Checking versions..."
checkVersion "docker client" "$REQ_DOCKER_CLIENT_VERSION" "docker version --format {{.Client.Version}}"
checkVersion "docker server" "$REQ_DOCKER_SERVER_VERSION" "docker version --format {{.Server.Version}}"
docker compose version --short >/dev/null 2>&1 || error "could not find the docker compose V2 plugin. Please install it using this instruction: https://docs.docker.com/compose/install/linux/"
checkVersion "docker compose" "$REQ_COMPOSE_VERSION" "docker compose version --short"

[ -e $HOME/.docker/daemon.json ] || error "dockerd config file $HOME/.docker/daemon.json not found"

TEMP_DOCKERD_JSON="$(mktemp)"
cp -f $HOME/.docker/daemon.json "$TEMP_DOCKERD_JSON"

checkValue() {
    local PARAM="$1"
    local EXPECTED="$2"
    local CURRENT
    CURRENT="$(cat "$TEMP_DOCKERD_JSON" | jq ".\"$PARAM\"")"
    if [ "$CURRENT" != "$EXPECTED" ]; then
        echo "dockerd config value[$PARAM] needs to be set to '$EXPECTED' (current value: '$CURRENT')"
        cat "$TEMP_DOCKERD_JSON" | jq ".\"$PARAM\" = $EXPECTED" > ${TEMP_DOCKERD_JSON}.fixed
        mv -f "${TEMP_DOCKERD_JSON}.fixed" "$TEMP_DOCKERD_JSON"
        RESTART_DOCKER=1
    else
        echo "dockerd config value[$PARAM]: OK ('$CURRENT')"
    fi
}

echo
echo "Checking dockerd config..."
checkValue "ipv6" "true"
checkValue "ip6tables" "true"
checkValue "fixed-cidr-v6" '"fd00::/64"'
checkValue "experimental" "true"

if ! ADR_POOL="$(cat "$TEMP_DOCKERD_JSON" | jq -c '."default-address-pools"[]' 2>/dev/null | grep --fixed-strings "$REQ_ADDR_POOL")" || [ "$ADR_POOL" != "$REQ_ADDR_POOL" ]; then
    echo "dockerd config value[default-address-pools] needs to be set to '$REQ_ADDR_POOL'"
    cat "$TEMP_DOCKERD_JSON" | jq ".\"default-address-pools\" += [$REQ_ADDR_POOL]" > ${TEMP_DOCKERD_JSON}.fixed
    mv -f "${TEMP_DOCKERD_JSON}.fixed" "$TEMP_DOCKERD_JSON"
    RESTART_DOCKER=1
else
    echo "dockerd config value[default-address-pools]: OK ('$ADR_POOL')"
fi

echo
if [ -z "$RESTART_DOCKER" ]; then
    echo "Current environment looks OK."
    exit 0
fi

echo "The dockerd configuration ($HOME/.docker/daemon.json) in the current environment must to be modified."
echo
echo "Current configuration:"
cat $HOME/.docker/daemon.json
echo
echo "Suggested configuration:"
cat "$TEMP_DOCKERD_JSON"
echo
read -r -p "Do you want to apply the suggested changed to the dockerd configuration? [y/N] " ASK
echo
case $ASK in
    [Yy]*)
        echo "Replacing $HOME/.docker/daemon.json ..."
        cat "$TEMP_DOCKERD_JSON" | sudo tee $HOME/.docker/daemon.json >/dev/null
        echo "Restart Docker Desktop..."
        #(set -x; sudo systemctl restart docker)
        echo
        echo "OK"
        ;;
    *)
        echo "WARNING: The dockerd configuration will not be modified. The environment may not work as expected."
        exit 1
        ;;
esac

