package = "kong-plugin-zscaler-ai-guard"
version = "0.2.0-1"

source = {
  url = "git+https://github.com/zscalerzoltanorg/kong-plugin-zscaler-ai-guard",
  tag = "0.2.0",
}

description = {
  summary = "Kong plugin for Zscaler AI Guard request/response policy checks",
  homepage = "https://github.com/zscalerzoltanorg/kong-plugin-zscaler-ai-guard",
  license = "Apache-2.0",
}

dependencies = {
  "lua >= 5.1",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.zscaler-ai-guard.handler"] = "kong/plugins/zscaler-ai-guard/handler.lua",
    ["kong.plugins.zscaler-ai-guard.schema"] = "kong/plugins/zscaler-ai-guard/schema.lua",
  }
}
