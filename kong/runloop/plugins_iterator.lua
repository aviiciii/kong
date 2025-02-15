local workspaces   = require "kong.workspaces"
local constants    = require "kong.constants"
local utils        = require "kong.tools.utils"
local tablepool    = require "tablepool"


local null         = ngx.null
local format       = string.format
local fetch_table  = tablepool.fetch
local release_table = tablepool.release

local TTL_ZERO          = { ttl = 0 }
local GLOBAL_QUERY_OPTS = { workspace = null, show_ws_id = true }

local subsystem = ngx.config.subsystem

local NON_COLLECTING_PHASES, DOWNSTREAM_PHASES, DOWNSTREAM_PHASES_COUNT, COLLECTING_PHASE
do
  if subsystem == "stream" then
    NON_COLLECTING_PHASES = {
      "certificate",
      "log",
    }

    DOWNSTREAM_PHASES = {
      "log",
    }

    COLLECTING_PHASE = "preread"

  else
    NON_COLLECTING_PHASES = {
      "certificate",
      "rewrite",
      "response",
      "header_filter",
      "body_filter",
      "log",
    }

    DOWNSTREAM_PHASES = {
      "response",
      "header_filter",
      "body_filter",
      "log",
    }

    COLLECTING_PHASE = "access"
  end

  DOWNSTREAM_PHASES_COUNT = #DOWNSTREAM_PHASES
end

local PLUGINS_NS = "plugins." .. subsystem

local PluginsIterator = {}

-- Build a compound key by string formatting route_id, service_id, and consumer_id with colons as separators.
--
-- @function build_compound_key
-- @tparam string|nil route_id The route identifier. If `nil`, an empty string is used.
-- @tparam string|nil service_id The service identifier. If `nil`, an empty string is used.
-- @tparam string|nil consumer_id The consumer identifier. If `nil`, an empty string is used.
-- @treturn string The compound key, in the format `route_id:service_id:consumer_id`.
---
function PluginsIterator.build_compound_key(route_id, service_id, consumer_id)
  return format("%s:%s:%s", route_id or "", service_id or "", consumer_id or "")
end

local function get_table_for_ctx(ws)
  local tbl = fetch_table(PLUGINS_NS, 0, DOWNSTREAM_PHASES_COUNT + 2)
  if not tbl.initialized then
    for i = 1, DOWNSTREAM_PHASES_COUNT do
      tbl[DOWNSTREAM_PHASES[i]] = kong.table.new(ws.plugins[0] * 2, 1)
    end
    tbl.initialized = true
  end

  for i = 1, DOWNSTREAM_PHASES_COUNT do
    tbl[DOWNSTREAM_PHASES[i]][0] = 0
  end

  tbl.ws = ws

  return tbl
end

local function release(ctx)
  local plugins = ctx.plugins
  if plugins then
    release_table(PLUGINS_NS, plugins, true)
    ctx.plugins = nil
  end
end


local enabled_plugins
local loaded_plugins


local function get_loaded_plugins()
  return assert(kong.db.plugins:get_handlers())
end


local function should_process_plugin(plugin)
  if plugin.enabled then
    local c = constants.PROTOCOLS_WITH_SUBSYSTEM
    for _, protocol in ipairs(plugin.protocols) do
      if c[protocol] == subsystem then
        return true
      end
    end
  end
end


local next_seq = 0

local function get_plugin_config(plugin, name, ws_id)
  if not plugin or not plugin.enabled then
    return
  end

  local cfg = plugin.config or {}

  cfg.route_id    = plugin.route    and plugin.route.id
  cfg.service_id  = plugin.service  and plugin.service.id
  cfg.consumer_id = plugin.consumer and plugin.consumer.id
  cfg.plugin_instance_name = plugin.instance_name
  cfg.__plugin_id = plugin.id

  local key = kong.db.plugins:cache_key(name,
                                        cfg.route_id,
                                        cfg.service_id,
                                        cfg.consumer_id,
                                        nil,
                                        ws_id)

  -- TODO: deprecate usage of __key__ as id of plugin
  if not cfg.__key__ then
    cfg.__key__ = key
    cfg.__seq__ = next_seq
    next_seq = next_seq + 1
  end

  return cfg
end

