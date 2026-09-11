# Codex setup — Alphanome

One-shot setup scripts that point the Codex CLI at Alphanome's Cloudflare AI
Gateway endpoint and register **DeepSeek V4.1-Flash** as the default model.

Both scripts resolve the current user's home directory at runtime, so there is
nothing user-specific to edit before distributing them. They copy the model
catalog from `config/codex-models-with-deepseek.json`, so **run them from a full
checkout of this repository**, not as standalone downloads.
They also **check that their prerequisites are present before writing anything**,
so a machine that is missing the Codex CLI or cloudflared gets clear install
instructions instead of a silently useless config.

| Script | Platform | Writes to |
| --- | --- | --- |
| `setup-codex.sh` | macOS, Linux | `$HOME/.codex/` |
| `setup-codex.ps1` | Windows | `%USERPROFILE%\.codex\` |

## What it installs

Each script writes exactly two files into your Codex config directory:

| File | Purpose |
| --- | --- |
| `~/.codex/config.toml` | Model selection, the `cloudflare-ai-gateway` provider, its auth command, and per-token cost headers. |
| `~/.codex/codex-models-with-deepseek.json` | The model catalog entry for `deepseek-flash`: Codex's `gpt-5.5` harness with the model swapped. |

Both are written as **UTF-8 without a BOM**, since TOML and strict JSON parsers
can reject a leading byte-order mark.

The filename of the JSON is not arbitrary — it must match `model_catalog_json`
inside `config.toml`. If you rename one, rename both.

## Prerequisite checks

Before writing any config, both scripts run the same two checks.

**1. Codex CLI.** If `codex` is not on your `PATH`, the script installs it:

| Platform | Mechanism |
| --- | --- |
| macOS with Homebrew | `brew install --cask codex` |
| macOS without Homebrew, Linux | `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` (installs to `~/.local/bin`, no sudo) |
| Windows | `irm https://chatgpt.com/codex/install.ps1 \| iex` (installs to `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin`) |

The official installers run with `CODEX_NON_INTERACTIVE=1`, so they don't offer
to launch Codex before the config is written. They download from
`releases.openai.com` and fall back to GitHub Releases. If the install fails,
the script prints manual instructions and stops.

**2. cloudflared.** Required, because the `auth` block in `config.toml` shells
out to `cloudflared access login`. If it is missing, the script installs it
automatically using whatever is available, in this order:

| Platform | Mechanism |
| --- | --- |
| macOS, Linuxbrew | `brew install cloudflared` |
| Debian / Ubuntu | `.deb` from Cloudflare's release page, installed via `dpkg` |
| RHEL / Fedora / Amazon Linux | `.rpm` from Cloudflare's release page, installed via `rpm` |
| Other Linux | static binary installed to `/usr/local/bin/cloudflared` |
| Windows | `winget`, then Chocolatey, then Scoop |

On Linux the install step writes outside your home directory, so it uses `sudo`
and **may prompt for your password**. If no supported package manager is found,
or the install fails, the script prints manual instructions instead.

**If either check fails, no files are written and the script exits non-zero.**
This is deliberate: a config pointing at a CLI you do not have is worse than no
config, because it fails later and less obviously.

## Install

### macOS / Linux

