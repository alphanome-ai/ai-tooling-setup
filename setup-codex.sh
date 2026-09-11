#!/bin/sh
set -e

TARGET_DIR="$HOME/.codex"
mkdir -p "$TARGET_DIR"

# Write config.toml with dynamic home directory resolution
cat << EOF > "$TARGET_DIR/config.toml"
# ---------- Model selection ----------
model_provider = "cloudflare-ai-gateway"
model = "deepseek-flash"
model_reasoning_effort = "medium"

model_catalog_json = "~/.codex/codex-models-with-deepseek.json"

# ---------- Cloudflare AI Gateway ----------
notify = ["$HOME/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]

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
EOF

# Write model definition catalog matching model_catalog_json path
cat << 'EOF' > "$TARGET_DIR/codex-models-with-deepseek.json"
{
  "models": [
    {
      "slug": "deepseek-flash",
      "display_name": "DeepSeek V4.1-Flash",
      "supported_reasoning_levels": [
        {
          "effort": "none",
          "description": "Thinking disabled"
        },
        {
          "effort": "low",
          "description": "Fast responses with lighter reasoning"
        },
        {
          "effort": "high",
          "description": "Greater reasoning depth for complex problems"
        },
        {
          "effort": "max",
          "description": "Maximum reasoning depth"
        }
      ],
      "shell_type": "unified_exec",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 1,
      "support_verbosity": true,
      "truncation_policy": {
        "mode": "bytes",
        "limit": 10000
      },
      "experimental_supported_tools": [],
      "context_window": 1000000,
      "max_context_window": 1000000,
      "auto_review_model_override": "deepseek-flash",
      "base_instructions": "You are DeepSeek V4.1-Flash running in the Codex CLI, a terminal-based coding assistant. You are expected to be precise, safe, and helpful."
    }
  ]
}
EOF

echo "Successfully written configuration files to $TARGET_DIR"
