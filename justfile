default:
  @just --choose

alias l := lint

lint:
  nix develop .#adhoc --command ./scripts/lint.sh