```bash
chmod +x setup-codex.sh
./setup-codex.sh
```

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File setup-codex.ps1
```

`-ExecutionPolicy Bypass` scopes the policy change to that single invocation; it
does not change your machine-wide PowerShell settings.

On success either script prints:
```
Successfully written configuration files to <config-dir>
```

### Skipping the checks

To write the config even when a prerequisite is missing — for example when
building an image where the tools are installed in a later layer:

```bash
./setup-codex.sh --skip-prereq-checks
```
```powershell
powershell -ExecutionPolicy Bypass -File setup-codex.ps1 -SkipPrereqChecks
```

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Config written, or `--help` shown. |
| `1` | A prerequisite is missing; nothing was written. |
| `2` | Unrecognised option (shell script only). |

## Verify the install

**1. Confirm both files landed:**
```bash
ls -la ~/.codex/config.toml ~/.codex/codex-models-with-deepseek.json
```
```powershell
Get-ChildItem "$HOME\.codex\config.toml", "$HOME\.codex\codex-models-with-deepseek.json"
```

**2. Confirm the JSON is valid:**
```bash
python3 -m json.tool ~/.codex/codex-models-with-deepseek.json > /dev/null && echo "JSON OK"
```

**3. Confirm the tools are visible:**
```bash
codex --version
cloudflared --version
```

**4. Send a test prompt.** The first request triggers `cloudflared access login`
and opens a browser tab. Complete the login, then the request proceeds. A
successful response confirms the provider, auth, and model catalog are all wired
up correctly.

## Configuration reference

The generated `config.toml` in full:

```toml
# ---------- Model selection ----------
model_provider = "cloudflare-ai-gateway"
model = "deepseek-flash"
model_reasoning_effort = "medium"

model_catalog_json = "~/.codex/codex-models-with-deepseek.json"

# ---------- Cloudflare AI Gateway ----------

[model_providers.cloudflare-ai-gateway]
name = "Alphanome"
base_url = "https://inference.domesly.com/deepseek"
wire_api = "responses"

# Per-token cost reported to the gateway, in USD per token.
http_headers = { "cf-aig-custom-cost" = '{"per_token_in":0.0000003,"per_token_out":0.0000012,"per_cache_read_token":0.000000006,"per_cache_write_token":0.000000006}' }

