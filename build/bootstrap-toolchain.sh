#!/usr/bin/env bash
# Installs BUILD-TIME tools via Homebrew (never linked into produced binaries).
# Idempotent: second run installs nothing.
set -euo pipefail

command -v brew >/dev/null 2>&1 || { echo "ERROR: Homebrew required for build-time toolchain" >&2; exit 1; }

# formula -> binary used to detect presence
FORMULAE=(autoconf automake libtool pkg-config cmake bison re2c ninja)

missing=()
for f in "${FORMULAE[@]}"; do
  if ! brew list --formula --versions "$f" >/dev/null 2>&1; then
    missing+=("$f")
  fi
done

if ((${#missing[@]})); then
  echo "Installing: ${missing[*]}"
  HOMEBREW_NO_AUTO_UPDATE=1 brew install "${missing[@]}"
else
  echo "Toolchain already present (no-op)."
fi

BISON_BIN="$(brew --prefix bison)/bin"
export PATH="$BISON_BIN:$(brew --prefix)/bin:$PATH"

bison_ver="$(bison --version | head -1 | awk '{print $NF}')"
[[ "${bison_ver%%.*}" -ge 3 ]] || { echo "ERROR: bison >= 3 required, got $bison_ver" >&2; exit 1; }

printf '%-10s %s\n' bison "$bison_ver" \
  re2c "$(re2c --version | awk '{print $2}')" \
  cmake "$(cmake --version | head -1 | awk '{print $3}')" \
  autoconf "$(autoconf --version | head -1 | awk '{print $NF}')" \
  automake "$(automake --version | head -1 | awk '{print $NF}')" \
  glibtool "$(glibtool --version | head -1 | awk '{print $NF}')" \
  pkg-config "$(pkg-config --version)" \
  ninja "$(ninja --version)"
