#!/bin/sh
# Codex CLI setup for Alphanome's Cloudflare AI Gateway (DeepSeek V4.1-Flash).
#
# Installs into $HOME/.codex/, from ./config/ (the source of truth), or from
# the latest GitHub release when run standalone:
#   config.toml         ./config/config.toml is prepended to the existing file
#                       (inside marker comments, so re-runs replace it)
#   alp-cf-models.json  copied as-is
#
# Usage: ./setup-codex.sh [--skip-prereq-checks]

set -e

TARGET_DIR="$HOME/.codex"
SKIP_PREREQ_CHECKS=0

CLOUDFLARED_RELEASES="https://github.com/cloudflare/cloudflared/releases/latest/download"
RELEASE_URL="https://github.com/alphanome-ai/org-setup/releases/latest/download"

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
err()  { printf 'error: %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<'USAGE'
Usage: setup-codex.sh [options]

Writes Codex CLI configuration into $HOME/.codex/.

Options:
  -h, --help             Show this help and exit.
  --skip-prereq-checks   Write the config even if codex and/or cloudflared are
                         missing. Useful when provisioning an image where the
                         tools get installed later.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--skip-prereq-checks) SKIP_PREREQ_CHECKS=1 ;;
		*) err "unknown option: $1"; usage >&2; exit 2 ;;
	esac
	shift
done

# From a repo checkout, use ./config/. Run standalone (downloaded as a release
# asset), fetch the same two files from the latest GitHub release.
SRC_DIR="$(dirname "$0")/config"
if [ ! -f "$SRC_DIR/config.toml" ] || [ ! -f "$SRC_DIR/alp-cf-models.json" ]; then
	have curl || { err "curl is required to download the config files."; exit 1; }
	SRC_DIR=$(mktemp -d)
	trap 'rm -rf "$SRC_DIR"' EXIT
	for f in config.toml alp-cf-models.json; do
		say "Downloading $f..."
		if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$SRC_DIR/$f" "$RELEASE_URL/$f"; then
			err "download failed: $RELEASE_URL/$f"
			exit 1
		fi
	done
fi
TOML_SRC="$SRC_DIR/config.toml"
CATALOG_SRC="$SRC_DIR/alp-cf-models.json"

# Run a command as root, using sudo when we are not already root.
# Returns non-zero if no privilege escalation is available.
run_root() {
	if [ "$(id -u)" = "0" ]; then
		"$@"
	elif have sudo; then
		sudo "$@"
	else
		return 1
	fi
}

# Map this machine's architecture onto a cloudflared release asset suffix.
# Echoes "amd64" or "arm64", or nothing when unsupported.
cloudflared_arch() {
	case "$(uname -m)" in
		x86_64|amd64) echo amd64 ;;
		aarch64|arm64) echo arm64 ;;
		*) : ;;
	esac
}

install_cloudflared() {
	# macOS, and Linuxbrew: the package manager handles everything.
	if have brew; then
		say "Installing cloudflared with Homebrew..."
		brew install cloudflared && return 0
		return 1
	fi

	have curl || return 1
	arch=$(cloudflared_arch)
	[ -n "$arch" ] || { warn "Unsupported architecture: $(uname -m)"; return 1; }

	# Debian / Ubuntu: install the .deb from Cloudflare's release page.
	if have apt-get && have dpkg; then
		asset="cloudflared-linux-$arch.deb"
		tmp="${TMPDIR:-/tmp}/$asset"
		say "Downloading $asset..."
		curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$CLOUDFLARED_RELEASES/$asset" || return 1
		say "Installing (this may prompt for your password)..."
		run_root dpkg -i "$tmp" && return 0
		return 1
	fi

	# RHEL / Fedora / Amazon Linux: install the .rpm.
	if have dnf || have yum; then
		case "$arch" in
			amd64) asset="cloudflared-linux-x86_64.rpm" ;;
			arm64) asset="cloudflared-linux-aarch64.rpm" ;;
		esac
		tmp="${TMPDIR:-/tmp}/$asset"
		say "Downloading $asset..."
		curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$CLOUDFLARED_RELEASES/$asset" || return 1
		say "Installing (this may prompt for your password)..."
		run_root rpm -Uvh --replacepkgs "$tmp" && return 0
		return 1
	fi

	# Anything else on Linux: drop the static binary into /usr/local/bin.
	asset="cloudflared-linux-$arch"
	tmp="${TMPDIR:-/tmp}/$asset"
	say "Downloading $asset..."
	curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$CLOUDFLARED_RELEASES/$asset" || return 1
	say "Installing to /usr/local/bin (this may prompt for your password)..."
	run_root cp "$tmp" /usr/local/bin/cloudflared || return 1
	run_root chmod 0755 /usr/local/bin/cloudflared || return 1
	return 0
}

cloudflared_manual_instructions() {
	cat <<'EOS' >&2

Install cloudflared manually, then re-run this script:

  macOS           brew install cloudflared
  Windows         winget install --id Cloudflare.cloudflared -e

  Debian/Ubuntu   curl -fL -o /tmp/cloudflared.deb \
                    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
                  sudo dpkg -i /tmp/cloudflared.deb

  RHEL/Fedora     sudo rpm -Uvh \
                    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm

  Other Linux     download a static binary from
                    https://github.com/cloudflare/cloudflared/releases
                  then: install -m 0755 cloudflared-linux-amd64 /usr/local/bin/cloudflared

Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
EOS
}

