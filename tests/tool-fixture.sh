#!/bin/sh
set -eu
mkdir -p "$1/libexec"
printf '#!/bin/sh\nprintf "%s\\n"\n' "$2" > "$1/libexec/fixture"
