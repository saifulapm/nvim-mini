local Helpers = {}

-- Add extra expectations
Helpers.expect = vim.deepcopy(MiniTest.expect)

Helpers.expect.match = MiniTest.new_expectation(
  'string matching',
  function(str, pattern) return str:find(pattern) ~= nil end,
  function(str, pattern) return string.format('Pattern: %s\nObserved string: %s', vim.inspect(pattern), str) end
)

Helpers.expect.no_match = MiniTest.new_expectation(
  'no string matching',
  function(str, pattern) return str:find(pattern) == nil end,
  function(str, pattern) return string.format('Pattern: %s\nObserved string: %s', vim.inspect(pattern), str) end
)

-- Monkey-patch `MiniTest.new_child_neovim` with helpful wrappers
Helpers.new_child_neovim = function()
  local child = MiniTest.new_child_neovim()

  local prevent_hanging = function(method)
    -- stylua: ignore
    if not child.is_blocked() then return end

    local msg = string.format('Can not use `child.%s` because child process is blocked.', method)
    error(msg)
  end

  child.setup = function()
    child.restart({ '-u', 'lua/mini-dev/minimal_init.lua' })

    -- Change initial buffer to be readonly. This not only increases execution
    -- speed, but more closely resembles manually opened Neovim.
    child.bo.readonly = false
  end

  child.set_lines = function(arr, start, finish)
    prevent_hanging('set_lines')

    if type(arr) == 'string' then arr = vim.split(arr, '\n') end

    child.api.nvim_buf_set_lines(0, start or 0, finish or -1, false, arr)
  end

  child.get_lines = function(start, finish)
    prevent_hanging('get_lines')

    return child.api.nvim_buf_get_lines(0, start or 0, finish or -1, false)
  end

  child.set_cursor = function(line, column, win_id)
    prevent_hanging('set_cursor')

    child.api.nvim_win_set_cursor(win_id or 0, { line, column })
  end

  child.get_cursor = function(win_id)
    prevent_hanging('get_cursor')

    return child.api.nvim_win_get_cursor(win_id or 0)
  end

  child.set_size = function(lines, columns)
    prevent_hanging('set_size')

    if type(lines) == 'number' then child.o.lines = lines end

    if type(columns) == 'number' then child.o.columns = columns end
  end

  child.get_size = function()
    prevent_hanging('get_size')

    return { child.o.lines, child.o.columns }
  end

  --- Assert visual marks
  ---
  --- Useful to validate visual selection
  ---
  ---@param first number|table Table with start position or number to check linewise.
  ---@param last number|table Table with finish position or number to check linewise.
  ---@private
  child.expect_visual_marks = function(first, last)
    child.ensure_normal_mode()

    first = type(first) == 'number' and { first, 0 } or first
    last = type(last) == 'number' and { last, 2147483647 } or last

    MiniTest.expect.equality(child.api.nvim_buf_get_mark(0, '<'), first)
    MiniTest.expect.equality(child.api.nvim_buf_get_mark(0, '>'), last)
  end

  -- Work with 'mini.nvim':
  -- - `mini_load` - load with "normal" table config
  -- - `mini_load_strconfig` - load with "string" config, which is still a
  --   table but with string values. Final loading is done by constructing
  --   final string table. Needed to be used if one of the config entries is a
  --   function (as currently there is no way to communicate a function object
  --   through RPC).
  -- - `mini_unload` - unload module and revert common side effects.
  child.mini_load = function(name, config)
    local lua_cmd = ([[require('mini-dev.%s').setup(...)]]):format(name)
    child.lua(lua_cmd, { config })
  end

  child.mini_load_strconfig = function(name, strconfig)
    local t = {}
    for key, val in pairs(strconfig) do
      table.insert(t, key .. ' = ' .. val)
    end
    local str = string.format('{ %s }', table.concat(t, ', '))

    local command = ([[require('mini-dev.%s').setup(%s)]]):format(name, str)
    child.lua(command)
  end

  child.mini_unload = function(name)
    local module_name = 'mini-dev.' .. name
    local tbl_name = 'Mini' .. name:sub(1, 1):upper() .. name:sub(2)

    -- Unload Lua module
    child.lua(([[package.loaded['%s'] = nil]]):format(module_name))

    -- Remove global table
    child.lua(('_G[%s] = nil'):format(tbl_name))

    -- Remove autocmd group
    if child.fn.exists('#' .. tbl_name) == 1 then
      -- NOTE: having this in one line as `'augroup %s | au! | augroup END'`
      -- for some reason seemed to sometimes not execute `augroup END` part.
      -- That lead to a subsequent bare `au ...` calls to be inside `tbl_name`
      -- group, which gets empty after every `require(<module_name>)` call.
      child.cmd(('augroup %s'):format(tbl_name))
      child.cmd('au!')
      child.cmd('augroup END')
    end
  end

  child.expect_screenshot = function(opts, path, screenshot_opts)
    if child.fn.has('nvim-0.8') == 0 then MiniTest.skip('Screenshots are tested for Neovim>=0.8 (for simplicity).') end

    MiniTest.expect.reference_screenshot(child.get_screenshot(screenshot_opts), path, opts)
  end

  return child
end

-- Mark test failure as "flaky"
Helpers.mark_flaky = function()
  MiniTest.finally(function()
    if #MiniTest.current.case.exec.fails > 0 then MiniTest.add_note('This test is flaky.') end
  end)
end

return Helpers
