# Kong Plugin: `zscaler-ai-guard`

Custom Kong HTTP plugin that sends request/response AI content to Zscaler AI Guard for policy evaluation.

This plugin is designed for Kong Gateway HTTP traffic (not stream/TCP plugins).

Repository: `https://github.com/zscalerzoltanorg/kong-plugin-zscaler-ai-guard`

## What This Plugin Does

- Scans inbound request content (`IN`) before proxying upstream
- Can block requests when AI Guard returns a block decision
- Scans outbound response content (`OUT`)
- Returns a minimal, consistent block response payload (`static` or `detailed`)

## Plugin Type

This is an HTTP plugin.

Why:
- The schema uses `protocols_http`
- The handler uses HTTP phase handlers like `access` and `body_filter`

It is not a stream plugin (TCP/UDP/TLS stream).

## Repository Layout

The Kong plugin source is under:

`kong/plugins/zscaler-ai-guard/`

## Deployment vs Configuration (Important)

There are two separate tasks when using a custom Kong plugin:

1. Deploy/load the plugin code on Kong nodes
2. Configure a plugin instance (usually in Kong UI / Konnect UI / Admin API / decK)

This README now prioritizes that split:
- First: how to make Kong load `zscaler-ai-guard`
- Second: how to configure it (preferably in UI/API/decK)

In other words:
- `KONG_PLUGINS` and `KONG_LUA_PACKAGE_PATH` are runtime/bootstrap settings
- `api_key`, `policy_id_out`, `block_mode`, etc. are plugin instance settings

## Installation Options

### Option 1: Docker bind mount (simple for local/dev)

This is the pattern you are already using.

Example `docker run` flags:

```bash
-e "KONG_PLUGINS=bundled,zscaler-ai-guard" \
-e "KONG_LUA_PACKAGE_PATH=/custom-plugins/?.lua;/custom-plugins/?/init.lua;;" \
-v "$(pwd)/zscaler-ai-guard:/custom-plugins:ro" \
```

Notes:
- `KONG_PLUGINS=bundled,zscaler-ai-guard` tells Kong to load the built-in plugins plus this custom one.
- `KONG_LUA_PACKAGE_PATH=...` extends Lua's module lookup path so Kong can find the mounted plugin code.
- The volume mount should expose the plugin tree that contains `kong/plugins/zscaler-ai-guard/...`.
- Your Konnect cert mount is separate and unrelated to this plugin itself.

If you mount the whole plugin folder as shown above, this `KONG_LUA_PACKAGE_PATH` works because Kong will resolve:
- `/custom-plugins/kong/plugins/zscaler-ai-guard/handler.lua`
- `/custom-plugins/kong/plugins/zscaler-ai-guard/schema.lua`

### Option 1b: Docker Compose example

```yaml
services:
  kong:
    image: kong/kong-gateway:3.8
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /kong/declarative/kong.yaml
      KONG_PLUGINS: bundled,zscaler-ai-guard
      KONG_LUA_PACKAGE_PATH: /custom-plugins/?.lua;/custom-plugins/?/init.lua;;
      ZSCALER_AI_GUARD_API_KEY: ${ZSCALER_AI_GUARD_API_KEY}
    volumes:
      - ./zscaler-ai-guard:/custom-plugins:ro
      - ./kong.yaml:/kong/declarative/kong.yaml:ro
    ports:
      - "8000:8000"
      - "8001:8001"
```

### Option 1c: Custom Kong image (recommended for production/self-managed)

Instead of bind mounts, bake the plugin into a custom Kong image:

```dockerfile
FROM kong/kong-gateway:3.8

USER root
COPY zscaler-ai-guard/kong/plugins/zscaler-ai-guard /usr/local/share/lua/5.1/kong/plugins/zscaler-ai-guard
USER kong

ENV KONG_PLUGINS=bundled,zscaler-ai-guard
```

This is usually easier to operate than host mounts in production.

