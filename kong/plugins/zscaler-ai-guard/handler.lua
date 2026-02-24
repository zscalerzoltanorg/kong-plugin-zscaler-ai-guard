-- kong/plugins/zscaler-ai-guard-out/handler.lua
local http  = require "resty.http"
local cjson = require "cjson.safe"

local ZAG_DEFAULT_URL = "https://api.zseclipse.net/v1/detection/execute-policy"

local plugin = {
  PRIORITY = 5,
  VERSION  = "0.2.0",
}

-- =========================
-- Helpers
-- =========================

local function build_block_payload(conf, zag_body)
  local mode = conf.block_mode or "static"           -- "static" | "detailed"
  local msg  = conf.block_message or "Blocked by policy."

  -- Always return at least these:
  local out = {
    error   = "ZSCALER_BLOCK",
    message = msg,
  }

  -- Static mode stops here
  if mode ~= "detailed" then
    return out
  end

  -- Detailed mode
  local decoded = cjson.decode(zag_body)
  if type(decoded) ~= "table" then
    return out
  end

  out.policyId = tonumber(conf.policy_id_out)
  out.action   = decoded.action or "BLOCK"

  if conf.include_transaction_id ~= false then
    out.transactionId = decoded.transactionId
  end

  if conf.include_triggered ~= false then
    local dr = decoded.detectorResponses
    if type(dr) == "table" then
      local triggered = {}
      for detector_name, det in pairs(dr) do
        if type(det) == "table" and (det.triggered == true or (type(det.action)=="string" and det.action:upper()=="BLOCK")) then
          local info = { detector = detector_name }

          if type(det.details) == "table" and type(det.details.detectedSecretTypes) == "table" then
            local types = {}
            for t, _ in pairs(det.details.detectedSecretTypes) do
              types[#types+1] = t
            end
            if #types > 0 then
              info.triggered_types = types
            end
          end

          triggered[#triggered+1] = info
        end
      end
      if #triggered > 0 then
        out.triggered = triggered
      end
    end
  end

  return out
end

local function is_our_block_response(raw_body)
  if not raw_body or raw_body == "" then
    return false
  end

  -- Fast string check avoids JSON decode overhead/edge-cases
  if raw_body:find('"error"%s*:%s*"ZSCALER_BLOCK"') then
    return true
  end

  local decoded = cjson.decode(raw_body)
  if type(decoded) == "table" and decoded.error == "ZSCALER_BLOCK" then
    return true
  end

  return false
end

-- Extract ONLY assistant text from an OpenAI-style chat completion JSON body.
-- Falls back to raw body if it can't decode or doesn't match expected shape.
local function extract_assistant_text(body_text)
  if not body_text or body_text == "" then
    return nil
  end

  local decoded = cjson.decode(body_text)
  if type(decoded) ~= "table" then
    return body_text
  end

  local choices = decoded.choices
  if type(choices) == "table" and type(choices[1]) == "table" then
    local msg = choices[1].message
    if type(msg) == "table" and type(msg.content) == "string" and msg.content ~= "" then
      return msg.content
    end

    if type(choices[1].text) == "string" and choices[1].text ~= "" then
      return choices[1].text
    end
  end

  if type(decoded.output_text) == "string" and decoded.output_text ~= "" then
    return decoded.output_text
  end

  return body_text
end

-- Extract only user prompt content from request JSON:
-- {"messages":[{"role":"user","content":"..."}, ...]}
-- If we can't parse, fall back to raw body (still works, just noisier).
local function extract_user_prompt(raw)
  if not raw or raw == "" then
    return ""
  end

  local decoded = cjson.decode(raw)
  if type(decoded) ~= "table" then
    return raw
  end

  local msgs = decoded.messages
  if type(msgs) ~= "table" then
    return raw
  end

  local parts = {}
  for i = 1, #msgs do
    local m = msgs[i]
    if type(m) == "table" and m.role == "user" then
      local c = m.content
      if type(c) == "string" and c ~= "" then
        parts[#parts + 1] = c
      end
      -- if content is not a string (e.g., multimodal), fall back to tostring
      if type(c) ~= "string" and c ~= nil then
        parts[#parts + 1] = tostring(c)
      end
    end
  end

  if #parts > 0 then
    return table.concat(parts, "\n")
  end

  return raw
end

local function zag_call(conf, direction, content)
  local payload_tbl = {
    policyId  = tonumber(conf.policy_id_out),
    direction = direction,
    content   = content or "",
  }

  local payload = cjson.encode(payload_tbl)
  if not payload then
    return nil, "JSON encode failed"
  end

  local httpc = http.new()
  httpc:set_timeout((conf.timeout_ms or 5000))

  local res, err = httpc:request_uri(conf.zag_url or ZAG_DEFAULT_URL, {
    method     = "POST",
    ssl_verify = (conf.ssl_verify ~= false),
    headers    = {
      ["Authorization"] = "Bearer " .. conf.api_key,
      ["Content-Type"]  = "application/json",
    },
    body = payload,
  })

  if not res then
    return nil, err
  end

  return res
end

local function zag_is_block(res_body)
  if not res_body or res_body == "" then
    return false
  end

  -- Fast path (works with your existing Zscaler responses)
  if res_body:find('"action"%s*:%s*"BLOCK"') then
    return true
  end

  local decoded = cjson.decode(res_body)
  if type(decoded) == "table" then
    local action = decoded.action
    if type(action) == "string" and action:upper() == "BLOCK" then
      return true
    end
    if decoded.blocked == true then
      return true
    end
  end

  return false
end

-- =========================
-- IN: access phase
-- =========================

function plugin:access(conf)
  -- Read request body (must enable "request buffering" implicitly; raw_body works for JSON)
  local raw = kong.request.get_raw_body() or ""
  if raw == "" then
    return
  end

  local prompt_only = extract_user_prompt(raw)

  -- Call Zscaler for IN
  local res, err = zag_call(conf, "IN", prompt_only)
  if not res then
    -- Fail OPEN: allow request if Zscaler is down (better for demos)
    kong.log.err("[zscaler-ai-guard] ZAG IN call failed: ", err)
    kong.ctx.shared.zag_in_allowed = true
    return
  end

  -- Do NOT set zag_in_allowed; OUT will skip on non-2xx anyway
  if zag_is_block(res.body) then
    return kong.response.exit(403, build_block_payload(conf, res.body))
  end

  -- Mark that upstream was allowed to run (optional flag; useful if you later want it)
  kong.ctx.shared.zag_in_allowed = true
end

-- =========================
-- OUT: body_filter + async timer
-- =========================

local function send_out_to_zag(premature, conf, body_text)
  if premature then return end
  if not body_text or body_text == "" then return end

  -- If IN blocked, Kong returned our JSON error; don't scan that as OUT
  if is_our_block_response(body_text) then
    return
  end

  -- Send only assistant content to AI Guard
  local content_only = extract_assistant_text(body_text)
  if not content_only or content_only == "" then
    return
  end

  local res, err = zag_call(conf, "OUT", content_only)
  if not res then
    kong.log.err("[zscaler-ai-guard] ZAG OUT call failed: ", err)
    return
  end

  kong.log.notice("[zscaler-ai-guard] ZAG OUT status=", res.status)
end

function plugin:body_filter(conf)
  -- Skip OUT scanning for non-2xx responses (includes our own 403 blocks)
  local status = kong.response.get_status()
  if not status or status < 200 or status >= 300 then
    return
  end

  -- collect response body chunks safely
  local chunk = ngx.arg[1]
  local eof   = ngx.arg[2]

  kong.ctx.shared.zag_out_buf = kong.ctx.shared.zag_out_buf or {}
  kong.ctx.shared.zag_out_len = kong.ctx.shared.zag_out_len or 0

  if chunk and chunk ~= "" then
    local max = conf.max_bytes or (128 * 1024) -- 128KB
    if kong.ctx.shared.zag_out_len < max then
      local remaining = max - kong.ctx.shared.zag_out_len
      if #chunk > remaining then
        chunk = string.sub(chunk, 1, remaining)
      end
      table.insert(kong.ctx.shared.zag_out_buf, chunk)
      kong.ctx.shared.zag_out_len = kong.ctx.shared.zag_out_len + #chunk
    end
  end

  if eof then
    local full = table.concat(kong.ctx.shared.zag_out_buf or {})
    kong.ctx.shared.zag_out_buf = nil
    kong.ctx.shared.zag_out_len = nil

    if is_our_block_response(full) then
      return
    end

    local ok, terr = ngx.timer.at(0, send_out_to_zag, conf, full)
    if not ok then
      kong.log.err("[zscaler-ai-guard] failed to create timer: ", terr)
    end
  end
end

return plugin