[model_providers.cloudflare-ai-gateway.auth]
command = "cloudflared"
args = ["access", "login", "--no-verbose", "https://inference.domesly.com"]
timeout_ms = 30000
refresh_interval_ms = 0
```

| Key | Meaning |
| --- | --- |
| `model` | Default model slug; must match `models[].slug` in the JSON catalog. |
| `model_reasoning_effort` | Default reasoning level. Valid: `low`, `medium`, `high`, `xhigh`. |
| `model_catalog_json` | Path to the JSON catalog. Uses a literal `~`; see limitations. |
| `base_url` | Gateway route. The API path is appended by the client. |
| `wire_api` | `responses` — the Responses API wire format. |
| `http_headers` | Per-token pricing in USD so the gateway can compute spend. |
| `auth.command` / `args` | How to obtain credentials — `cloudflared access login`. |
| `refresh_interval_ms` | `0` — creds are cached by `cloudflared`, not re-fetched on a timer. |
| `timeout_ms` | Max wait for the auth command (30s). |

### Reasoning levels

| Effort | Behavior |
| --- | --- |
| `low` | Fast responses with lighter reasoning |
| `medium` | Balanced (default) |
| `high` | Greater reasoning depth for complex problems |
| `xhigh` | Extra high reasoning depth |

Model limits: `1000000` token context window (`context_window` and
`max_context_window`), token-based output truncation at `10000`.

### Why the catalog entry is so large

The `deepseek-flash` entry is a clone of Codex's own `gpt-5.5` entry, taken
from `~/.codex/models_cache.json` (Codex 0.154.0). Codex requires either
`base_instructions` or `model_messages.instructions_template`; the clone
carries the full ~21K-character Codex prompt. Only these fields differ:

- Identity: slug, name, description, `priority`, 1M context window, and the
  prompt's opening line says "based on DeepSeek V4.1-Flash" instead of "GPT-5".
- OpenAI-only features switched off: `support_verbosity`, `supports_search_tool`
  (hosted web search), image input (`input_modalities = ["text"]`).
- Dropped: `comp_hash`, `default_verbosity`, `web_search_tool_type`.

To pick up a newer Codex prompt, regenerate the file from `models_cache.json`
with the same edits.

This keeps the full Codex harness — system prompt, `apply_patch` tool,
`unified_exec` shell — and swaps only the model underneath. `gpt-5.5` is cloned rather than `gpt-5.6-*`
because 5.6 uses `code_mode_only` and `use_responses_lite`, which depend on
OpenAI's servers.

## Customizing

**Change the default reasoning effort** — edit `model_reasoning_effort` in
`~/.codex/config.toml` after running the script, or change the default in the
script before distributing it.

**Change the default model** — update `model` in `config.toml` to any slug
present in the catalog.

**Update per-token pricing** — edit the `cf-aig-custom-cost` object in
`config.toml`. Values are USD per token, so `0.0000012` is $1.20 per million.

## Known limitations

- **The scripts overwrite `config.toml`.** There is no backup step and no merge.
  Any existing providers, models, plugin, or MCP settings in that file are replaced.
  Back it up first if you have an existing Codex configuration:
  ```bash
  cp ~/.codex/config.toml ~/.codex/config.toml.bak
  ```
- **`model_catalog_json` uses a literal `~`.** This is the only path in the
  file. It works if Codex expands `~` itself, which is verified on macOS. If a
  platform does not expand it (Windows is untested), replace the value with an
  absolute path inside `config.toml`.
- **`notify` is deliberately not written.** The turn-ended hook is
  machine-local — it points at a binary inside a macOS `.app` bundle — so it is
  not part of the distributed config. Add your own `notify` line to
  `config.toml` if you want that behaviour on a particular machine.
- **The cloudflared install needs network access** and, on Linux, `sudo`. On a
  locked-down or offline machine, install cloudflared first and the script will
  skip straight to writing config.
- **Uninstalling does not remove cloudflared.** See below.

## Uninstall / revert

The scripts create only the two config files. To revert:

```bash
rm -f ~/.codex/codex-models-with-deepseek.json
rm -f ~/.codex/config.toml   # or: mv ~/.codex/config.toml.bak ~/.codex/config.toml
```

If the script installed cloudflared for you, remove it separately with the same
package manager (`brew uninstall cloudflared`, `winget uninstall Cloudflare.cloudflared`,
`sudo apt-get remove cloudflared`, …) — it is a general-purpose tool and is left
in place.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `error: Codex CLI not found on your PATH.` | codex not installed, or not on this shell's `PATH` | Install it with one of the printed commands, then re-run. |
| `warning: cloudflared was installed, but is not on this shell's PATH yet.` | Package managers update `PATH` for *new* sessions only | Open a new terminal and re-run the script. |
| `Automatic installation failed or is not supported on this system.` | No supported package manager, no network, or no `sudo` | Follow the printed manual instructions, then re-run. |
| `Missing prerequisites; config was NOT written.` | One of the two checks failed | Fix the reported item, or use `--skip-prereq-checks` / `-SkipPrereqChecks`. |
| `error: unknown option: --foo` | Typo in a flag | Run with `--help`. |
| `cloudflared: command not found` at request time | It was installed after the shell started | Restart the shell, or check your `PATH`. |
| Browser opens but requests still fail | Cloudflare Access login not completed, or not authorized for the app | Re-run and finish the browser login; confirm you're a member of the Access policy. |
| `403` / `Unauthorized` from the gateway | Authenticated, but not authorized for `inference.domesly.com` | Request access from whoever administers the Cloudflare Access application. |
| `model not found` / unknown slug | Catalog JSON missing, malformed, or `model_catalog_json` path wrong | Re-run the setup script; validate the JSON with the check above. |
| Model list is empty | Codex did not expand the `~` in `model_catalog_json` | Replace it with an absolute path to the JSON file. |
| Pricing shows as zero | `cf-aig-custom-cost` header stripped or malformed | Confirm the `http_headers` line is intact and the JSON inside it is valid. |
| Login prompt appears on every request | Cached Access credentials cleared | Expected to be cached; check that the `auth` block survived in `config.toml`. |
