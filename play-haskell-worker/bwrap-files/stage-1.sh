#!/bin/bash
set -euo pipefail

echo >&2 "[s1] In stage-1"

cd "$(dirname "$0")"

# Read ghc output FD from command-line arguments
if [[ $# -ne 1 ]]; then
  echo >&2 "Usage: $0 <ghc_out_fd>"
  echo >&2 "stage-2 needs to run bwrap with tomsmeding/tmpfs-size patch."
  echo >&2 "Build https://github.com/tomsmeding/bubblewrap/tree/tmpfs-size and"
  echo >&2 "put the executable in this directory as 'bwrap'. If such an executable"
  echo >&2 "exists, stage-2 will use it instead of the 'bwrap' from PATH."
  exit 1
fi
ghc_out_fd="$1"

# Close all open file descriptors other than 0,1,2 and the ghc output FD
close_cmdline="exec"
for fd in $(ls /proc/$$/fd); do
  if [[ "$fd" -gt 2 && "$fd" -ne "$ghc_out_fd" ]]; then
    close_cmdline="$close_cmdline $fd>&-"
  fi
done
eval "$close_cmdline"

tmpdir=$(mktemp -d)
echo >&2 "tmpdir = $tmpdir"

trap "rm -r '$tmpdir'" EXIT

mkfifo "${tmpdir}/ghc-out"
# This cat will exit automatically once the stage-2 exits (closes the fifo).
( cat <"${tmpdir}/ghc-out" >&"$ghc_out_fd" ) &
ghc_out_catpid=$!

echo >&2 "[s1] Entering systemd-run"

./systemd-run-shim ./stage-2.sh "${tmpdir}/ghc-out"

echo >&2 "[s1] systemd-run done"