# Homebrew on macOS; otherwise (or if brew fails) OpenAI's standalone
# installer, which installs to ~/.local/bin without sudo.
install_codex() {
	say "Codex CLI not found; installing..."
	if [ "$(uname -s)" = "Darwin" ] && have brew; then
		brew install --cask codex && return 0
	fi
	have curl || return 1
	# CODEX_NON_INTERACTIVE stops the installer offering to launch Codex before
	# our config is written.
	curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh || return 1
	# The installer updates shell profiles for future sessions; this one needs it now.
	PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"
}

MISSING_PREREQS=0

# ---------- prerequisite: Codex CLI ----------
# The config is useless without the client, so report this clearly. Whether to
# stop is decided after both checks have run, so the user sees every problem in
# one pass.
if have codex; then
	say "Found Codex CLI: $(command -v codex)"
elif install_codex && have codex; then
	say "Installed Codex CLI: $(command -v codex)"
else
	err "Codex CLI not found on your PATH, and automatic installation failed."
	cat <<'EOS' >&2

Install the Codex CLI, then re-run this script:

  macOS (Homebrew)      brew install --cask codex
  macOS / Linux         curl -fsSL https://chatgpt.com/codex/install.sh | sh
  npm (all platforms)   npm install -g @openai/codex

Docs: https://developers.openai.com/codex/cli
EOS
	MISSING_PREREQS=1
fi

# ---------- prerequisite: cloudflared ----------
# Required by the auth block in config.toml: it performs the Cloudflare Access
# login that authenticates requests to the gateway.
if have cloudflared; then
	say "Found cloudflared: $(command -v cloudflared)"
else
	warn "cloudflared not found (required for gateway authentication)."
	say "Attempting to install cloudflared..."
	if install_cloudflared; then
		if have cloudflared; then
			say "Installed cloudflared: $(command -v cloudflared)"
		else
			# Package managers can install outside the current shell's PATH.
			warn "cloudflared was installed, but is not on this shell's PATH yet."
			warn "Open a new terminal and re-run this script."
			MISSING_PREREQS=1
		fi
	else
		warn "Automatic installation failed or is not supported on this system."
		cloudflared_manual_instructions
		MISSING_PREREQS=1
	fi
fi

if [ "$MISSING_PREREQS" = "1" ] && [ "$SKIP_PREREQ_CHECKS" = "0" ]; then
	err "Missing prerequisites; config was NOT written."
	err "Resolve the items above and re-run, or pass --skip-prereq-checks to write the config anyway."
	exit 1
fi

# ---------- write configuration ----------
mkdir -p "$TARGET_DIR"

CONFIG="$TARGET_DIR/config.toml"
BEGIN_MARK="# >>> alphanome codex setup >>>"
END_MARK="# <<< alphanome codex setup <<<"

# TOML has no way to close a [table], so keys after a header belong to it.
# Our file is therefore split at its first [table] header: its top-level keys
# go at the very top (before any of the user's tables) and its tables go at
# the very bottom (so they can't capture the user's top-level keys).
# Marked blocks from a previous run are stripped, so re-runs never duplicate keys.
# Unmarked copies of our top-level keys and tables in the user's file are
# dropped too, so ours replace them instead of duplicating them.
# ponytail: header detection is a line starting with "[", fine while
# config/config.toml has no multi-line arrays at the top level. Keys are
# matched by bare name; dotted or quoted top-level keys are left alone.
touch "$CONFIG"
cp "$CONFIG" "$CONFIG.bak"
tmp="$TARGET_DIR/.config.toml.tmp.$$"
{
	printf '%s\n' "$BEGIN_MARK"
	awk '/^\[/ { exit } 1' "$TOML_SRC"
	printf '%s\n' "$END_MARK"
	awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
		function header(s) { sub(/#.*/, "", s); gsub(/[ \t]/, "", s); return s }
		function key(s) { if (!match(s, /^[ \t]*[A-Za-z0-9_-]+[ \t]*=/)) return ""; s = substr(s, 1, RLENGTH); gsub(/[ \t=]/, "", s); return s }
		# First file (ours): collect its top-level key names and table headers.
		NR == FNR {
			if (/^\[/) { tables[header($0)] = 1; in_tables = 1 }
			else if (!in_tables && key($0) != "") keys[key($0)] = 1
			next
		}
		$0 == b { skip = 1; next }
		$0 == e { skip = 0; next }
		skip { next }
		/^\[/ { user_tables = 1; drop = (header($0) in tables) }
		drop { next }
		!user_tables && (key($0) in keys) { next }
		1
	' "$TOML_SRC" "$CONFIG"
	printf '%s\n' "$BEGIN_MARK"
	awk 'found || /^\[/ { found = 1; print }' "$TOML_SRC"
	printf '%s\n' "$END_MARK"
} > "$tmp"
# cat-into rather than mv: keeps the existing file's permissions and symlinks.
cat "$tmp" > "$CONFIG"
rm -f "$tmp"

# Copied under its own name, which model_catalog_json in config.toml points at.
cp "$CATALOG_SRC" "$TARGET_DIR/"

echo "Successfully written configuration files to $TARGET_DIR"
