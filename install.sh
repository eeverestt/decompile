#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-eeverestt/decompile}"
REF="${REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
NO_MODIFY_PATH="${NO_MODIFY_PATH:-0}"

OS="$(uname -s)"
case "$OS" in
  MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
  Darwin)               PLATFORM="macos"   ;;
  Linux)                PLATFORM="linux"   ;;
  *)                    PLATFORM="unknown" ;;
esac

if [[ "$PLATFORM" == "windows" ]]; then
  BIN_NAME="decompile.exe"
  BUILD_BINARY="decompiler.exe"
else
  BIN_NAME="decompile"
  BUILD_BINARY="decompiler"
fi

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'
  CYAN=$'\033[36m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; CYAN=''; GREEN=''; YELLOW=''; RED=''; RESET=''
fi

_step=0
info()    { printf '  %s•%s %s\n' "$CYAN" "$RESET" "$*"; }
step()    { _step=$((_step + 1)); printf '  %s[%d]%s %s\n' "$CYAN" "$_step" "$RESET" "$*"; }
success() { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
error()   { printf '  %s✗ error:%s %s\n' "$RED" "$RESET" "$*" >&2; }
die()     { error "$*"; exit 1; }

banner() {
  local rule
  rule="$(printf '─%.0s' {1..58})"
  printf '\n  %s%s%s\n' "$DIM" "$rule" "$RESET"
  printf '  %sdecompiler%s\n' "$BOLD" "$RESET"
  printf '  %sDecompile Minecraft mod JARs into readable Java source.%s\n' "$DIM" "$RESET"
  printf '  %s%s%s\n\n' "$DIM" "$rule" "$RESET"
}

banner
info "Platform: ${BOLD}${PLATFORM}${RESET}"

step "Checking dependencies..."
for cmd in curl tar dotnet; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing dependency: $cmd"
done

if ! command -v java >/dev/null 2>&1; then
  warn "java not found — decompilation will fail at runtime."
fi

DOTNET_MAJOR="$(dotnet --version | cut -d. -f1)"
if [[ "$DOTNET_MAJOR" -lt 10 ]]; then
  die "the project targets .NET 10, but dotnet ${DOTNET_MAJOR}.x is installed."
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz"
ARCHIVE="$TMP_DIR/src.tar.gz"
SRC_DIR="$TMP_DIR/$(basename "$REPO")-${REF}"

step "Downloading ${BOLD}${REPO}@${REF}${RESET}..."
curl -fsSL "$ARCHIVE_URL" -o "$ARCHIVE" || die "download failed: $ARCHIVE_URL"

step "Extracting source..."
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
[[ -d "$SRC_DIR" ]] || die "expected source directory not found: $SRC_DIR"

PUBLISH_DIR="$TMP_DIR/publish"

step "Publishing (Release, single-file)..."
dotnet publish "$SRC_DIR" \
  -c Release \
  --self-contained false \
  -p:PublishSingleFile=true \
  -o "$PUBLISH_DIR" \
  --nologo \
  -v quiet

[[ -f "$PUBLISH_DIR/$BUILD_BINARY" ]] || die "build succeeded but binary was not produced"

step "Installing binary to ${BOLD}${INSTALL_DIR}/${BIN_NAME}${RESET}..."
mkdir -p "$INSTALL_DIR"
cp "$PUBLISH_DIR/$BUILD_BINARY" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"
success "Binary installed."

NEEDS_RELOAD=0
SHELL_RC=""

configure_path() {
  local dir="$1"
  local shell_name marker_begin marker_end

  shell_name="$(basename "${SHELL:-bash}")"

  case "$shell_name" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
    bash)
      if   [[ -f "$HOME/.bashrc" ]];       then SHELL_RC="$HOME/.bashrc"
      elif [[ -f "$HOME/.bash_profile" ]]; then SHELL_RC="$HOME/.bash_profile"
      else                                      SHELL_RC="$HOME/.profile"
      fi
      ;;
    *)    SHELL_RC="$HOME/.profile" ;;
  esac

  marker_begin="# >>> decompile installer >>>"
  marker_end="# <<< decompile installer <<<"

  if [[ -f "$SHELL_RC" ]] && grep -qF "$marker_begin" "$SHELL_RC"; then
    info "PATH already configured in ${BOLD}${SHELL_RC}${RESET}"
    return 0
  fi

  if printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$dir"; then
    info "${BOLD}${dir}${RESET} is already on PATH"
    return 0
  fi

  mkdir -p "$(dirname "$SHELL_RC")"

  if [[ "$shell_name" == "fish" ]]; then
    {
      echo ""
      echo "$marker_begin"
      echo "fish_add_path \"$dir\""
      echo "$marker_end"
    } >> "$SHELL_RC"
  else
    {
      echo ""
      echo "$marker_begin"
      echo "export PATH=\"$dir:\$PATH\""
      echo "$marker_end"
    } >> "$SHELL_RC"
  fi

  success "Added ${BOLD}${dir}${RESET} to PATH in ${BOLD}${SHELL_RC}${RESET}"
  NEEDS_RELOAD=1
}

if [[ "$NO_MODIFY_PATH" == "1" ]]; then
  step "Skipping PATH modification (NO_MODIFY_PATH=1)."
else
  step "Configuring PATH..."
  configure_path "$INSTALL_DIR"
fi

step "Cleaning up source files..."
cleanup
trap - EXIT
success "Source removed."

printf '\n'
success "Installed: ${BOLD}${INSTALL_DIR}/${BIN_NAME}${RESET}"

if [[ "$PLATFORM" == "windows" ]]; then
  if command -v cygpath >/dev/null 2>&1; then
    WIN_INSTALL_DIR="$(cygpath -w "$INSTALL_DIR")"
  else
    WIN_INSTALL_DIR="$INSTALL_DIR"
  fi
  printf '\n'
  warn "On Windows, PATH was added to your Git Bash rc file."
  warn "To run ${BIN_NAME} from cmd.exe or PowerShell, add this to your user PATH:"
  printf '    %s%s%s\n' "$BOLD" "$WIN_INSTALL_DIR" "$RESET"
fi

if [[ "$NEEDS_RELOAD" == "1" ]]; then
  printf '\n'
  warn "Shell reload required to pick up the new PATH."
  printf '  Run this in your terminal:\n\n'
  printf '    %ssource %s%s\n\n' "$BOLD" "$SHELL_RC" "$RESET"
  printf '  Or just open a new terminal.\n'
fi

printf '\n'
success "Done. Try: ${BOLD}${BIN_NAME} --help${RESET}"
printf '\n'