---
-- Lookup a configuration for a given combination of route_id, service_id, consumer_id
--
-- The function checks various combinations of route_id, service_id and consumer_id to find
-- the best matching configuration in the given 'combos' table. The priority order is as follows:
--
-- Route, Service, Consumer
-- Route, Consumer
-- Service, Consumer
-- Route, Service
-- Consumer
-- Route
-- Service
-- Global
--
-- @function lookup_cfg
-- @tparam table combos A table containing configuration data indexed by compound keys.
-- @tparam string|nil route_id The route identifier.
-- @tparam string|nil service_id The service identifier.
-- @tparam string|nil consumer_id The consumer identifier.
-- @return any|nil The configuration corresponding to the best matching combination, or 'nil' if no configuration is found.
---
function PluginsIterator.lookup_cfg(combos, route_id, service_id, consumer_id)
  -- Use the build_compound_key function to create an index for the 'combos' table
  local build_compound_key = PluginsIterator.build_compound_key

    local key
    if route_id and service_id and consumer_id then
        key = build_compound_key(route_id, service_id, consumer_id)
        if combos[key] then
            return combos[key]
        end
    end
    if route_id and consumer_id then
        key = build_compound_key(route_id, nil, consumer_id)
        if combos[key] then
            return combos[key]
        end
    end
    if service_id and consumer_id then
        key = build_compound_key(nil, service_id, consumer_id)
        if combos[key] then
            return combos[key]
        end
    end
    if route_id and service_id then
        key = build_compound_key(route_id, service_id, nil)
        if combos[key] then
            return combos[key]
        end
    end
    if consumer_id then
        key = build_compound_key(nil, nil, consumer_id)
        if combos[key] then
            return combos[key]
        end
    end
    if route_id then
        key = build_compound_key(route_id, nil, nil)
        if combos[key] then
            return combos[key]
        end
    end
    if service_id then
        key = build_compound_key(nil, service_id, nil)
        if combos[key] then
            return combos[key]
        end
    end
    return combos[build_compound_key(nil, nil, nil)]

end


---
-- Load the plugin configuration based on the context (route, service, and consumer) and plugin handler rules.
--
-- This function filters out route, service, and consumer information from the context based on the plugin handler rules,
-- and then calls the 'lookup_cfg' function to get the best matching plugin configuration for the given combination of
-- route_id, service_id, and consumer_id.
--
-- @function load_configuration_through_combos
-- @tparam table ctx A table containing the context information, including route, service, and authenticated_consumer.
-- @tparam table combos A table containing configuration data indexed by compound keys.
-- @tparam table plugin A table containing plugin information, including the handler with no_route, no_service, and no_consumer rules.
-- @treturn any|nil The configuration corresponding to the best matching combination, or 'nil' if no configuration is found.
---
local function load_configuration_through_combos(ctx, combos, plugin)

    -- Filter out route, service, and consumer based on the plugin handler rules and get their ids
  local route_id = (ctx.route and not plugin.handler.no_route) and ctx.route.id or nil
  local service_id = (ctx.service and not plugin.handler.no_service) and ctx.service.id or nil
  -- TODO: kong.client.get_consumer() for more consistency. This might be an exception though as we're aiming for raw speed instead of compliance.
  local consumer_id = (ctx.authenticated_consumer and not plugin.handler.no_consumer) and ctx.authenticated_consumer.id or nil

  -- Call the lookup_cfg function to get the best matching plugin configuration
  return PluginsIterator.lookup_cfg(combos, route_id, service_id, consumer_id)
end

local function get_workspace(self, ctx)
  if not ctx then
    return self.ws[kong.default_workspace]
  end

  return self.ws[workspaces.get_workspace_id(ctx) or kong.default_workspace]
end

local function get_next_init_worker(plugins, i)
  local i = i + 1
  local plugin = plugins[i]
  if not plugin then
    return nil
  end

  if plugin.handler.init_worker then
    return i, plugin
  end

  return get_next_init_worker(plugins, i)
end


local function get_init_worker_iterator(self)
  if #self.loaded == 0 then
    return nil
  end

  return get_next_init_worker, self.loaded
end


local function get_next_global_or_collected_plugin(plugins, i)
  i = i + 2
  if i > plugins[0] then
    return nil
  end
  local cfg = kong.vault.update(plugins[i])
  return i, plugins[i - 1], cfg
end


local function get_global_iterator(self, phase)
  local plugins = self.globals[phase]
  if plugins[0] == 0 then
    return nil
  end

  return get_next_global_or_collected_plugin, plugins
end


local function get_collected_iterator(self, phase, ctx)
  local plugins = ctx.plugins
  if plugins then
    plugins = plugins[phase]
    if plugins[0] == 0 then
      return nil
    end

    return get_next_global_or_collected_plugin, plugins
  end

  return get_global_iterator(self, phase)
end


local function get_next_and_collect(ctx, i)
  i = i + 1
  local ws = ctx.plugins.ws
  local plugins = ws.plugins
  if i > plugins[0] then
    return nil
  end

  local plugin = plugins[i]
  local name = plugin.name
  local cfg
  local combos = ws.combos[name]
  if combos then
    cfg = load_configuration_through_combos(ctx, combos, plugin)
    if cfg then
      cfg = kong.vault.update(cfg)
      local handler = plugin.handler
      local collected = ctx.plugins
      for j = 1, DOWNSTREAM_PHASES_COUNT do
        local phase = DOWNSTREAM_PHASES[j]
        if handler[phase] then
          local n = collected[phase][0] + 2
          collected[phase][0] = n
          collected[phase][n] = cfg
          collected[phase][n-1] = plugin
          if phase == "response" and not ctx.buffered_proxying then
            ctx.buffered_proxying = true
          end
        end
      end

      if handler[COLLECTING_PHASE] then
        return i, plugin, cfg
      end
    end
  end

  return get_next_and_collect(ctx, i)
