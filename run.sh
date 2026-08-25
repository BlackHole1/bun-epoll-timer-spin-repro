#!/bin/sh
# Runs the matrix: Bun version x (epoll_pwait2 available | blocked) x timer mode.
#
# "blocked" uses a seccomp profile that makes epoll_pwait2 return ENOSYS, which puts Bun on the
# same epoll_pwait fallback path it takes on Linux kernels older than 5.11.
#
# Environment overrides:
#   VERSIONS="1.3.13 1.3.14 1.4.0"   Bun image tags to test
#   MODES="timer1 timer10 kafkajs"   modes of spin.ts to run
#   SECONDS_PER_RUN=5                measurement window per run
set -eu
cd "$(dirname "$0")"

VERSIONS="${VERSIONS:-1.3.13 1.3.14 1.4.0}"
MODES="${MODES:-timer1 timer10 kafkajs}"
SECONDS_PER_RUN="${SECONDS_PER_RUN:-5}"
SECCOMP_PROFILE="$PWD/seccomp-no-epoll_pwait2.json"

if [ ! -d node_modules/kafkajs ]; then
  echo "installing kafkajs into ./node_modules (inside a container, no local bun needed)" >&2
  docker run --rm -v "$PWD":/app -w /app oven/bun:1.4.0 bun install --frozen-lockfile --silent
fi

# run_case <bun version> <available|blocked> <mode>: prints the JSON line emitted by spin.ts
run_case() {
  if [ "$2" = blocked ]; then
    docker run --rm --cpus=1 --security-opt "seccomp=$SECCOMP_PROFILE" -v "$PWD":/app -w /app \
      "oven/bun:$1" bun spin.ts "$3" "$SECONDS_PER_RUN" 2>/dev/null | tail -n 1
  else
    docker run --rm --cpus=1 -v "$PWD":/app -w /app \
      "oven/bun:$1" bun spin.ts "$3" "$SECONDS_PER_RUN" 2>/dev/null | tail -n 1
  fi
}

printf '%-8s  %-13s  %-8s  %8s  %6s  %6s\n' bun epoll_pwait2 mode iter/s user% sys%
for version in $VERSIONS; do
  for availability in available blocked; do
    for mode in $MODES; do
      line=$(run_case "$version" "$availability" "$mode" || true)
      parsed=$(printf '%s' "$line" | sed -n \
        's/.*"iterationsPerSecond":\([0-9]*\).*"userCpuPercent":\([0-9.]*\).*"systemCpuPercent":\([0-9.]*\).*/\1 \2 \3/p')
      if [ -z "$parsed" ]; then
        printf '%-8s  %-13s  %-8s  %s\n' "$version" "$availability" "$mode" "failed: $line"
        continue
      fi
      # shellcheck disable=SC2086
      set -- $parsed
      printf '%-8s  %-13s  %-8s  %8s  %6s  %6s\n' "$version" "$availability" "$mode" "$1" "$2" "$3"
    done
  done
done
