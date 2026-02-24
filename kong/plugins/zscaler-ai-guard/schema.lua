local typedefs = require "kong.db.schema.typedefs"

return {
  name = "zscaler-ai-guard",
  fields = {
    { consumer  = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- URL optional because handler defaults it
          { zag_url = {
              type = "string",
              default = "https://api.zseclipse.net/v1/detection/execute-policy",
              match = "^https://",
            },
          },

          { api_key = { type = "string", required = true, encrypted = true } },

          -- If you're using the same plugin for IN+OUT, you can keep just OUT for now
          { policy_id_out = { type = "integer", required = true } },

          { timeout_ms = { type = "integer", default = 5000, between = { 1, 60000 } } },
          { ssl_verify = { type = "boolean", default = true } },
          { max_bytes = { type = "integer", default = 131072, between = { 1024, 1048576 } } },

          -- =========================
          -- Block response formatting
          -- =========================

          -- "static" => only {error,message}
          -- "detailed" => add selected fields below
          { block_mode = {
              type = "string",
              default = "static",
              one_of = { "static", "detailed" },
            },
          },

          -- Used for BOTH static and detailed (as the human message)
          { block_message = {
              type = "string",
              default = "Blocked by policy.",
            },
          },

          -- Toggle which fields appear in detailed mode
          { include_transaction_id = { type = "boolean", default = true } },
          { include_triggered = { type = "boolean", default = true } },
        },
      },
    },
  },
}
