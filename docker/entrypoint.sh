#!/bin/sh
set -e

Xvfb :99 -screen 0 800x600x24 -nolisten tcp &
export DISPLAY=:99

# Wait until Xvfb is accepting connections before starting Java
i=0
until xdotool getdisplaygeometry >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 30 ] && { echo "Xvfb failed to start" >&2; exit 1; }
    sleep 0.2
done

exec java -jar /emulicious/Emulicious.jar -remotedebug 58870 "$@"