### Option 2: LuaRocks package (cleaner for repeatable installs)

This repo includes a rockspec file so users can install the plugin with LuaRocks.

From the plugin root:

```bash
cd /path/to/zscaler-ai-guard
luarocks make
```

Then enable it in Kong:

```bash
export KONG_PLUGINS="bundled,zscaler-ai-guard"
```

If Kong does not see the installed rock automatically in your environment, you may still need to set `KONG_LUA_PACKAGE_PATH` or install the rock in the same Lua/LuaJIT environment used by Kong.

### Option 3: Manual host install (non-Docker)

Copy the plugin files onto each Kong node so they land under a Lua path like:

`/usr/local/share/lua/5.1/kong/plugins/zscaler-ai-guard/`

Then enable the plugin in your Kong config:

```ini
plugins = bundled,zscaler-ai-guard
```

If you install to a non-default location, set:

```ini
lua_package_path = /path/to/custom-plugins/?.lua;;
```

## Configure the Plugin (UI/API/decK)

Once the code is deployed and Kong can load `zscaler-ai-guard`, create/configure the plugin instance.

Most teams do this in one of these places:

- Kong Manager UI (self-managed Kong Enterprise)
- Konnect UI (Hybrid mode)
- Kong Admin API
- `decK` / declarative config

### Preferred: Configure in UI (Kong Manager or Konnect)

If the plugin schema is available to your control plane, you can configure it in the UI:

1. Open your Service or Route
2. Add plugin: `zscaler-ai-guard`
3. Fill in required fields:
   - `api_key`
   - `policy_id_out`
4. Set recommended fields:
   - `ssl_verify = true`
   - `block_mode = static` (or `detailed`)
   - `timeout_ms` and `max_bytes` as needed
5. Save and test

If the plugin does not appear in the UI, the schema/code has not been loaded correctly yet (see the Konnect Hybrid section below for schema upload).

Minimum required config:

- `api_key` (Zscaler AI Guard API key)
- `policy_id_out` (policy ID used by the plugin for scans)

Example (declarative config snippet):

```yaml
plugins:
  - name: zscaler-ai-guard
    config:
      api_key: "${ZSCALER_AI_GUARD_API_KEY}"
      policy_id_out: 12345
      zag_url: "https://api.zseclipse.net/v1/detection/execute-policy"
      timeout_ms: 5000
      ssl_verify: true
      max_bytes: 131072
      block_mode: "static" # or "detailed"
      block_message: "Blocked by policy."
      include_transaction_id: true
      include_triggered: true
```

Example (Admin API):

```bash
curl -i -X POST http://localhost:8001/plugins \
  --data "name=zscaler-ai-guard" \
  --data "config.api_key=$ZSCALER_AI_GUARD_API_KEY" \
  --data "config.policy_id_out=12345" \
  --data "config.ssl_verify=true"
```

Example (`decK`, self-managed or Konnect-supported workflow for config entities):

```yaml
_format_version: "3.0"

services:
  - name: llm-upstream
    url: https://your-llm-proxy.example.com
    routes:
      - name: llm-route
        paths:
          - /v1/chat/completions

plugins:
  - name: zscaler-ai-guard
    service: llm-upstream
    config:
      api_key: ${ZSCALER_AI_GUARD_API_KEY}
      policy_id_out: 12345
      ssl_verify: true
      block_mode: static
```

## Konnect / Hosted Kong Enterprise Deployment

There are two common Konnect deployment models, and the custom plugin process differs:

### Konnect Hybrid Mode (most common for custom plugins)

You can use this plugin in Konnect Hybrid mode.

Workflow:
1. Upload the plugin `schema.lua` to the Konnect Control Plane (this makes the plugin configurable in Konnect).
2. Install the plugin code (`handler.lua` + `schema.lua`) on every Data Plane node.
3. Enable `zscaler-ai-guard` in each Data Plane node's `KONG_PLUGINS`.
4. Configure the plugin via Konnect UI / API / decK.

