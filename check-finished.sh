#!/bin/bash

# Usage ./check-finished ~/solus/packagename

# Figure out eopkg string.
PKGNAME=$(grep ^name < "$1/package.yml" | awk '{ print $3 }' | tr -d "'")
RELEASE=$(grep ^release < "$1/package.yml" | awk '{ print $3 }' | tr -d "'")
VERSION=$(grep ^version < "$1/package.yml" | awk '{ print $3 }' | tr -d "'")

# The buildname of the package listed on the buildserver queue.
BUILDNAME="${PKGNAME}-${VERSION}-${RELEASE}"

echo $BUILDNAME

while [[ ! $(curl -s https://build.getsol.us | grep -A 3 ${BUILDNAME} | grep build-ok) ]] ; do
    sleep 10
    if [[ $(curl -s https://build.getsol.us | grep -A 3 ${BUILDNAME} | grep build-failed) ]] ; then
        notify-send -u critical "${BUILDNAME} failed on the build server!" -t 0
        paplay /usr/share/sounds/freedesktop/stereo/suspend-error.oga
    fi
done

notify-send "$BUILDNAME finished building on the build server!" -t 0 && paplay /usr/share/sounds/freedesktop/stereo/message-new-instant.oga