end

local function get_collecting_iterator(self, ctx)
  local ws = get_workspace(self, ctx)
  if not ws then
    return nil
  end

  local plugins = ws.plugins
  if plugins[0] == 0 then
    return nil
  end

  ctx.plugins = get_table_for_ctx(ws)

  return get_next_and_collect, ctx
end

local function new_ws_data()
  return {
    plugins = { [0] = 0 },
    combos = {},
  }
end


function PluginsIterator.new(version)
  if kong.db.strategy ~= "off" then
    if not version then
      error("version must be given", 2)
    end
  end

  loaded_plugins = loaded_plugins or get_loaded_plugins()
  enabled_plugins = enabled_plugins or kong.configuration.loaded_plugins

  local ws_id = workspaces.get_workspace_id() or kong.default_workspace
  local ws = {
    [ws_id] = new_ws_data()
  }

  local counter = 0
  local page_size = kong.db.plugins.pagination.max_page_size
  local globals
  do
    globals = {}
    for _, phase in ipairs(NON_COLLECTING_PHASES) do
      globals[phase] = { [0] = 0 }
    end
  end

  local has_plugins = false

  for plugin, err in kong.db.plugins:each(page_size, GLOBAL_QUERY_OPTS) do
    if err then
      return nil, err
    end

    local name = plugin.name
    if not enabled_plugins[name] then
      return nil, name .. " plugin is in use but not enabled"
    end

    local data = ws[plugin.ws_id]
    if not data then
      data = new_ws_data()
      ws[plugin.ws_id] = data
    end
    local plugins = data.plugins
    local combos = data.combos

    if kong.core_cache
       and counter > 0
       and counter % page_size == 0
       and kong.db.strategy ~= "off" then

      local new_version, err = kong.core_cache:get("plugins_iterator:version", TTL_ZERO, utils.uuid)
      if err then
        return nil, "failed to retrieve plugins iterator version: " .. err
      end

      if new_version ~= version then
        -- the plugins iterator rebuild is being done by a different process at
        -- the same time, stop here and let the other one go for it
        kong.log.info("plugins iterator was changed while rebuilding it")
        return
      end
    end

    if should_process_plugin(plugin) then
      if not has_plugins then
        has_plugins = true
      end

      plugins[name] = true

      -- Retrieve route_id, service_id, and consumer_id from the plugin object, if they exist
      local route_id = plugin.route and plugin.route.id
      local service_id = plugin.service and plugin.service.id
      local consumer_id = plugin.consumer and plugin.consumer.id

      -- Get the plugin configuration for the specified workspace (ws_id)
      local cfg = get_plugin_config(plugin, name, plugin.ws_id)
      -- Determine if the plugin configuration is global (i.e., not tied to any route, service, consumer or group)
      local is_global = not route_id and not service_id and not consumer_id and plugin.ws_id == kong.default_workspace
      if is_global then
        -- Store the global configuration for the plugin in the 'globals' table
        globals[name] = cfg
      end

      if cfg then
        -- Initialize an empty table for the plugin in the 'combos' table if it doesn't already exist
        combos[name] = combos[name] or {}

        -- Build a compound key using the route_id, service_id, and consumer_id
        local compound_key = PluginsIterator.build_compound_key(route_id, service_id, consumer_id)

        -- Store the plugin configuration in the 'combos' table using the compound key
        combos[name][compound_key] = cfg
      end
    end
    counter = counter + 1
  end

  for _, plugin in ipairs(loaded_plugins) do
    local name = plugin.name
    for _, data in pairs(ws) do
      local plugins = data.plugins
      if plugins[name] then
        local n = plugins[0] + 1
        plugins[n] = plugin
        plugins[0] = n
        plugins[name] = nil
      end
    end

    local cfg = globals[name]
    if cfg then
      for _, phase in ipairs(NON_COLLECTING_PHASES) do
        if plugin.handler[phase] then
          local plugins = globals[phase]
          local n = plugins[0] + 2
          plugins[0] = n
          plugins[n] = cfg
          plugins[n - 1] = plugin
        end
      end
    end
  end

  return {
    version = version,
    ws = ws,
    loaded = loaded_plugins,
    globals = globals,
    get_init_worker_iterator = get_init_worker_iterator,
    get_global_iterator = get_global_iterator,
    get_collecting_iterator = get_collecting_iterator,
    get_collected_iterator = get_collected_iterator,
    has_plugins = has_plugins,
    release = release,
  }
end

return PluginsIterator
