#!/usr/bin/env bash
# Compile every ```rust block of the skill against the published discordrs.
#
#   scripts/check-examples.sh                 # discordrs =3.2.0 from crates.io
#   DISCORDRS_VERSION=3.1.1 scripts/check-examples.sh
#   DISCORDRS_PATH=$HOME/discord.rs scripts/check-examples.sh   # unpublished checkout
#   CHECK_DIR=/tmp/elsewhere scripts/check-examples.sh
#
# Each block's first line `// features: ...` selects the Cargo features; blocks
# with the same set share one scratch crate (see scripts/extract-examples.py).
# Needs python3 and cargo. Uses no token and makes no Discord requests.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_dir="${CHECK_DIR:-/tmp/discordrs-skill-check}"
version="${DISCORDRS_VERSION:-3.2.0}"
export PATH="$HOME/.cargo/bin:$PATH"
# One target dir for every feature set: dependencies compile once.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$check_dir/target}"

if [[ -n "${DISCORDRS_PATH:-}" ]]; then
  spec="path = \"$DISCORDRS_PATH\""
else
  spec="version = \"=$version\""
fi

rm -rf "$check_dir"/check-*
python3 -I "$root/scripts/extract-examples.py" "$root" "$check_dir" "$spec"

status=0
for crate in "$check_dir"/check-*/; do
  name="$(basename "$crate")"
  echo "== cargo check $name"
  if ! cargo check --quiet --manifest-path "$crate/Cargo.toml"; then
    echo "FAILED: $name ($crate/src/lib.rs)" >&2
    status=1
  fi
done
if [[ $status -eq 0 ]]; then
  echo "all example crates compiled against discordrs ($spec)"
fi
exit $status
