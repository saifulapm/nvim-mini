-- MIT License Copyright (c) 2022 Evgeni Chasnovski

-- Documentation ==============================================================
--- Module for creating extended `a`/`i` textobjects. Basically, like
--- 'wellle/targets.vim' but in Lua and slightly different.
---
--- Features:
--- - Customizable creation of `a`/`i` textobjects using Lua patterns. Supports
---   dot-repeat, consecutive application, search method, |v:count|.
--- - Comprehensive defaults:
---     - Balanced brackets (with and without whitespace).
---     - Balanced quotes.
---     - Single character punctuation, digit, or whitespace.
---     - Function call.
---     - Function argument (in simple but common cases).
---     - Tag.
---     - Derived from user prompt.
--- - Motions for jumping to left/right edge of textobject.
---
--- Utilizes same basic ideas about searching object as |mini.surround|, but
--- has more advanced features.
---
--- What it doesn't (and probably won't) do:
--- - Have special operators to specially handle whitespace (like `I` and `A`
---   in 'targets.vim'). Whitespace handling is assumed to be done inside
---   textobject specification (like `i(` and `i)` handle whitespace differently).
--- - Have "last" and "next" textobject modifiers (like `il` and `in` in
---   'targets.vim'). Either set and use appropriate `config.search_method` or
---   move to the next place and then use textobject. For a quicker movements,
---   see |mini.jump| and |mini.jump2d|.
---
--- General rule of thumb: any instrument using available parser for document
--- structure (like treesitter) will usually provide more precise results. This
--- module is mostly about creating plain text textobjects which are useful
--- most of the times (like "inside brackets", "around quotes/underscore", etc.).
---
--- # Setup~
---
--- This module needs a setup with `require('mini.ai').setup({})` (replace
--- `{}` with your `config` table). It will create global Lua table `MiniAi`
--- which you can use for scripting or manually (with `:lua MiniAi.*`).
---
--- See |MiniAi.config| for available config settings.
---
--- You can override runtime config settings (like `config.textobjects`) locally to
--- buffer inside `vim.b.miniai_config` which should have same structure as
--- `MiniAi.config`. See |mini.nvim-buffer-local-config| for more details.
---
--- # Comparisons~
---
--- - 'wellle/targets.vim':
---     - ...
--- - 'kana/vim-textobj-user':
---     - ...
--- - 'nvim-treesitter/nvim-treesitter-textobjects':
---     - ...
---
--- # Disabling~
---
--- To disable, set `g:miniai_disable` (globally) or `b:miniai_disable`
--- (for a buffer) to `v:true`. Considering high number of different scenarios
--- and customization intentions, writing exact rules for disabling module's
--- functionality is left to user. See |mini.nvim-disabling-recipes| for common
--- recipes.
---@tag mini.ai
---@tag MiniAi
---@toc_entry Extended a/i textobjects

--- Algorithm design
---
--- - *Region* - ... .
--- - *Pattern* - string describing Lua pattern.
--- - *Span* - interval inside a string. Like `[1, 5]`.
--- - *Span `[a1, a2]` is nested inside `[b1, b2]`* <=> `b1 <= a1 <= a2 <= b2`.
---   It is also *span `[b1, b2]` covers `[a1, a2]`*.
--- - *Nested pattern* - array of patterns aimed to describe nested spans.
--- - *Span matches nested pattern* if there is a sequence of increasingly
---   nested spans each matching corresponding pattern within substring of
---   previous span (input string for first span). Example:
---     Nested patterns: `{ '%b()', '^. .* .$' }` (padded balanced `()`)
---     Input string: `( ( () ( ) ) )`
---                   `12345678901234`
---   Here are all matching spans `[1, 14]` and `[3, 12]`. Both `[5, 6]` and
---   `[8, 10]` match first pattern but not second. All other combinations of
---   `(` and `)` don't match first pattern (not balanced)
--- - *Composed pattern*: array with each element describing possible pattern
---   at that place. Elements can be arrays or string patterns. Composed pattern
---   basically defines all possible combinations of nested pattern (their
---   cartesian product). Example:
---     Composed pattern: `{{'%b()', '%b[]'}, '^. .* .$'}`
---     Composed pattern expanded into equivalent array of nested patterns:
---       `{ '%b()', '^. .* .$' }` and `{ '%b[]', '^. .* .$' }`
--- - *Span matches composed pattern* if it matches at least one nested
---   pattern from expanded composed pattern.
---
---@tag MiniAi-algorithm

-- Module definition ==========================================================
MiniAi = {}
H = {}

--- Module setup
---
---@param config table|nil Module config table. See |MiniAi.config|.
---
---@usage `require('mini.ai').setup({})` (replace `{}` with your `config` table)
MiniAi.setup = function(config)
  -- Export module
  _G.MiniAi = MiniAi

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)
end

