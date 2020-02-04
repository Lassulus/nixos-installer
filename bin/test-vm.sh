#!/usr/bin/env nix-shell
#! nix-shell -i bash -p nixos-generators

set -xefu

WD=$(dirname "$0")
nixos-generate -c "$WD"/../test.nix -f vm-nogui --run "$@"
