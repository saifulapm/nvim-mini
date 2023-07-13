local helpers = dofile('lua/mini-dev/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
--stylua: ignore start
local load_module = function(config) child.mini_load('clue', config) end
local unload_module = function() child.mini_unload('clue') end
local reload_module = function(config) unload_module(); load_module(config) end
local set_cursor = function(...) return child.set_cursor(...) end
local get_cursor = function(...) return child.get_cursor(...) end
local set_lines = function(...) return child.set_lines(...) end
local get_lines = function(...) return child.get_lines(...) end
local type_keys = function(...) return child.type_keys(...) end
local poke_eventloop = function() child.api.nvim_eval('1') end
local sleep = function(ms) vim.loop.sleep(ms); poke_eventloop() end
--stylua: ignore end

-- Mapping helpers
local replace_termcodes = function(x) return vim.api.nvim_replace_termcodes(x, true, false, true) end

local reset_test_map_count = function(mode, lhs)
  local lua_cmd = string.format([[_G['test_map_%s_%s'] = 0]], mode, replace_termcodes(lhs))
  child.lua(lua_cmd)
end

local get_test_map_count = function(mode, lhs)
  local lua_cmd = string.format([=[_G['test_map_%s_%s']]=], mode, replace_termcodes(lhs))
  return child.lua_get(lua_cmd)
end

local make_test_map = function(mode, lhs, opts)
  lhs = replace_termcodes(lhs)
  opts = opts or {}

  reset_test_map_count(mode, lhs)

  --stylua: ignore
  local lua_cmd = string.format(
    [[vim.keymap.set('%s', '%s', function() _G['test_map_%s_%s'] = _G['test_map_%s_%s'] + 1 end, %s)]],
    mode, lhs,
    mode, lhs,
    mode, lhs,
    vim.inspect(opts)
  )
  child.lua(lua_cmd)
end

-- Custom validators
local validate_trigger_keymap = function(mode, keys)
  local lua_cmd =
    string.format('vim.fn.maparg(%s, %s, false, true).desc', vim.inspect(replace_termcodes(keys)), vim.inspect(mode))
  local map_desc = child.lua_get(lua_cmd)

  -- Neovim<0.8 doesn't have `keytrans()` used inside description
  if child.fn.has('nvim-0.8') == 0 then
    eq(type(map_desc), 'string')
  else
    local desc_pattern = 'clues after.*"' .. vim.pesc(keys) .. '"'
    expect.match(map_desc, desc_pattern)
  end
end

local validate_edit = function(lines_before, cursor_before, keys, lines_after, cursor_after)
  child.ensure_normal_mode()
  set_lines(lines_before)
  set_cursor(cursor_before[1], cursor_before[2])

  type_keys(keys)

  eq(get_lines(), lines_after)
  eq(get_cursor(), cursor_after)

  child.ensure_normal_mode()
end

local validate_edit1d = function(line_before, col_before, keys, line_after, col_after)
  validate_edit({ line_before }, { 1, col_before }, keys, { line_after }, { 1, col_after })
end

local validate_move =
  function(lines, cursor_before, keys, cursor_after) validate_edit(lines, cursor_before, keys, lines, cursor_after) end

local validate_move1d =
  function(line, col_before, keys, col_after) validate_edit1d(line, col_before, keys, line, col_after) end

local validate_selection = function(lines, cursor, keys, selection_from, selection_to, visual_mode)
  visual_mode = visual_mode or 'v'
  child.ensure_normal_mode()
  set_lines(lines)
  set_cursor(cursor[1], cursor[2])

  type_keys(keys)
  eq(child.fn.mode(), visual_mode)
  eq({ child.fn.line('v'), child.fn.col('v') - 1 }, selection_from)
  eq({ child.fn.line('.'), child.fn.col('.') - 1 }, selection_to)

  child.ensure_normal_mode()
end

local validate_selection1d = function(line, col, keys, selection_col_from, selection_col_to, visual_mode)
  validate_selection({ line }, { 1, col }, keys, { 1, selection_col_from }, { 1, selection_col_to }, visual_mode)
end

-- Data =======================================================================

-- Output test set ============================================================
T = new_set({
  hooks = {
    pre_case = function() child.setup() end,
    post_once = child.stop,
  },
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  load_module()

  -- Global variable
  eq(child.lua_get('type(_G.MiniClue)'), 'table')

  -- Autocommand group
  eq(child.fn.exists('#MiniClue'), 1)

  -- Highlight groups
  local validate_hl_group = function(name, ref) expect.match(child.cmd_capture('hi ' .. name), ref) end

  validate_hl_group('MiniClueBorder', 'links to FloatBorder')
  validate_hl_group('MiniClueGroup', 'links to DiagnosticFloatingWarn')
  validate_hl_group('MiniClueNextKey', 'links to DiagnosticFloatingHint')
  validate_hl_group('MiniClueNormal', 'links to NormalFloat')
  validate_hl_group('MiniClueSingle', 'links to DiagnosticFloatingInfo')
  validate_hl_group('MiniClueTitle', 'links to FloatTitle')
end

T['setup()']['creates `config` field'] = function()
  load_module()

  eq(child.lua_get('type(_G.MiniClue.config)'), 'table')

  -- Check default values
  local expect_config = function(field, value) eq(child.lua_get('MiniClue.config.' .. field), value) end

  -- expect_config('clues', {})
  -- expect_config('triggers', {})
  --
  -- expect_config('window.delay', 100)
  -- expect_config('window.config', {})
end

T['setup()']['respects `config` argument'] = function()
  load_module({ window = { delay = 10 } })
  eq(child.lua_get('MiniClue.config.window.delay'), 10)
end

T['setup()']['validates `config` argument'] = function()
  local expect_config_error = function(config, name, target_type)
    expect.error(load_module, vim.pesc(name) .. '.*' .. vim.pesc(target_type), config)
  end

  expect_config_error('a', 'config', 'table')

  expect_config_error({ clues = 'a' }, 'clues', 'table')
  expect_config_error({ triggers = 'a' }, 'triggers', 'table')

  expect_config_error({ window = 'a' }, 'window', 'table')
  expect_config_error({ window = { delay = 'a' } }, 'window.delay', 'number')
  expect_config_error({ window = { config = 'a' } }, 'window.config', 'table')
end

-- T['setup()']['respects "human-readable" key names'] = function()
--   -- In `clues` (`keys` and 'postkeys')
--
--   -- In `triggers`
--   MiniTest.skip()
-- end

-- T['setup()']['respects explicit `<Leader>`'] = function()
--   -- In `clues` (`keys` and 'postkeys')
--
--   -- In `triggers`
--   MiniTest.skip()
-- end

-- T['setup()']['respects "raw" key names'] = function()
--   -- In `clues` (`keys` and 'postkeys')
--
--   -- In `triggers`
--   MiniTest.skip()
-- end

T['execute_without_triggers()'] = new_set()

T['execute_without_triggers()']['works'] = function() MiniTest.skip() end

-- Integration tests ==========================================================
T['Reproducing keys'] = new_set()

T['Reproducing keys']['works for builtin keymaps in Normal mode'] = function()
  load_module({ triggers = { { mode = 'n', keys = 'g' } } })
  validate_trigger_keymap('n', 'g')

  -- `ge` (basic test)
  validate_move1d('aa bb', 3, 'ge', 1)

  -- `gg` (should avoid infinite recursion)
  validate_move({ 'aa', 'bb' }, { 2, 0 }, 'gg', { 1, 0 })

  -- `g~` (should work with operators)
  validate_edit1d('aa bb', 0, 'g~iw', 'AA bb', 0)

  -- `g'a` (should work with more than one character ahead)
  set_lines({ 'aa', 'bb' })
  set_cursor(2, 0)
  type_keys('ma')
  set_cursor(1, 0)
  type_keys("g'a")
  eq(get_cursor(), { 2, 0 })
end

T['Reproducing keys']['works for user keymaps in Normal mode'] = function()
  -- Should work for both keymap created before and after making trigger
  make_test_map('n', '<Space>f')
  load_module({ triggers = { { mode = 'n', keys = '<Space>' } } })
  make_test_map('n', '<Space>g')

  validate_trigger_keymap('n', '<Space>')

  type_keys(' f')
  eq(get_test_map_count('n', ' f'), 1)
  eq(get_test_map_count('n', ' g'), 0)

  type_keys(' g')
  eq(get_test_map_count('n', ' f'), 1)
  eq(get_test_map_count('n', ' g'), 1)
end

T['Reproducing keys']['respects `[count]` in Normal mode'] = function()
  load_module({ triggers = { { mode = 'n', keys = 'g' } } })
  validate_trigger_keymap('n', 'g')

  validate_move1d('aa bb cc', 6, '2ge', 1)
end

T['Reproducing keys']['works for builtin keymaps in Insert mode'] = function()
  load_module({ triggers = { { mode = 'i', keys = '<C-x>' } } })
  validate_trigger_keymap('i', '<C-X>')

  set_lines({ 'aa aa', 'bb bb', '' })
  set_cursor(3, 0)
  type_keys('i', '<C-x><C-l>')

  eq(child.fn.mode(), 'i')
  local complete_words = vim.tbl_map(function(x) return x.word end, child.fn.complete_info().items)
  eq(complete_words, { 'aa aa', 'bb bb' })
end

T['Reproducing keys']['works for user keymaps in Insert mode'] = function()
  -- Should work for both keymap created before and after making trigger
  make_test_map('i', '<Space>f')
  load_module({ triggers = { { mode = 'i', keys = '<Space>' } } })
  make_test_map('i', '<Space>g')

  validate_trigger_keymap('i', '<Space>')

  child.cmd('startinsert')

  type_keys(' f')
  eq(child.fn.mode(), 'i')
  eq(get_test_map_count('i', ' f'), 1)
  eq(get_test_map_count('i', ' g'), 0)

  type_keys(' g')
  eq(child.fn.mode(), 'i')
  eq(get_test_map_count('i', ' f'), 1)
  eq(get_test_map_count('i', ' g'), 1)
end

T['Reproducing keys']['works for builtin keymaps in Visual mode'] = function()
  load_module({ triggers = { { mode = 'x', keys = 'g' }, { mode = 'x', keys = 'a' } } })
  validate_trigger_keymap('x', 'g')
  validate_trigger_keymap('x', 'a')

  -- `a'` (should work to update selection)
  validate_selection1d("'aa'", 1, "va'", 0, 3)

  -- Should preserve Visual submode
  validate_selection({ 'aa', 'bb', '', 'cc' }, { 1, 0 }, 'Vap', { 1, 0 }, { 3, 0 }, 'V')
  validate_selection1d("'aa'", 1, "<C-v>a'", 0, 3, replace_termcodes('<C-v>'))

  -- `g?` (should work to manipulation selection)
  validate_edit1d('aa bb', 0, 'viwg?', 'nn bb', 0)
end

T['Reproducing keys']['works for user keymaps in Visual mode'] = function()
  -- Should work for both keymap created before and after making trigger
  make_test_map('x', '<Space>f')
  load_module({ triggers = { { mode = 'x', keys = '<Space>' } } })
  make_test_map('x', '<Space>g')

  validate_trigger_keymap('x', '<Space>')

  type_keys('v')

  type_keys(' f')
  eq(child.fn.mode(), 'v')
  eq(get_test_map_count('x', ' f'), 1)
  eq(get_test_map_count('x', ' g'), 0)

  type_keys(' g')
  eq(child.fn.mode(), 'v')
  eq(get_test_map_count('x', ' f'), 1)
  eq(get_test_map_count('x', ' g'), 1)

  -- Should preserve Visual submode
  child.ensure_normal_mode()
  type_keys('V')
  type_keys(' f')
  eq(child.fn.mode(), 'V')
  eq(get_test_map_count('x', ' f'), 2)

  child.ensure_normal_mode()
  type_keys('<C-v>')
  type_keys(' f')
  eq(child.fn.mode(), replace_termcodes('<C-v>'))
  eq(get_test_map_count('x', ' f'), 3)
end

T['Reproducing keys']['respects `[count]` in Visual mode'] = function()
  load_module({ triggers = { { mode = 'x', keys = 'a' } } })
  validate_trigger_keymap('x', 'a')

  validate_selection1d('aa bb cc', 0, 'v2aw', 0, 5)
end

T['Reproducing keys']['Operator-pending mode'] = new_set({
  hooks = {
    pre_case = function()
      -- Make user keymap
      child.api.nvim_set_keymap('o', 'if', 'iw', {})
      child.api.nvim_set_keymap('o', 'iF', 'ip', {})

      -- Register trigger
      load_module({ triggers = { { mode = 'o', keys = 'i' } } })
      validate_trigger_keymap('o', 'i')
    end,
  },
})

T['Reproducing keys']['Operator-pending mode']['c'] = function()
  validate_edit1d('aa bb cc', 3, 'ciwdd', 'aa dd cc', 5)

  -- Dot-repeat
  validate_edit1d('aa bb', 0, 'ciwdd<Esc>w.', 'dd dd', 4)

  -- Should respect register
  validate_edit1d('aaa', 0, '"aciwxxx', 'xxx', 3)
  eq(child.fn.getreg('a'), 'aaa')

  -- User keymap
  validate_edit1d('aa bb cc', 3, 'cifdd', 'aa dd cc', 5)

  -- Should respect `[count]`
  validate_edit1d('aa bb cc', 0, 'c2iwdd', 'ddbb cc', 2)
end

T['Reproducing keys']['Operator-pending mode']['d'] = function()
  validate_edit1d('aa bb cc', 3, 'diw', 'aa  cc', 3)

  -- Dot-rpeat
  validate_edit1d('aa bb cc', 0, 'diww.', '  cc', 1)

  -- Should respect register
  validate_edit1d('aaa', 0, '"adiw', '', 0)
  eq(child.fn.getreg('a'), 'aaa')

  -- User keymap
  validate_edit1d('aa bb cc', 3, 'dif', 'aa  cc', 3)

  -- Should respect `[count]`
  validate_edit1d('aa bb cc', 0, 'd2iw', 'bb cc', 0)
end

T['Reproducing keys']['Operator-pending mode']['y'] = function()
  validate_edit1d('aa bb cc', 3, 'yiwP', 'aa bbbb cc', 4)

  -- Should respect register
  validate_edit1d('aaa', 0, '"ayiw', 'aaa', 0)
  eq(child.fn.getreg('a'), 'aaa')

  -- User keymap
  validate_edit1d('aa bb cc', 3, 'yifP', 'aa bbbb cc', 4)

  -- Should respect `[count]`
  validate_edit1d('aa bb cc', 0, 'y2iwP', 'aa aa bb cc', 2)
end

T['Reproducing keys']['Operator-pending mode']['~'] = function()
  child.o.tildeop = true

  validate_edit1d('aa bb', 0, '~iw', 'AA bb', 0)
  validate_edit1d('aa bb', 1, '~iw', 'AA bb', 0)
  validate_edit1d('aa bb', 3, '~iw', 'aa BB', 3)

  -- Dot-repeat
  validate_edit1d('aa bb', 0, '~iww.', 'AA BB', 3)

  -- User keymap
  validate_edit1d('aa bb', 0, '~if', 'AA bb', 0)

  -- Should respect `[count]`
  validate_edit1d('aa bb cc', 0, '~3iw', 'AA BB cc', 0)
end

T['Reproducing keys']['Operator-pending mode']['g~'] = function()
  validate_edit1d('aa bb', 0, 'g~iw', 'AA bb', 0)
  validate_edit1d('aa bb', 1, 'g~iw', 'AA bb', 0)
  validate_edit1d('aa bb', 3, 'g~iw', 'aa BB', 3)

  -- Dot-repeat
  validate_edit1d('aa bb', 0, 'g~iww.', 'AA BB', 3)

  -- User keymap
  validate_edit1d('aa bb', 0, 'g~if', 'AA bb', 0)

  -- Should respect `[count]`
  validate_edit1d('aa bb cc', 0, 'g~3iw', 'AA BB cc', 0)
end

T['Reproducing keys']['Operator-pending mode']['gu'] = function()
  validate_edit1d('AA BB', 0, 'guiw', 'aa BB', 0)
  validate_edit1d('AA BB', 1, 'guiw', 'aa BB', 0)
  validate_edit1d('AA BB', 3, 'guiw', 'AA bb', 3)

  -- Dot-repeat
  validate_edit1d('AA BB', 0, 'guiww.', 'aa bb', 3)

  -- User keymap
  validate_edit1d('AA BB', 0, 'guif', 'aa BB', 0)

  -- Should respect `[count]`
  validate_edit1d('AA BB CC', 0, 'gu3iw', 'aa bb CC', 0)
end

T['Reproducing keys']['Operator-pending mode']['gU'] = function()
  validate_edit1d('aa bb', 0, 'gUiw', 'AA bb', 0)
  validate_edit1d('aa bb', 1, 'gUiw', 'AA bb', 0)
  validate_edit1d('aa bb', 3, 'gUiw', 'aa BB', 3)

  -- Dot-repeat
  validate_edit1d('aa bb', 0, 'gUiww.', 'AA BB', 3)

  -- User keymap
  validate_edit1d('aa bb', 0, 'gUif', 'AA bb', 0)

  -- Should respect `[count]`
  validate_edit1d('aa bb cc', 0, 'gU3iw', 'AA BB cc', 0)
end

T['Reproducing keys']['Operator-pending mode']['gq'] = function()
  child.lua([[_G.formatexpr = function()
    local from, to = vim.v.lnum, vim.v.lnum + vim.v.count - 1
    local new_lines = {}
    for _ = 1, vim.v.count do table.insert(new_lines, 'xxx') end
    vim.api.nvim_buf_set_lines(0, from - 1, to, false, new_lines)
  end]])
  child.bo.formatexpr = 'v:lua.formatexpr()'

  validate_edit({ 'aa', 'aa', '', 'bb' }, { 1, 0 }, 'gqip', { 'xxx', 'xxx', '', 'bb' }, { 1, 0 })

  -- Dot-repeat
  validate_edit({ 'aa', 'aa', '', 'bb', 'bb' }, { 1, 0 }, 'gqipG.', { 'xxx', 'xxx', '', 'xxx', 'xxx' }, { 4, 0 })

  -- User keymap
  validate_edit({ 'aa', 'aa', '', 'bb' }, { 1, 0 }, 'gqiF', { 'xxx', 'xxx', '', 'bb' }, { 1, 0 })

  -- Should respect `[count]`
  validate_edit({ 'aa', '', 'bb', '', 'cc' }, { 1, 0 }, 'gq3ip', { 'xxx', 'xxx', 'xxx', '', 'cc' }, { 1, 0 })
end

T['Reproducing keys']['Operator-pending mode']['gw'] = function()
  child.o.textwidth = 5

  validate_edit({ 'aaa aaa', '', 'bb' }, { 1, 0 }, 'gwip', { 'aaa', 'aaa', '', 'bb' }, { 1, 0 })

  -- Dot-repeat
  validate_edit({ 'aaa aaa', '', 'bbb bbb' }, { 1, 0 }, 'gwipG.', { 'aaa', 'aaa', '', 'bbb', 'bbb' }, { 4, 0 })

  -- User keymap
  validate_edit({ 'aaa aaa', '', 'bb' }, { 1, 0 }, 'gwiF', { 'aaa', 'aaa', '', 'bb' }, { 1, 0 })

  -- Should respect `[count]`
  validate_edit(
    { 'aaa aaa', '', 'bbb bbb', '', 'cc' },
    { 1, 0 },
    'gw3ip',
    { 'aaa', 'aaa', '', 'bbb', 'bbb', '', 'cc' },
    { 1, 0 }
  )
end

T['Reproducing keys']['Operator-pending mode']['g?'] = function()
  validate_edit1d('aa bb', 0, 'g?iw', 'nn bb', 0)
  validate_edit1d('aa bb', 1, 'g?iw', 'nn bb', 0)
  validate_edit1d('aa bb', 3, 'g?iw', 'aa oo', 3)

  -- Dot-repeat
  validate_edit1d('aa bb', 0, 'g?iww.', 'nn oo', 3)

  -- User keymap
  validate_edit1d('aa bb', 0, 'g?if', 'nn bb', 0)

  -- Should respect `[count]`
  validate_edit1d('aa bb cc', 0, 'g?3iw', 'nn oo cc', 0)
end

T['Reproducing keys']['Operator-pending mode']['!'] = function()
  validate_edit({ 'cc', 'bb', '', 'aa' }, { 1, 0 }, '!ipsort<CR>', { 'bb', 'cc', '', 'aa' }, { 1, 0 })

  -- Dot-repeat
  validate_edit({ 'cc', 'bb', '', 'dd', 'aa' }, { 1, 0 }, '!ipsort<CR>G.', { 'bb', 'cc', '', 'aa', 'dd' }, { 4, 0 })

  -- User keymap
  validate_edit({ 'cc', 'bb', '', 'aa' }, { 1, 0 }, '!iFsort<CR>', { 'bb', 'cc', '', 'aa' }, { 1, 0 })

  -- Should respect `[count]`
  validate_edit(
    { 'cc', 'bb', '', 'ee', 'dd', '', 'aa' },
    { 1, 0 },
    '!3ipsort<CR>',
    { '', 'bb', 'cc', 'dd', 'ee', '', 'aa' },
    { 1, 0 }
  )
end

T['Reproducing keys']['Operator-pending mode']['='] = function()
  validate_edit({ 'aa', '\taa', '', 'bb' }, { 1, 0 }, '=ip', { 'aa', 'aa', '', 'bb' }, { 1, 0 })

  -- Dot-repeat
  validate_edit({ 'aa', '\taa', '', 'bb', '\tbb' }, { 1, 0 }, '=ipG.', { 'aa', 'aa', '', 'bb', 'bb' }, { 4, 0 })

  -- User keymap
  validate_edit({ 'aa', '\taa', '', 'bb' }, { 1, 0 }, '=iF', { 'aa', 'aa', '', 'bb' }, { 1, 0 })

  -- Should respect `[count]`
  validate_edit(
    { 'aa', '\taa', '', 'bb', '\tbb', '', 'cc' },
    { 1, 0 },
    '=3ip',
    { 'aa', 'aa', '', 'bb', 'bb', '', 'cc' },
    { 1, 0 }
  )
end

T['Reproducing keys']['Operator-pending mode']['>'] = function()
  validate_edit({ 'aa', '', 'bb' }, { 1, 0 }, '>ip', { '\taa', '', 'bb' }, { 1, 0 })

  -- Dot-repeat
  validate_edit({ 'aa', '', 'bb' }, { 1, 0 }, '>ip.2j.', { '\t\taa', '', '\tbb' }, { 3, 0 })

  -- User keymap
  validate_edit({ 'aa', '', 'bb' }, { 1, 0 }, '>iF', { '\taa', '', 'bb' }, { 1, 0 })

  -- Should respect `[count]`
  validate_edit({ 'aa', '', 'bb', '', 'cc' }, { 1, 0 }, '>3ip', { '\taa', '', '\tbb', '', 'cc' }, { 1, 0 })
end

T['Reproducing keys']['Operator-pending mode']['<'] = function()
  validate_edit({ '\t\taa', '', 'bb' }, { 1, 0 }, '<LT>ip', { '\taa', '', 'bb' }, { 1, 0 })

  -- Dot-repeat
  validate_edit({ '\t\t\taa', '', '\tbb' }, { 1, 0 }, '<LT>ip.2j.', { '\taa', '', 'bb' }, { 3, 1 })

  -- User keymap
  validate_edit({ '\t\taa', '', 'bb' }, { 1, 0 }, '<LT>iF', { '\taa', '', 'bb' }, { 1, 0 })

  -- Should respect `[count]`
  validate_edit({ '\t\taa', '', '\t\tbb', '', 'cc' }, { 1, 0 }, '<LT>3ip', { '\taa', '', '\tbb', '', 'cc' }, { 1, 0 })
end

T['Reproducing keys']['Operator-pending mode']['zf'] = function()
  local validate = function(keys, ref_last_folded_line)
    local lines = { 'aa', 'aa', '', 'bb', '', 'cc' }
    set_lines(lines)
    set_cursor(1, 0)

    type_keys(keys)

    for i = 1, ref_last_folded_line do
      eq(child.fn.foldclosed(i), 1)
    end

    for i = ref_last_folded_line + 1, #lines do
      eq(child.fn.foldclosed(i), -1)
    end
  end

  validate('zfip', 2)
  validate('zfiF', 2)

  -- Should respect `[count]`
  validate('zf3ip', 4)
end

T['Reproducing keys']['Operator-pending mode']['g@'] = function()
  child.o.operatorfunc = 'v:lua.operatorfunc'

  -- Charwise
  child.lua([[_G.operatorfunc = function()
    local from, to = vim.fn.col("'["), vim.fn.col("']")
    local line = vim.fn.line('.')

    vim.api.nvim_buf_set_text(0, line - 1, from - 1, line - 1, to, { 'xx' })
  end]])

  validate_edit1d('aa bb cc', 3, 'g@iw', 'aa xx cc', 3)

  -- - Dot-repeat
  set_lines({ 'aa bb cc' })
  set_cursor(1, 3)
  -- - Seems to need separate `nvim_input` to update event loop
  type_keys('g@iw', 'w', '.')
  eq(get_lines(), { 'aa xx xx' })
  eq(get_cursor(), { 1, 6 })

  -- - User keymap
  validate_edit1d('aa bb cc', 3, 'g@if', 'aa xx cc', 3)

  -- - Should respect `[count]`
  validate_edit1d('aa bb cc', 0, 'g@3iw', 'xx cc', 0)

  -- Linewise
  child.lua([[_G.operatorfunc = function() vim.cmd("'[,']sort") end]])

  validate_edit({ 'cc', 'bb', '', 'aa' }, { 1, 0 }, 'g@ip', { 'bb', 'cc', '', 'aa' }, { 1, 0 })

  -- - Dot-repeat
  set_lines({ 'cc', 'bb', '', 'dd', 'aa' })
  set_cursor(1, 0)
  type_keys('g@ip', 'G', '.')
  eq(get_lines(), { 'bb', 'cc', '', 'aa', 'dd' })
  eq(get_cursor(), { 4, 0 })

  -- - User keymap
  validate_edit({ 'cc', 'bb', '', 'aa' }, { 1, 0 }, 'g@iF', { 'bb', 'cc', '', 'aa' }, { 1, 0 })

  -- Should respect `[count]`
  validate_edit(
    { 'cc', 'bb', '', 'ee', 'dd', '', 'aa' },
    { 1, 0 },
    'g@3ip',
    { '', 'bb', 'cc', 'dd', 'ee', '', 'aa' },
    { 1, 0 }
  )
end

T['Reproducing keys']['Operator-pending mode']['works with operator and textobject from triggers'] = function()
  load_module({ triggers = { { mode = 'n', keys = 'g' }, { mode = 'o', keys = 'i' } } })
  validate_trigger_keymap('n', 'g')
  validate_trigger_keymap('o', 'i')

  -- `g~`
  set_lines({ 'aa bb' })
  set_cursor(1, 0)
  -- - Seems to need separate `nvim_input` to update event loop
  type_keys('g~', 'iw')
  set_lines({ 'AA bb' })
  set_cursor(1, 0)

  -- `g@`
  child.lua([[_G.operatorfunc = function() vim.cmd("'[,']sort") end]])
  child.o.operatorfunc = 'v:lua.operatorfunc'

  set_lines({ 'cc', 'bb', '', 'aa' })
  set_cursor(1, 0)
  -- - Seems to need separate `nvim_input` to update event loop
  type_keys('g@', 'ip')
  set_lines({ 'bb', 'cc', '', 'aa' })
  set_cursor(1, 0)
end

T['Reproducing keys']['Operator-pending mode']['respects forced submode'] = function()
  load_module({ triggers = { { mode = 'o', keys = '`' } } })
  validate_trigger_keymap('o', '`')

  -- Linewise
  set_lines({ 'aa', 'bbbb', 'cc' })
  set_cursor(2, 1)
  type_keys('mb')
  set_cursor(1, 0)
  type_keys('dV`b')
  eq(get_lines(), { 'cc' })

  -- Blockwise
  set_lines({ 'aa', 'bbbb', 'cc' })
  set_cursor(3, 1)
  type_keys('mc')
  set_cursor(1, 0)
  type_keys('d\22`c')
  eq(get_lines(), { '', 'bb', '' })
end

T['Reproducing keys']['works for builtin keymaps in Terminal mode'] = function()
  load_module({ triggers = { { mode = 't', keys = [[<C-\>]] } } })
  validate_trigger_keymap('t', [[<C-\>]])

  child.cmd('wincmd v')
  child.cmd('terminal')
  -- Wait for terminal to load
  vim.loop.sleep(100)
  child.cmd('startinsert')
  eq(child.fn.mode(), 't')

  type_keys([[<C-\><C-n>]])
  eq(child.fn.mode(), 'n')
end

T['Reproducing keys']['works for user keymaps in Terminal mode'] = function()
  -- Should work for both keymap created before and after making trigger
  make_test_map('t', '<Space>f')
  load_module({ triggers = { { mode = 't', keys = '<Space>' } } })
  make_test_map('t', '<Space>g')

  validate_trigger_keymap('t', '<Space>')

  child.cmd('wincmd v')
  child.cmd('terminal')
  -- Wait for terminal to load
  vim.loop.sleep(100)
  child.cmd('startinsert')
  eq(child.fn.mode(), 't')

  type_keys(' f')
  eq(child.fn.mode(), 't')
  eq(get_test_map_count('t', ' f'), 1)
  eq(get_test_map_count('t', ' g'), 0)

  type_keys(' g')
  eq(child.fn.mode(), 't')
  eq(get_test_map_count('t', ' f'), 1)
  eq(get_test_map_count('t', ' g'), 1)
end

T['Reproducing keys']['works for builtin keymaps in Command-line mode'] = function()
  load_module({ triggers = { { mode = 'c', keys = '<C-r>' } } })
  validate_trigger_keymap('c', '<C-R>')

  set_lines({ 'aaa' })
  set_cursor(1, 0)
  type_keys(':', '<C-r><C-w>')
  eq(child.fn.getcmdline(), 'aaa')
end

T['Reproducing keys']['works for user keymaps in Command-line mode'] = function()
  -- Should work for both keymap created before and after making trigger
  make_test_map('c', '<Space>f')
  load_module({ triggers = { { mode = 'c', keys = '<Space>' } } })
  make_test_map('c', '<Space>g')

  validate_trigger_keymap('c', '<Space>')

  type_keys(':')

  type_keys(' f')
  eq(child.fn.mode(), 'c')
  eq(get_test_map_count('c', ' f'), 1)
  eq(get_test_map_count('c', ' g'), 0)

  type_keys(' g')
  eq(child.fn.mode(), 'c')
  eq(get_test_map_count('c', ' f'), 1)
  eq(get_test_map_count('c', ' g'), 1)
end

T['Reproducing keys']['works for registers'] = function()
  load_module({ triggers = { { mode = 'n', keys = '"' }, { mode = 'x', keys = '"' } } })
  validate_trigger_keymap('n', '"')
  validate_trigger_keymap('x', '"')

  -- Normal mode
  set_lines({ 'aa' })
  set_cursor(1, 0)
  type_keys('"ayiw')
  eq(child.fn.getreg('"a'), 'aa')

  -- Visual mode
  set_lines({ 'bb' })
  set_cursor(1, 0)
  type_keys('viw"by')
  eq(child.fn.getreg('"b'), 'bb')
end

T['Reproducing keys']['works for marks'] = function()
  load_module({ triggers = { { mode = 'n', keys = "'" }, { mode = 'n', keys = '`' } } })
  validate_trigger_keymap('n', "'")
  validate_trigger_keymap('n', '`')

  set_lines({ 'aa', 'bb' })
  set_cursor(1, 1)
  type_keys('ma')

  -- Line jump
  set_cursor(2, 0)
  type_keys("'a")
  eq(get_cursor(), { 1, 0 })

  -- Exact jump
  set_cursor(2, 0)
  type_keys('`a')
  eq(get_cursor(), { 1, 1 })
end

T['Reproducing keys']['trigger forwards keys even if no extra clues is set'] = function()
  load_module({ triggers = { { mode = 'c', keys = 'g' }, { mode = 'i', keys = 'g' } } })
  validate_trigger_keymap('c', 'g')
  validate_trigger_keymap('i', 'g')

  type_keys(':', 'g')
  eq(child.fn.getcmdline(), 'g')

  child.ensure_normal_mode()
  type_keys('i', 'g')
  eq(get_lines(), { 'g' })
end

T['Reproducing keys']['works when key query is executed in presence of longer keymaps'] = function()
  -- Imitate Lua commenting
  child.lua([[
    _G.comment_operator = function()
      vim.o.operatorfunc = 'v:lua.operatorfunc'
      return 'g@'
    end

    _G.comment_line = function() return _G.comment_operator() .. '_' end

    _G.operatorfunc = function()
      local from, to = vim.fn.line("'["), vim.fn.line("']")
      local lines = vim.api.nvim_buf_get_lines(0, from - 1, to, false)
      local new_lines = vim.tbl_map(function(x) return '-- ' .. x end, lines)
      vim.api.nvim_buf_set_lines(0, from - 1, to, false, new_lines)
    end

    vim.keymap.set('n', 'gc', _G.comment_operator, { expr = true, replace_keycodes = false })
    vim.keymap.set('n', 'gcc', _G.comment_line, { expr = true, replace_keycodes = false })
  ]])

  load_module({ triggers = { { mode = 'n', keys = 'g' }, { mode = 'o', keys = 'i' } } })
  validate_trigger_keymap('n', 'g')
  validate_trigger_keymap('o', 'i')

  validate_edit({ 'aa', 'bb', '', 'cc' }, { 1, 0 }, 'gcip', { '-- aa', '-- bb', '', 'cc' }, { 1, 0 })
end

T['Reproducing keys']["works with 'mini.ai'"] = function()
  -- `i`/`in`/`il` and `a`/`an`/`al`
  MiniTest.skip()
end

T['Reproducing keys']["works with 'mini.align'"] = function()
  -- Operators `ga` and `gA` work when textobject uses trigger.
  -- Example: `gaip` and `gAip` (both with trigger `g` and not)
  MiniTest.skip()
end

T['Reproducing keys']["works with 'mini.bracketed'"] = function() MiniTest.skip() end

T['Reproducing keys']["works with 'mini.comment'"] = function() MiniTest.skip() end

T['Reproducing keys']["works with 'mini.indentscope'"] = function() MiniTest.skip() end

T['Reproducing keys']["works with 'mini.surround'"] = function()
  -- `saiw` works as expected when `s` and `i` are triggers: doesn't move cursor, no messages.

  -- Dot-repeat for every operator
  MiniTest.skip()
end

-- T['Reproducing keys']['works with `<Cmd>` mappings'] = function() MiniTest.skip() end

-- T['Reproducing keys']['works buffer-local mappings'] = function() MiniTest.skip() end

-- T['Reproducing keys']['respects `vim.b.miniclue_config`'] = function() MiniTest.skip() end

return T
