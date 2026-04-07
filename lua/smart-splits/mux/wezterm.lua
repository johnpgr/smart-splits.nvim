local Direction = require('smart-splits.types').Direction
local config = require('smart-splits.config')

local dir_keys_wezterm = {
  [Direction.left] = 'Left',
  [Direction.right] = 'Right',
  [Direction.down] = 'Down',
  [Direction.up] = 'Up',
}

local dir_keys_wezterm_splits = {
  [Direction.left] = '--left',
  [Direction.right] = '--right',
  [Direction.up] = '--top',
  [Direction.down] = '--bottom',
}

--- Synchronous CLI call — used for edge-detection and pane-info refresh
local function wezterm_exec(cmd)
  local command = vim.deepcopy(cmd)
  table.insert(command, 1, config.wezterm_cli_path)
  table.insert(command, 2, 'cli')
  return require('smart-splits.utils').system(command)
end

--- Fire-and-forget CLI call — used for split actions
local function wezterm_exec_async(cmd)
  local command = vim.deepcopy(cmd)
  table.insert(command, 1, config.wezterm_cli_path)
  table.insert(command, 2, 'cli')
  vim.system(command, { text = true })
end

-- Monotonic counter: incremented only when next_pane verifies a neighbor
-- exists. move_multiplexer_inner compares current_pane_id() before/after
-- next_pane() to decide whether the multiplexer actually switched panes.
local pane_id_counter = 0

-- Unique sequence number for OSC commands so repeated identical actions
-- still trigger wezterm's user-var-changed handler.
local command_sequence = 0

-- Cached directional adjacency, keyed by wezterm direction names.
local edge_cache = {}

-- Cached pane metadata (zoom state, etc.), refreshed on layout events
local cached_pane_info = nil

local function set_wezterm_user_var(name, value)
  local format_var = vim.fn['smart_splits#format_wezterm_user_var']
  local write_var = vim.fn['smart_splits#write_wezterm_var']
  return write_var(format_var(name, value))
end

local function has_neighbor_for_output(output)
  return output ~= nil and #vim.trim(output) > 0
end

local function refresh_edge_for_direction(direction)
  local wezterm_direction = dir_keys_wezterm[direction]
  if not wezterm_direction then
    return nil
  end

  local output, code = wezterm_exec({ 'get-pane-direction', wezterm_direction })
  if code == 0 then
    local has_neighbor = has_neighbor_for_output(output or '')
    edge_cache[wezterm_direction] = has_neighbor
    return has_neighbor
  end

  edge_cache[wezterm_direction] = nil
  return nil
end

local function refresh_pane_info()
  local output, code = wezterm_exec({ 'list', '--format', 'json' })
  if code ~= 0 or not output or #output == 0 then
    cached_pane_info = nil
    return
  end

  local ok, data = pcall(vim.json.decode, output)
  if not ok or type(data) ~= 'table' then
    cached_pane_info = nil
    return
  end

  local pane_id = vim.env.WEZTERM_PANE
  for _, pane in ipairs(data) do
    if tostring(pane.pane_id) == pane_id then
      cached_pane_info = pane
      return
    end
  end
  cached_pane_info = nil
end

---@type SmartSplitsMultiplexer
local M = {} ---@diagnostic disable-line: missing-fields

M.type = 'wezterm'

function M.current_pane_id()
  return pane_id_counter
end

function M.current_pane_at_edge(direction)
  local wezterm_direction = dir_keys_wezterm[direction]
  if not wezterm_direction then
    return false
  end

  local has_neighbor = edge_cache[wezterm_direction]
  if has_neighbor == nil then
    has_neighbor = refresh_edge_for_direction(direction)
  end

  if has_neighbor ~= nil then
    return not has_neighbor
  end

  -- Fallback for older wezterm without get-pane-direction:
  -- assume not at edge so navigation is attempted.
  return false
end

function M.is_in_session()
  return vim.env.WEZTERM_PANE ~= nil
end

function M.current_pane_is_zoomed()
  if cached_pane_info == nil then
    refresh_pane_info()
  end

  if cached_pane_info then
    return cached_pane_info.is_zoomed == true
  end
  return false
end

function M.next_pane(direction)
  if not M.is_in_session() then
    return false
  end

  -- Guard: don't report a move that wezterm will ignore
  if M.current_pane_at_edge(direction) then
    return false
  end

  local wezterm_direction = dir_keys_wezterm[direction]
  if not wezterm_direction then
    return false
  end

  command_sequence = command_sequence + 1
  local ok = set_wezterm_user_var('SMART_SPLITS_CMD', string.format('move:%s:%d', wezterm_direction, command_sequence))
  if not ok then
    return false
  end

  pane_id_counter = pane_id_counter + 1
  return true
end

function M.resize_pane(direction, amount)
  if not M.is_in_session() then
    return false
  end

  local wezterm_direction = dir_keys_wezterm[direction]
  if not wezterm_direction then
    return false
  end

  command_sequence = command_sequence + 1
  return set_wezterm_user_var(
    'SMART_SPLITS_CMD',
    string.format('resize:%s:%s:%d', wezterm_direction, tostring(amount), command_sequence)
  )
end

function M.split_pane(direction, size)
  local args = { 'split-pane', dir_keys_wezterm_splits[direction] }
  if size then
    table.insert(args, '--cells')
    table.insert(args, size)
  end
  wezterm_exec_async(args)
  return true
end

function M.on_init()
  local format_var = vim.fn['smart_splits#format_wezterm_var']
  local write_var = vim.fn['smart_splits#write_wezterm_var']
  write_var(format_var('true'))
end

function M.on_exit()
  local format_var = vim.fn['smart_splits#format_wezterm_var']
  local write_var = vim.fn['smart_splits#write_wezterm_var']
  write_var(format_var('false'))
end

function M.update_mux_layout_details()
  for direction, wezterm_direction in pairs(dir_keys_wezterm) do
    edge_cache[wezterm_direction] = refresh_edge_for_direction(direction)
  end
  refresh_pane_info()
end

return M