Important:
- Konnect only stores the schema/config metadata in Hybrid mode.
- The actual plugin code must exist on every Data Plane node.
- This means the UI configuration experience depends on the schema being uploaded first.

Example schema upload (Konnect Control Plane Config API):

```bash
curl -X POST \
  "https://us.api.konghq.com/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugin-schemas" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  --data "{\"lua_schema\": $(jq -Rs . './kong/plugins/zscaler-ai-guard/schema.lua')}"
```

After schema upload succeeds, configure the plugin in Konnect UI on the target Service/Route (preferred), or via decK/Admin API.

### Konnect Dedicated Cloud Gateways (important limitation)

Kong documents that custom plugins for Dedicated Cloud Gateways cannot set timers.

This plugin currently uses `ngx.timer.at(...)` in `body_filter` for OUT scanning, so it is likely **not compatible** with Dedicated Cloud Gateway custom plugin streaming in its current form.

If you need Dedicated Cloud Gateway support, the plugin would need a refactor to remove timer usage and redesign the OUT processing path accordingly.

## Which Traffic Types This Plugin Covers (HTTP vs Stream)

This plugin is the correct type for most LLM integrations because most AI provider traffic is:

- HTTPS REST/JSON
- HTTPS with chunked responses
- HTTPS Server-Sent Events (SSE) for `stream=true`
- Sometimes gRPC (still HTTP/2-based in Kong's HTTP subsystem)

Kong "stream plugins" are for Layer 4 traffic (TCP/UDP/TLS stream), which is a different plugin subsystem and not how most LLM provider APIs are consumed.

Important terminology note:
- Provider "streaming" (for example `stream=true` token streaming via SSE) is still HTTP traffic.
- Kong "stream plugin" means Kong's Layer 4 stream subsystem, not SSE/chunked HTTP responses.

### Do you need a separate stream plugin?

Usually no.

You would only need a stream plugin if your application communicates with an AI service over non-HTTP protocols (raw TCP/UDP/TLS passthrough), which is uncommon for mainstream LLM providers.

### Is a stream plugin "mostly the same code"?

No. The policy logic idea is reusable, but the implementation would be materially different:

- different phases/PDK APIs
- no HTTP request/response body parsing in the same way
- different buffering and protocol handling
- different enforcement behavior

For this project, documenting it as an **HTTP AI/LLM gateway plugin** is the right approach.

## Current Behavior Notes

- `IN` scan can block before proxying upstream.
- `OUT` scan runs in `body_filter`.
- The plugin only applies to HTTP traffic.
- This plugin currently uses an async timer for OUT processing.
- If you need strict token-by-token enforcement for SSE responses before data is sent to the client, that would require a different HTTP-plugin design (not a Kong stream plugin).

## Security Notes

- `ssl_verify` defaults to `true` and should remain enabled in production.
- `api_key` is declared as an encrypted plugin config field in the schema.
- The plugin avoids logging full Zscaler response bodies by default.

## Packaging and Publishing

This plugin can be distributed by:

- GitHub repository (recommended)
- LuaRocks package (`luarocks make` / `luarocks upload`)
- Internal artifact repository or image-based packaging

For most custom plugins, you host and distribute it yourself; Kong Plugin Hub listing is typically not the path for independent custom plugins unless you are in Kong's partner ecosystem.

## Quick Start (Recommended Path)

If you want the shortest path for most users:

1. Deploy plugin code to Kong (Docker mount for dev, custom image for prod)
2. Set `KONG_PLUGINS=bundled,zscaler-ai-guard`
3. Ensure Kong can resolve the Lua module path (`KONG_LUA_PACKAGE_PATH` if needed)
4. In Kong Manager / Konnect UI, add plugin `zscaler-ai-guard` to a Service or Route
5. Enter `api_key` and `policy_id_out`
6. Test with a known allowed prompt and a known blocked prompt

Use the API/decK examples above if your team manages Kong as code instead of using the UI.