--- Module config
---
--- Default values:
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
---@text # Options ~
---
--- ## Custom textobjects
---
--- Specification is a "composed pattern" (see |MiniAi-algorithm|). ...
---
--- Builtin ones:
--- - Balanced brackets:
---     - `(`, `[`, `{`. `a` - around brackets, `i` - inside brackets excluding
---       edge whitespace.
---     - `)`, `]`, `}`. `a` - around brackets, `i` - inside brackets.
---     - `b` - alias for a best region among `)`, `]`, `}`.
--- - Balanced quotes;
---     - `"`, `'`, `. Textobject is between odd and even character starting
---       from whole neighborhood.
---     - Alias for a best region among `"`, `'`, `.
--- - Function call. Works in simple but most popular cases. Probably better
---   using treesitter textobjects.
--- - Argument. Same caveats as function call.
--- - Tag. Same caveats as function call.
--- - Prompted from user. Can't result into span with two or more right edges.
--- - All other single character punctuation, digit, or whitespace. Left and
---   right edges will be multiples of the character without this character in
---   between. Includes only right edge in `a` textobject. Can't result into
---   covering span, so can't evolve with `config.search_method = 'cover'`. To
---   consecutively select use with `v:count` equal to 2 (like `v2a_`).
---
--- Examples:
--- - Imitating word: `{ w = { '()()%f[%w]%w+()[ \t]*()' } }`
--- - Word with camel case support:
---   `{ c = { { '[A-Z][%l%d]*', '%f[%S][%l%d]+', '%f[%P][%l%d]+' }, '^().*()$' } }`
--- - Date in 'YYYY-MM-DD' format: `{ d = { '()%d%d%d%d%-%d%d%-%d%d()' } }`
--- - Lua block string: `{ s = { '%[%[().-()%]%]' } }`
---
--- ## Search method
---
--- ...
MiniAi.config = {
  -- Table with textobject id as fields, textobject spec (or function returning
  -- textobject spec) as values
  custom_textobjects = nil,

  -- Module mappings. Use `''` (empty string) to disable one.
  mappings = {
    -- Main textobject prefixes
    around = 'a',
    inside = 'i',

    -- Move cursor to certain part of textobject
    goto_left = 'g[',
    goto_right = 'g]',
  },

  n_lines = 20,

  -- How to search for object (first inside current line, then inside
  -- neighborhood). One of 'cover', 'cover_or_next', 'cover_or_prev',
  -- 'cover_or_nearest'. For more details, see `:h MiniAi.config`.
  search_method = 'cover_or_next',
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Find textobject region
---
---@param id string Single character string representing textobject id.
---@param ai_type string One of `'a'` or `'i'`.
---@param opts table|nil Options. Possible fields:
---   - <n_lines> - Number of lines within which textobject is searched.
---     Default: `config.n_lines` (see |MiniAi.config|).
---   - <n_times> - Number of times to perform a consecutive search. Each one
---     is done with reference region being previous found textobject region.
---     Default: 1.
---   - <reference_region> - Table describing region to try to cover.
---     Fields: <left> and <right> for start and end positions. Each position
---     is also a table with line <line> and columns <col> (both start at 1).
---     Default: single cell region describing cursor position.
---   - <search_method> - Search method. Default: `config.search_method`.
---
---@return table|nil Table describing region of textobject or `nil` if no
---   textobject was consecutively found `opts.n_times` times. Table has fields
---   <left> and <right> for corresponding inclusive edges. Each edge is itself
---   a table with `<line>` and `<col>` fields (both start from 1). Note: empty
---   region has `left` edge strictly on the right of `right` edge.
MiniAi.find_textobject = function(id, ai_type, opts)
  local tobj_spec = H.get_textobject_spec(id)
  if tobj_spec == nil then return end

  if not (ai_type == 'a' or ai_type == 'i') then H.error([[`ai_type` should be one of 'a' or 'i'.]]) end
  opts = vim.tbl_deep_extend('force', H.get_default_opts(), opts or {})

  local res = H.find_textobject_region(tobj_spec, ai_type, opts)

  if res == nil then
    local msg = string.format(
      [[No textobject %s found covering region%s within %d line%s and `config.search_method = '%s'`.]],
      vim.inspect(ai_type .. id),
      opts.n_times > 1 and (' %s times'):format(opts.n_times) or '',
      opts.n_lines,
      opts.n_lines > 1 and 's' or '',
      opts.search_method
    )
    H.message(msg)
  end

  return res
end

--- Visually select textobject region
---
--- Does nothing if no region is found.
---
---@param id string Single character string representing textobject id.
---@param ai_type string One of `'a'` or `'i'`.
---@param opts table|nil Same as in |MiniAi.find_textobject()|. Extra fields:
---   - <vis_mode> - One of `'v'`, `'V'`, `'<C-v>'`. Default: Latest visual mode.
---   - <operator_pending> - Whether selection is for Operator-pending mode.
---     Default: `false`.
MiniAi.select_textobject = function(id, ai_type, opts)
  opts = opts or {}

  -- Exit to Normal before getting textobject id. This way invalid id doesn't
  -- result into staying in current mode (which seems to be more convenient).
  H.exit_to_normal_mode()

  local tobj = MiniAi.find_textobject(id, ai_type, opts)
  if tobj == nil then return end

  local set_cursor = function(position) vim.api.nvim_win_set_cursor(0, { position.line, position.col - 1 }) end
  local tobj_is_empty = tobj.left.line > tobj.right.line
    or (tobj.left.line == tobj.right.line and tobj.left.col > tobj.right.col)

  local vis_mode = opts.vis_mode and vim.api.nvim_replace_termcodes(opts.vis_mode, true, true, true)
    or vim.fn.visualmode()

  -- Allow going past end of line in order to collapse multiline regions
  local cache_virtualedit = vim.o.virtualedit
  local cache_eventignore = vim.o.eventignore

  pcall(function()
    -- Do nothing in Operator-pending mode for empty region (except `c` or `d`)
    if tobj_is_empty and opts.operator_pending and not (vim.v.operator == 'c' or vim.v.operator == 'd') then
      H.message('Textobject region is empty. Nothing is done.')
      return
    end

    -- Allow setting cursor past line end (allows collapsing multiline region)
    vim.o.virtualedit = 'onemore'

    -- Open enough folds to show left and right edges
    set_cursor(tobj.left)
    vim.cmd('normal! zv')
    set_cursor(tobj.right)
    vim.cmd('normal! zv')

    vim.cmd('normal! ' .. vis_mode)

    if not tobj_is_empty then
      set_cursor(tobj.left)
      return
    end

    if opts.operator_pending then
      -- Add single space (without triggering events) and visually select it.
      -- Seems like the only way to make `ci)` and `di)` move inside empty
      -- brackets. Original idea is from 'wellle/targets.vim'.
      vim.o.eventignore = 'all'

      -- First escape from previously started Visual mode
      vim.cmd([[silent! execute "normal! \<Esc>a \<Esc>v"]])
    end
  end)

  -- Restore options
  vim.o.virtualedit = cache_virtualedit
  vim.o.eventignore = cache_eventignore
end

--- Make expression to visually select textobject
---
--- Designed to be used inside expression mapping. No need to use directly.
---
--- Textobject identifier is taken from user single character input.
--- Default `n_times` option is taken from |v:count1|.
---
---@param mode string One of 'x' (Visual) or 'o' (Operator-pending).
---@param ai_type string One of `'a'` or `'i'`.
MiniAi.expr_textobject = function(mode, ai_type)
  local tobj_id = H.user_textobject_id(ai_type)

  if tobj_id == nil then return '' end

  -- Fall back to builtin `a`/`i` textobjects in case of invalid id
  if not H.is_valid_textobject_id(tobj_id) then return ai_type .. tobj_id end

  -- Clear cache
  H.cache = {}

  -- Construct call options based on mode
  local reference_region_field, operator_pending, vis_mode = 'nil', 'nil', 'nil'

  if mode == 'x' then
    -- Use Visual selection as reference region for Visual mode mappings
    reference_region_field = vim.inspect(H.get_visual_region(), { newline = '', indent = '' })
  end

  if mode == 'o' then
    -- Supply `operator_pending` flag in Operator-pending mode
    operator_pending = 'true'

    -- Take into account forced Operator-pending modes ('nov', 'noV', 'no<C-V>')
    vis_mode = vim.fn.mode(1):gsub('^no', '')
    vis_mode = vim.inspect(vis_mode == '' and 'v' or vis_mode)
  end

  -- Make expression
  local res = '<Cmd>lua MiniAi.select_textobject('
    .. string.format(
      [['%s', '%s', { n_times = %d, reference_region = %s, operator_pending = %s, vis_mode = %s }]],
      vim.fn.escape(tobj_id, "'"),
      ai_type,
      vim.v.count1,
      reference_region_field,
      operator_pending,
      vis_mode
    )
    .. ')<CR>'

  return vim.api.nvim_replace_termcodes(res, true, true, true)
end

--- Move cursor to edge of textobject
---
---@param side string One of `'left'` or `'right'`.
---@param id string Single character string representing textobject id.
---@param ai_type string One of `'a'` or `'i'`.
---@param opts table|nil Same as in |MiniAi.find_textobject()|.
MiniAi.move_cursor = function(side, id, ai_type, opts)
  if not (side == 'left' or side == 'right') then H.error([[`side` should be one of 'left' or 'right'.]]) end
  opts = opts or {}
  local init_pos = vim.api.nvim_win_get_cursor(0)

  -- Compute single textobject first to find out if it would move the cursor.
  -- If not, then eventual `n_times` should be bigger by 1 to imitate `n_times`
  -- *actual* jumps. This implements consecutive jumps and has logic of "If
  -- cursor is strictly inside region, move to its side first".
  local new_opts = vim.tbl_deep_extend('force', opts, { n_times = 1 })
  local tobj_single = MiniAi.find_textobject(id, ai_type, new_opts)
  if tobj_single == nil then return end

  new_opts.n_times = opts.n_times or 1
  if (init_pos[1] == tobj_single[side].line) and (init_pos[2] == tobj_single[side].col - 1) then
    new_opts.n_times = new_opts.n_times + 1
  end

  -- Compute actually needed textobject while avoiding unnecessary computation
  -- in a most common usage (`v:count1 == 1`)
  local pos = tobj_single[side]
  if new_opts.n_times > 1 then
    local tobj = MiniAi.find_textobject(id, ai_type, new_opts)
    if tobj == nil then return end
    pos = tobj[side]
  end

  -- Move cursor and open enough folds
  vim.api.nvim_win_set_cursor(0, { pos.line, pos.col - 1 })
  vim.cmd('normal! zv')
end

--- Make expression for moving cursor to edge of textobject
---
--- Designed to be used inside expression mapping. No need to use directly.
---
--- Textobject identifier is taken from user single character input.
--- Default `n_times` option is taken from |v:count1|.
---
---@param side string One of `'left'` or `'right'`.
MiniAi.expr_motion = function(side)
  if not (side == 'left' or side == 'right') then H.error([[`side` should be one of 'left' or 'right'.]]) end

  -- Get user input
  local tobj_id = H.user_textobject_id('a')
  if tobj_id == nil then return end

  -- Clear cache
  H.cache = {}

  -- Make expression for moving cursor
  local res = string.format(
    [[<Cmd>lua MiniAi.move_cursor('%s', '%s', 'a', { n_times = %d })<CR>]],
    side,
    vim.fn.escape(tobj_id, "'"),
    vim.v.count1
  )
  return vim.api.nvim_replace_termcodes(res, true, true, true)
end

-- Helper data ================================================================
-- Module default config
H.default_config = MiniAi.config

-- Cache for various operations
H.cache = {}

-- Builtin textobjects
H.builtin_textobjects = {
  -- Use balanced pair for brackets. Use opening ones to possibly remove edge
  -- whitespace from `i` textobject.
  ['('] = { '%b()', '^.%s*().-()%s*.$' },
  [')'] = { '%b()', '^.().-().$' },
  ['['] = { '%b[]', '^.%s*().-()%s*.$' },
  [']'] = { '%b[]', '^.().-().$' },
  ['{'] = { '%b{}', '^.%s*().-()%s*.$' },
  ['}'] = { '%b{}', '^.().-().$' },
  ['<'] = { '%b<>', '^.%s*().-()%s*.$' },
  ['>'] = { '%b<>', '^.().-().$' },
  -- Use special "same balanced" pattern to select quotes in pairs
  ["'"] = { "%b''", '^.().-().$' },
  ['"'] = { '%b""', '^.().-().$' },
  ['`'] = { '%b``', '^.().-().$' },
  -- Derived from user prompt
  ['?'] = function()
    -- Using cache allows for a dot-repeat without another user input
    if H.cache.prompted_textobject ~= nil then return H.cache.prompted_textobject end

    local left = H.user_input('Left edge')
    if left == nil or left == '' then return end
    local right = H.user_input('Right edge')
    if right == nil or right == '' then return end

    local left_esc, right_esc = vim.pesc(left), vim.pesc(right)
    local find = ('%s.-%s'):format(left_esc, right_esc)
    local extract = ('^%s().-()%s$'):format(left_esc, right_esc)
    local res = { find, extract }
    H.cache.prompted_textobject = res
    return res
  end,
  -- Argument. Probably better to use treesitter-based textobject.
  ['a'] = {
    { '%b()', '%b[]', '%b{}' },
    -- Around argument is between comma(s) and edge(s). One comma is included.
    -- Inner argument - around argument minus comma and "outer" whitespace
    { ',()%s*().-()%s*,()', '^.()%s*().-()%s*().$', '^.()%s*().-()%s*,()', '(),%s*().-()%s*().$' },
  },
  -- Brackets
  ['b'] = { { '%b()', '%b[]', '%b{}' }, '^.().*().$' },
  -- Function call. Probably better to use treesitter-based textobject.
  ['f'] = { '%f[%w_%.][%w_%.]+%b()', '^.-%(().*()%)$' },
  -- Tag
  ['t'] = { '<(%w-)%f[^<%w][^<>]->.-</%1>', '^<.->().*()</[^/]->$' },
  -- Quotes
  ['q'] = { { "%b''", '%b""', '%b``' }, '^.().*().$' },
}

H.ns_id = {
  input = vim.api.nvim_create_namespace('MiniAiInput'),
}

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  -- General idea: if some table elements are not present in user-supplied
  -- `config`, take them from default config
  vim.validate({ config = { config, 'table', true } })
  config = vim.tbl_deep_extend('force', H.default_config, config or {})

  vim.validate({
    custom_textobjects = { config.custom_textobjects, 'table', true },
    mappings = { config.mappings, 'table' },
    n_lines = { config.n_lines, 'number' },
    search_method = { config.search_method, H.is_search_method },
  })

  vim.validate({
    ['mappings.around'] = { config.mappings.around, 'string' },
    ['mappings.inside'] = { config.mappings.inside, 'string' },
    ['mappings.goto_left'] = { config.mappings.goto_left, 'string' },
    ['mappings.goto_right'] = { config.mappings.goto_right, 'string' },
  })

  return config
end

--stylua: ignore
H.apply_config = function(config)
  MiniAi.config = config

  -- Make mappings
  local maps = config.mappings

  -- Usage of expression maps implements dot-repeat support
  H.map('n', maps.goto_left,  [[v:lua.MiniAi.expr_motion('left')]],   { expr = true, desc = 'Move to left "around"' })
  H.map('n', maps.goto_right, [[v:lua.MiniAi.expr_motion('right')]],  { expr = true, desc = 'Move to right "around"' })
  H.map('x', maps.goto_left,  [[v:lua.MiniAi.expr_motion('left')]],   { expr = true, desc = 'Move to left "around"' })
  H.map('x', maps.goto_right, [[v:lua.MiniAi.expr_motion('right')]],  { expr = true, desc = 'Move to right "around"' })
  H.map('o', maps.goto_left,  [[v:lua.MiniAi.expr_motion('left')]],   { expr = true, desc = 'Move to left "around"' })
  H.map('o', maps.goto_right, [[v:lua.MiniAi.expr_motion('right')]],  { expr = true, desc = 'Move to right "around"' })

  H.map('x', maps.around, [[v:lua.MiniAi.expr_textobject('x', 'a')]], { expr = true, desc = 'Around textobject' })
  H.map('x', maps.inside, [[v:lua.MiniAi.expr_textobject('x', 'i')]], { expr = true, desc = 'Inside textobject' })
  H.map('o', maps.around, [[v:lua.MiniAi.expr_textobject('o', 'a')]], { expr = true, desc = 'Around textobject' })
  H.map('o', maps.inside, [[v:lua.MiniAi.expr_textobject('o', 'i')]], { expr = true, desc = 'Inside textobject' })
end

H.is_disabled = function() return vim.g.miniai_disable == true or vim.b.miniai_disable == true end

H.get_config =
  function(config) return vim.tbl_deep_extend('force', MiniAi.config, vim.b.miniai_config or {}, config or {}) end

H.is_search_method = function(x, x_name)
  x = x or H.get_config().search_method
  x_name = x_name or '`config.search_method`'

  if vim.tbl_contains({ 'cover_or_next', 'cover', 'cover_or_prev', 'cover_or_nearest' }, x) then return true end
  local msg = ([[%s should be one of 'cover_or_next', 'cover', 'cover_or_prev', 'cover_or_nearest'.]]):format(x_name)
  return false, msg
end

H.validate_tobj_pattern = function(x)
  local msg = string.format('%s is not a textobject pattern.', vim.inspect(x))
  if type(x) ~= 'table' then H.error(msg) end
  for _, val in ipairs(vim.tbl_flatten(x)) do
    if type(val) ~= 'string' then H.error(msg) end
  end
end

H.validate_search_method = function(x, x_name)
  local is_valid, msg = H.is_search_method(x, x_name)
  if not is_valid then H.error(msg) end
end

-- Work with textobject info --------------------------------------------------
H.make_textobject_table = function()
  -- Extend builtins with data from `config`. Don't use `tbl_deep_extend()`
  -- because only top level keys should be merged.
  local textobjects = vim.tbl_extend('force', H.builtin_textobjects, H.get_config().custom_textobjects or {})

  -- Use default textobject pattern only for some characters: punctuation,
  -- whitespace, digits.
  return setmetatable(textobjects, {
    __index = function(_, key)
      if not (type(key) == 'string' and string.find(key, '^[%p%s%d]$')) then return end
      -- Include both sides in `a` textobject because:
      -- - This feels more coherent and leads to less code.
      -- - There are issues with evolving in Visual mode because reference
      --   region will be smaller than pattern match. This lead to acceptance
      --   of pattern and the same region will be highlighted again.
      local key_esc = vim.pesc(key)
      -- Use `%f[]` to have maximum stretch to the left. Include only right
      -- edge in `a` textobject. Example outcome with `_`: '%f[_]_+().-()_+'.
      return { string.format('%%f[%s]%s+()().-()%s+()', key_esc, key_esc, key_esc) }
    end,
  })
end

H.is_valid_textobject_id = function(id)
  local textobject_tbl = H.make_textobject_table()
  return textobject_tbl[id] ~= nil
end

H.get_textobject_spec = function(id)
  local textobject_tbl = H.make_textobject_table()
  local spec = textobject_tbl[id]

  -- Allow function returning spec
  if type(spec) == 'function' then spec = spec() end

  -- This is needed to allow easy disabling of textobject identifiers
  if not (type(spec) == 'table' and #spec > 0) then return nil end
  return spec
end

-- Work with finding textobjects ----------------------------------------------
---@param tobj_spec table Composed pattern. Last item(s) - extraction template.
---@param ai_type string One of `'a'` or `'i'`.
---@param opts table Textobject options with all fields present.
---@private
H.find_textobject_region = function(tobj_spec, ai_type, opts)
  local reference_region, n_times, n_lines = opts.reference_region, opts.n_times, opts.n_lines

  -- Find `n_times` matching spans evolving from reference region span
  -- First try to find inside 0-neighborhood
  local neigh = H.get_neighborhood(reference_region, 0)
  local find_res = { span = neigh.region_to_span(reference_region) }

  local cur_n_times = 0
  while cur_n_times < n_times do
    local new_find_res = H.find_best_match(neigh['1d'], tobj_spec, find_res.span, opts)

    -- If didn't find in 0-neighborhood, try extended one.
    -- Stop if didn't find in extended neighborhood.
    if new_find_res.span == nil then
      if neigh.n_neighbors > 0 then return end

      local found_region = neigh.span_to_region(find_res.span)
      neigh = H.get_neighborhood(reference_region, n_lines)
      find_res = { span = neigh.region_to_span(found_region) }
    else
      find_res = new_find_res
      cur_n_times = cur_n_times + 1
    end
  end

  -- Extract local (with respect to best matched span) span
  local s = neigh['1d']:sub(find_res.span.left, find_res.span.right)
  local extract_pattern = find_res.nested_pattern[#find_res.nested_pattern]
  local local_span = H.extract_span(s, extract_pattern, ai_type)

  -- Convert local span to region
  local offset = find_res.span.left - 1
  local found_span = { left = local_span.left + offset, right = local_span.right + offset }
  return neigh.span_to_region(found_span)
end

H.get_default_opts = function()
  local config = H.get_config()
  local cur_pos = vim.api.nvim_win_get_cursor(0)
  cur_pos = { line = cur_pos[1], col = cur_pos[2] + 1 }
  return {
    n_lines = config.n_lines,
    n_times = 1,
    reference_region = { left = cur_pos, right = cur_pos },
    search_method = config.search_method,
  }
end

-- Work with matching spans ---------------------------------------------------
---@param line string
---@param composed_pattern table
---@param reference_span table Span to cover.
---@param opts table Fields: <search_method>.
---@private
H.find_best_match = function(line, composed_pattern, reference_span, opts)
  local best_span, best_nested_pattern, current_nested_pattern
  local f = function(span)
    if H.is_better_span(span, best_span, reference_span, opts) then
      best_span = span
      best_nested_pattern = current_nested_pattern
    end
  end

  for _, nested_pattern in ipairs(H.cartesian_product(composed_pattern)) do
    current_nested_pattern = nested_pattern
    H.iterate_matched_spans(line, nested_pattern, f)
  end

  return { span = best_span, nested_pattern = best_nested_pattern }
end

H.iterate_matched_spans = function(line, nested_pattern, f)
  local max_level = #nested_pattern
  -- Keep track of visited spans to ensure only one call of `f`.
  -- Example: `((a) (b))`, `{'%b()', '%b()'}`
  local visited = {}

  local process
  process = function(level, level_line, level_offset)
    local pattern = nested_pattern[level]
    local is_same_balanced = pattern:match('^%%b(.)%1$') ~= nil
    local init = 1
    while init <= level_line:len() do
      local left, right = H.string_find(level_line, pattern, init)
      if left == nil then break end

      if level == max_level then
        local found_match = { left = left + level_offset, right = right + level_offset }
        local found_match_id = string.format('%s_%s', found_match.left, found_match.right)
        if not visited[found_match_id] then
          f(found_match)
          visited[found_match_id] = true
        end
      else
        local next_level_line = level_line:sub(left, right)
        local next_level_offset = level_offset + left - 1
        process(level + 1, next_level_line, next_level_offset)
      end

      -- Start searching from right end to implement "balanced" pair.
      -- This doesn't work with regular balanced pattern because it doesn't
      -- capture nested brackets.
      init = (is_same_balanced and right or left) + 1
    end
  end

  process(1, line, 0)
end

---@param candidate table Candidate span to test agains `current`.
---@param current table|nil Current best span.
---@param reference table Reference span to cover.
---@param opts table Fields: <search_method>.
---@private
H.is_better_span = function(candidate, current, reference, opts)
  -- Candidate never equals reference to allow incrementing textobjects
  if H.is_span_equal(candidate, reference) then return false end

  -- Covering span is always better than not covering span
  local is_candidate_covering = H.is_span_covering(candidate, reference)
  local is_current_covering = H.is_span_covering(current, reference)

  if is_candidate_covering and not is_current_covering then return true end
  if not is_candidate_covering and is_current_covering then return false end

  if is_candidate_covering then
    -- Covering candidate is better than covering current if it is narrower
    return (candidate.right - candidate.left) < (current.right - current.left)
  else
    local search_method = opts.search_method
    if search_method == 'cover' then return false end
    -- Candidate never should be nested inside `span_to_cover`
    if H.is_span_covering(reference, candidate) then return false end

    local is_good_candidate = (search_method == 'cover_or_next' and H.is_span_on_left(reference, candidate))
      or (search_method == 'cover_or_prev' and H.is_span_on_left(candidate, reference))
      or (search_method == 'cover_or_nearest')

    if not is_good_candidate then return false end
    if current == nil then return true end

    -- Non-covering good candidate is better than non-covering current if it is
    -- closer to `span_to_cover`
    return H.span_distance(candidate, reference, search_method) < H.span_distance(current, reference, search_method)
  end
end

H.is_span_covering = function(span, span_to_cover)
  if span == nil or span_to_cover == nil then return false end
  return (span.left <= span_to_cover.left) and (span_to_cover.right <= span.right)
end

H.is_span_equal = function(span_1, span_2)
  if span_1 == nil or span_2 == nil then return false end
  return (span_1.left == span_2.left) and (span_1.right == span_2.right)
end

H.is_span_on_left = function(span_1, span_2)
  if span_1 == nil or span_2 == nil then return false end
  return (span_1.left <= span_2.left) and (span_1.right <= span_2.right)
end

H.span_distance = function(span_1, span_2, search_method)
  -- Other possible choices of distance between [a1, a2] and [b1, b2]:
  -- - Hausdorff distance: max(|a1 - b1|, |a2 - b2|).
  --   Source:
  --   https://math.stackexchange.com/questions/41269/distance-between-two-ranges
  -- - Minimum distance: min(|a1 - b1|, |a2 - b2|).

  -- Distance is chosen so that "next span" in certain direction is the closest
  if search_method == 'cover_or_next' then return math.abs(span_1.left - span_2.left) end
  if search_method == 'cover_or_prev' then return math.abs(span_1.right - span_2.right) end
  if search_method == 'cover_or_nearest' then
    return math.min(math.abs(span_1.left - span_2.left), math.abs(span_1.right - span_2.right))
  end
end

-- Work with Lua patterns -----------------------------------------------------
H.extract_span = function(s, extract_pattern, tobj_type)
  local positions = { s:match(extract_pattern) }

  local is_all_numbers = true
  for _, pos in ipairs(positions) do
    if type(pos) ~= 'number' then is_all_numbers = false end
  end

  local is_valid_positions = is_all_numbers and (#positions == 2 or #positions == 4)
  if not is_valid_positions then
    local msg = 'Could not extract proper positions (two or four empty captures) from '
      .. string.format([[string '%s' with extraction pattern '%s'.]], s, extract_pattern)
    H.error(msg)
  end

  local ai_spans
  if #positions == 2 then
    ai_spans = {
      a = { left = 1, right = s:len() },
      i = { left = positions[1], right = positions[2] - 1 },
    }
  else
    ai_spans = {
      a = { left = positions[1], right = positions[4] - 1 },
      i = { left = positions[2], right = positions[3] - 1 },
    }
  end

  return ai_spans[tobj_type]
end

-- Work with cursor neighborhood ----------------------------------------------
---@param reference_region table Reference region.
---@param n_neighbors number Maximum number of neighbors to include before
---   start line and after end line.
---@private
H.get_neighborhood = function(reference_region, n_neighbors)
  if reference_region == nil then
    -- Use region covering cursor position by default
    local cur_pos = vim.api.nvim_win_get_cursor(0)
    cur_pos = { line = cur_pos[1], col = cur_pos[2] + 1 }
    reference_region = { left = cur_pos, right = cur_pos }
  end
  n_neighbors = n_neighbors or 0

  -- '2d neighborhood': position is determined by line and column
  local line_start = math.max(1, reference_region.left.line - n_neighbors)
  local line_end = math.min(vim.api.nvim_buf_line_count(0), reference_region.right.line + n_neighbors)
  local neigh2d = vim.api.nvim_buf_get_lines(0, line_start - 1, line_end, false)
  -- Append 'newline' character to distinguish between lines in 1d case
  for k, v in pairs(neigh2d) do
    neigh2d[k] = v .. '\n'
  end

  -- '1d neighborhood': position is determined by offset from start
  local neigh1d = table.concat(neigh2d, '')

  -- Convert 2d buffer position to 1d offset
  local pos_to_offset = function(pos)
    local line_num = line_start
    local offset = 0
    while line_num < pos.line do
      offset = offset + neigh2d[line_num - line_start + 1]:len()
      line_num = line_num + 1
    end

    return offset + pos.col
  end

  -- Convert 1d offset to 2d buffer position
  local offset_to_pos = function(offset)
    local line_num = 1
    local line_offset = 0
    while line_num <= #neigh2d and line_offset + neigh2d[line_num]:len() < offset do
      line_offset = line_offset + neigh2d[line_num]:len()
      line_num = line_num + 1
    end

    return { line = line_start + line_num - 1, col = offset - line_offset }
  end

  -- Convert 2d region to 1d span
  local region_to_span =
    function(region) return { left = pos_to_offset(region.left), right = pos_to_offset(region.right) } end

  -- Convert 1d span to 2d region
  local span_to_region = function(span)
    -- NOTE: this might lead to outside of line positions due to added `\n` at
    -- the end of lines in 1d-neighborhood. However, this is crucial for
    -- allowing `i` textobjects to collapse multiline selections.
    return { left = offset_to_pos(span.left), right = offset_to_pos(span.right) }
  end

  return {
    n_neighbors = n_neighbors,
    region = reference_region,
    ['1d'] = neigh1d,
    ['2d'] = neigh2d,
    pos_to_offset = pos_to_offset,
    offset_to_pos = offset_to_pos,
    region_to_span = region_to_span,
    span_to_region = span_to_region,
  }
end

-- Work with user input -------------------------------------------------------
H.user_textobject_id = function(ai_type)
  -- Get from user single character textobject identifier
  local needs_help_msg = true
  vim.defer_fn(function()
    if not needs_help_msg then return end

    local msg = string.format('Enter `%s` textobject identifier (single character) ', ai_type)
    H.message(msg)
  end, 1000)
  local ok, char = pcall(vim.fn.getchar)
  needs_help_msg = false

  -- Terminate if couldn't get input (like with <C-c>) or it is `<Esc>`
  if not ok or char == 27 then return nil end

  if type(char) == 'number' then char = vim.fn.nr2char(char) end
  if char:find('^[%w%p%s]$') == nil then
    H.message('Input must be single character: alphanumeric, punctuation, or space.')
    return nil
  end

  return char
end

H.user_input = function(prompt, text)
  -- Register temporary keystroke listener to distinguish between cancel with
  -- `<Esc>` and immediate `<CR>`.
  local on_key = vim.on_key or vim.register_keystroke_callback
  local was_cancelled = false
  on_key(function(key)
    if key == vim.api.nvim_replace_termcodes('<Esc>', true, true, true) then was_cancelled = true end
  end, H.ns_id.input)

  -- Ask for input
  local opts = { prompt = '(mini.ai) ' .. prompt .. ': ', default = text or '' }
  -- Use `pcall` to allow `<C-c>` to cancel user input
  local ok, res = pcall(vim.fn.input, opts)

  -- Stop key listening
  on_key(nil, H.ns_id.input)

  if not ok or was_cancelled then return end
  return res
end

-- Work with Visual mode ------------------------------------------------------
H.is_visual_mode = function()
  local cur_mode = vim.fn.mode()
  -- '\22' is an escaped `<C-v>`
  return cur_mode == 'v' or cur_mode == 'V' or cur_mode == '\22', cur_mode
end

H.exit_to_normal_mode = function()
  -- '\28\14' is an escaped version of `<C-\><C-n>`
  vim.cmd('normal! \28\14')
end

H.get_visual_region = function()
  local is_vis, _ = H.is_visual_mode()
  if not is_vis then return end
  local res = {
    left = { line = vim.fn.line('v'), col = vim.fn.col('v') },
    right = { line = vim.fn.line('.'), col = vim.fn.col('.') },
  }
  if res.left.line > res.right.line or (res.left.line == res.right.line and res.left.col > res.right.col) then
    res = { left = res.right, right = res.left }
  end
  return res
end

-- Utilities ------------------------------------------------------------------
H.message = function(msg)
  vim.cmd([[echon '']])
  vim.cmd('redraw')
  vim.cmd('echomsg ' .. vim.inspect('(mini.ai) ' .. msg))
end

H.error = function(msg) error(string.format('(mini.ai) %s', msg), 0) end

H.map = function(mode, key, rhs, opts)
  if key == '' then return end

  opts = vim.tbl_deep_extend('force', { noremap = true, silent = true }, opts or {})

  -- Use mapping description only in Neovim>=0.7
  if vim.fn.has('nvim-0.7') == 0 then opts.desc = nil end

  vim.api.nvim_set_keymap(mode, key, rhs, opts)
end

H.string_find = function(s, pattern, init)
  -- Match only start of full string if pattern says so.
  -- This is needed because `string.find()` doesn't do this.
  -- Example: `string.find('(aaa)', '^.*$', 4)` returns `4, 5`
  if pattern:sub(1, 1) == '^' and init > 1 then return nil end

  return string.find(s, pattern, init)
end

---@param arr table List of items. If item is list, consider as set for
---   product. Else - make it single item list.
---@private
H.cartesian_product = function(arr)
  if not (vim.tbl_islist(arr) and #arr > 0) then return {} end
  arr = vim.tbl_map(function(x) return vim.tbl_islist(x) and x or { x } end, arr)

  local res, cur_item = {}, {}
  local process
  process = function(level)
    for i = 1, #arr[level] do
      table.insert(cur_item, arr[level][i])
      if level == #arr then
        -- Flatten array to allow tables as elements of step tables
        table.insert(res, vim.tbl_flatten(vim.deepcopy(cur_item)))
      else
        process(level + 1)
      end
      table.remove(cur_item, #cur_item)
    end
  end

  process(1)
  return res
end

-- TODO:
-- - Tests.
-- - Documentation.

-- Notes:
-- - To consecutively evolve `i`textobject, use `count` 2. Example: `2i)`.

-- Test cases

-- Brackets:
-- (
-- ___ [ (aaa) (bbb) ]  [{ccc}]
-- )
-- (ddd)

-- Brackets with whitespace:
-- (  aa   ) [bb   ] {  cc}

-- Multiline brackets to test difference between `i)` and `i(`; also collapsing
-- multiline regions (uncomment before testing):
-- (
--
-- a
--
-- )

-- Empty selections (test for `v`, `c`, `d`, `y` paired with `(` and `)`):
-- () [] {}
-- (    ) ( ) [   ] {  } (for `i(`, `i[`, `i{`)
-- '' "" ``
-- __ 4444

-- Evolving of quotes (tests for `%bxx` pattern; use with all `search_method`):
-- '   ' ' ' ' '  '
-- ' '  " ' ' "   ' '

-- Evolving of default textobjects:
-- aa_bb_cc__dd__
-- aa________bb______cc
-- 1  2  2  1  2  1  2

-- User prompted textobject:
-- e  e  e  o  e  e  o  e  o  o  o

-- Evolution of custom textobject using 'a.-b' pattern:
-- vim.b.miniai_config = { custom_textobjects = { ['~'] = { '``.-~~', '^..().-().$' } } }
-- `` ~~ ``
-- `` ``   ~~    ~~ `` ~~ (try between two `~~`)
-- `` ~~  `` ~~

-- Custom textobjects:
-- vim.b.miniai_config = { custom_textobjects = { D = { '()%d%d%d%d%-%d%d%-%d%d()' } } }
-- 2022-07-10
--
-- vim.b.miniai_config = { custom_textobjects = { d = { '()%f[%d]%d+()' } } }
-- 1     10     1000
--
-- vim.b.miniai_config = { custom_textobjects = { c = { { '[A-Z][%l%d]*', '%f[%S][%l%d]+', '%f[%P][%l%d]+' }, '^().*()$' } } }
-- SomeCamelCase startsWithSmall _startsWithPunct

-- Argument textobject:
-- (  aa  , bb,  cc  ,        dd)
-- f(aaa, g(bbb, ccc), ddd)
-- (aa) = f(aaaa, g(bbbb), ddd)

-- Cases from 'wellle/targets.vim':
-- vector<int> data = { variable1 * variable2, test(variable3, 10) * 15 };
-- struct Foo<A, Fn(A) -> bool> { ... }
-- if (window.matchMedia("(min-width: 180px)").matches) {

MiniAi.setup()
return MiniAi
