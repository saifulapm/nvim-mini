-- MIT License Copyright (c) 2022 Evgeni Chasnovski

-- TODO:
-- Code:
--
-- Tests:
-- - General:
--     - "Single animation active" rule is true for all supported animations.
--     - Emits "done event" after finishing.
-- - Cursor move:
--     - Mark can be placed inside/outside line width.
--     - Multibyte characters are respected.
--     - Folds are ignored.
--     - Window view does not matter.
-- - Scroll:
--     - `max_output_steps` in default `subscroll` correctly respected: total
--       number of steps never exceeds it and subscroll are divided as equal as
--       possible (with remainder equally split between all subscrolls).
--     - Manual scroll during animated scroll is done without jump directly
--       from current window view.
--     - One command resulting into several `WinScrolled` events (like
--       `nnoremap n nzvzz`) is not really working.
--       Use `MiniAnimate.execute_after()`.
--     - There shouldn't be any step after `n_steps`. Specifically, manually
--       setting cursor *just* after scroll end should not lead to restoring
--       cursor some time later. This is more a test for appropriate treatment
--       of step 0.
--     - Cursor during scroll should be placed at final position or at first
--       column of top/bottom line (whichever is closest) if it is outside of
--       current window view.
--     - Switching window and/or buffer should result into immediate stop of
--       animation.
-- - Resize:
--     - Works when resizing windows (`<C-w>|`, `<C-w>_`, `<C-w>=`, other
--       manual command).
--     - Works when opening new windows (`<C-w>v`, `<C-w>s`, other manual
--       command).
--     - Works when closing windows (`:quit`, manual command).
--     - Doesn't animate scroll during animation (including at the end).
--     - Works with `winheight`/`winwidth` in Neovim>=0.9.
--     - No view flicker when resizing from small to big width when cursor is
--       on the end of long line. Tests:
--         - `set winwidth=120 winheight=40` and hop between two vertically
--           split windows with cursor on `$` (in Neovim nightly).
--           This is particularly challenging because it seems that cursor
--           should always be visible inside current window.
--         - `<C-w>|` and then `<C-w>=` should not cause view to flicker.
-- - Open/close:
--     - Works when open/close tabpage. Including `animate_single` option for
--       "wipe" position. Including on second time (test using tabpage number
--       and not tabpage id).
--
-- Documentation:
-- - Manually scrolling (like with `<C-d>`/`<C-u>`) while scrolling animation
--   is performed leads to a scroll from the window view active at the moment
--   of manual scroll. Leads to an undershoot of scrolling.
-- - Scroll animation is essentially a precisely scheduled non-blocking
--   subscroll. This has two important interconnected consequences:
--     - If another scroll is attempted to be done during the animation, it is
--       done based on the **currently visible** window view. Example: if user
--       presses |CTRL-D| and then |CTRL-U| when animation is half done, window
--       will not display the previous view half of 'scroll' above it.
--       This especially affects scrolling with mouse wheel, as each its turn
--       results in a new scroll for number of lines defined by 'mousescroll'.
--       To mitigate this issue, configure `config.scroll.subscroll()` to
--       return `nil` if number of lines to scroll is less or equal to one
--       emitted by mouse wheel. Like by setting `min_input` option of
--       |MiniAnimate.gen_subscroll.equal()| to be one greater than that number.
--     - It breaks the use of several scrolling commands in the same command.
--       Use |MiniAnimate.execute_after()| to schedule action after reaching
--       target window view. Example: a useful `nnoremap n nzvzz` mapping
--       (consecutive application of |n|, |zv|, and |zz|) should have this
--       right hand side:
-- `<Cmd>lua vim.cmd('normal! n'); MiniAnimate.execute_after('scroll', 'normal! zvzz')<CR>`.
--
-- - Scroll animation is done only for vertical scroll inside current window.
-- - If output of either `config.cursor.path()` or `config.scroll.subscroll()`
--   is `nil` or array of length 0, animation is suspended.
-- - Minimum versions:
--     - `cursor` needs 0.7.0 to work fully (needs |getcursorcharpos()|).
--     - `scroll` works on all supported versions. Works best with Neovim>=0.9.
--     - `resize` works on all supported versions. Works best with Neovim>=0.9.
--     - `open` works on all supported versions.
--     - `close` works on all supported versions.
-- - Animation of scroll and resize works best with Neovim>=0.9 (after updates
--   to |WinScrolled| event and introduction of |WinResized| event). For
--   example, resize animation resulting from effect of 'winheight'/'winwidth'
--   will work properly.
--   Context:
--     - https://github.com/neovim/neovim/issues/18222
--     - https://github.com/vim/vim/issues/10628
--     - https://github.com/neovim/neovim/pull/13589
--     - https://github.com/neovim/neovim/issues/11532
-- - Animation done events.

-- Documentation ==============================================================
--- Animate common Neovim actions
---
--- Features:
--- - Animate cursor movement inside same buffer. Cursor path is configurable.
--- - Animate scrolling with a scheduled series of subscrolls ("smooth scrolling").
--- - Animate window resize by changing whole layout.
--- - Animate window open/close with a series of floating windows.
--- - Customizable animation timings.
--- - Ability to enable/disable per animation type.
---
--- # Setup~
---
--- This module needs a setup with `require('mini.animate').setup({})` (replace
--- `{}` with your `config` table). It will create global Lua table `MiniAnimate`
--- which you can use for scripting or manually (with `:lua MiniAnimate.*`).
---
--- See |MiniAnimate.config| for available config settings.
---
--- You can override runtime config settings (like `config.modifiers`) locally
--- to buffer inside `vim.b.minianimate_config` which should have same structure
--- as `MiniAnimate.config`. See |mini.nvim-buffer-local-config| for more details.
---
--- # Comparisons~
--- - Neovide:
--- - '???/neoscroll.nvim':
--- - '???/specs.nvim':
--- - 'DanilaMihailov/beacon.nvim'
--- - 'camspiers/lens.vim'
---
--- # Highlight groups~
---
--- * `MiniAnimateCursor` - highlight of cursor during its animated movement.
---
--- To change any highlight group, modify it directly with |:highlight|.
---
--- # Disabling~
---
--- To disable, set `g:minianimate_disable` (globally) or `b:minianimate_disable`
--- (for a buffer) to `v:true`. Considering high number of different scenarios
--- and customization intentions, writing exact rules for disabling module's
--- functionality is left to user. See |mini.nvim-disabling-recipes| for common
--- recipes.
---@tag mini.animate
---@tag MiniAnimate

---@diagnostic disable:undefined-field

-- Module definition ==========================================================
-- TODO: make local before release.
MiniAnimate = {}
H = {}

--- Module setup
---
---@param config table|nil Module config table. See |MiniAnimate.config|.
---
---@usage `require('mini.animate').setup({})` (replace `{}` with your `config` table)
MiniAnimate.setup = function(config)
  -- Export module
  _G.MiniAnimate = MiniAnimate

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Module behavior
  -- NOTEs:
  -- - Inside `WinScrolled` try to first animate resize before scroll to avoid
  --   flickering.
  -- - Use `vim.schedule()` for "open" animation to get a window data used for
  --   displaying (and not one after just opening). Useful for 'nvim-tree'.
  -- - Track scroll state immediately to avoid first scroll being non-animated.
  vim.api.nvim_exec(
    [[augroup MiniAnimate
        au!
        au CursorMoved * lua MiniAnimate.auto_cursor()
        au WinScrolled * lua MiniAnimate.auto_resize(); MiniAnimate.auto_scroll()
        au WinEnter    * lua MiniAnimate.track_scroll_state()
        au WinNew      * lua vim.schedule(MiniAnimate.auto_openclose)
        au WinClosed   * lua MiniAnimate.auto_openclose("close")
      augroup END]],
    false
  )
  MiniAnimate.track_scroll_state()

  -- Create highlighting
  vim.api.nvim_exec('hi default MiniAnimateCursor gui=reverse,nocombine', false)
end

--- Module config
---
--- Default values:
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
---@text # Options ~
---
MiniAnimate.config = {
  -- Cursor path
  cursor = {
    enable = true,
    timing = function(_, n) return 250 / n end,
    path = function(destination) return H.path_line(destination, { predicate = H.default_path_predicate }) end,
  },

  -- Vertical scroll
  scroll = {
    enable = true,
    timing = function(_, n) return 250 / n end,
    subscroll = function(total_scroll)
      return H.subscroll_equal(total_scroll, { predicate = H.default_subscroll_predicate, max_output_steps = 60 })
    end,
  },

  -- Window resize
  resize = {
    enable = true,
    timing = function(_, n) return 250 / n end,
  },

  -- Window open
  open = {
    enable = true,
    timing = function(_, n) return 250 / n end,
    position = function(win_id) return H.position_static(win_id, { n_steps = 25, animate_single = true }) end,
    winblend = function(s, n) return 80 + 20 * (s / n) end,
  },

  -- Window close
  close = {
    enable = true,
    timing = function(_, n) return 250 / n end,
    position = function(win_id) return H.position_static(win_id, { n_steps = 25, animate_single = true }) end,
    winblend = function(s, n) return 80 + 20 * (s / n) end,
  },
}
--minidoc_afterlines_end

-- Module functionality =======================================================
--- Check animation activity
---
---@param animation_type string One of supported animation types
---   (entries of |MiniAnimate.config|).
---
---@return boolean Whether the animation is currently active.
MiniAnimate.is_active = function(animation_type)
  local res = H.cache[animation_type .. '_is_active']
  if res == nil then H.error('Wrong `animation_type` for `is_active()`.') end
  return res
end

--- Execute action after some animation is done
---
--- Execute action immediately if animation is not active (checked with
--- |MiniAnimate.is_active()|). Else, schedule its execution until after
--- animation is done (on corresponding |MiniAnimate-done-events|).
---
--- Mostly meant to be used inside mappings.
---
--- Example ~
---
--- A useful `nnoremap n nzvzz` mapping (consecutive application of |n|, |zv|,
--- and |zz|) should have this right hand side:
--- `<Cmd>lua vim.cmd('normal! n'); MiniAnimate.execute_after('scroll', 'normal! zvzz')<CR>`.
---
---@param animation_type string One of supported animation types
---   (as in |MiniAnimate.is_active()|).
---@param action string|function Action to be executed. If string, executed as
---   command (via |vim.cmd()|).
MiniAnimate.execute_after = function(animation_type, action)
  local event_name = H.animation_done_events[animation_type]
  if event_name == nil then H.error('Wrong `animation_type` for `execute_after`.') end

  local callable = action
  if type(callable) == 'string' then callable = function() vim.cmd(action) end end
  if not vim.is_callable(callable) then
    H.error('Argument `action` of `execute_after()` should be string or callable.')
  end

  -- Schedule conditional action execution to allow animation to actually take
  -- effect. This helps creating more universal mappings, because some commands
  -- (like `n`) not always result into scrolling.
  vim.schedule(function()
    if MiniAnimate.is_active(animation_type) then
      -- TODO: use `nvim_create_autocmd()` after Neovim<=0.6 support is dropped
      MiniAnimate._action = callable
      local au_cmd = string.format('au User %s ++once lua MiniAnimate._action(); MiniAnimate._action = nil', event_name)
      vim.cmd(au_cmd)
    else
      callable()
    end
  end)
end

-- Action (step 0) - wait (step 1) - action (step 1) - ...
-- `step_action` should return `false` or `nil` (equivalent to not returning anything explicitly) in order to stop animation.
--- Animate action
---
--- This is equivalent to asynchronous execution of the following algorithm:
--- - Call `step_action(0)` immediately after calling this function. Stop if
---   action returned `false` or `nil`.
--- - Wait `step_timing(1)` milliseconds.
--- - Call `step_action(1)`. Stop if it returned `false` or `nil`.
--- - Wait `step_timing(2)` milliseconds.
--- - Call `step_action(2)`. Stop if it returned `false` or `nil`.
--- - ...
---
---
--- Notes:
--- - Animation is also stopped on action error or if maximum number of steps
---   is reached.
--- - Asynchronous execution is done with |uv.new_timer()|. It only allows
---   integer parts as repeat value. This has several implications:
---     - Outputs of `step_timing()` are accumulated in order to preserve total
---       execution time.
---     - Any wait time less than 1 ms means that action will be executed
---       immediately.
---
---@param step_action function Callable which takes `step` (integer 0, 1, 2,
---   etc. indicating current step) and executes some action. Its return value
---   defines when animation should stop: values `false` and `nil` (equivalent
---   to no explicit return) stop animation timer; any other continues it.
---@param step_timing function Callable which takes `step` (integer 1, 2, etc.
---   indicating current step) and returns how many milliseconds to wait before
---   executing step.
---@param opts table Options. Possible fields:
---   - <max_steps> - Maximum value of allowed step to execute. Default: 10000000.
MiniAnimate.animate = function(step_action, step_timing, opts)
  opts = vim.tbl_deep_extend('force', { max_steps = 10000000 }, opts or {})

  local step, max_steps = 0, opts.max_steps
  local timer, wait_time = vim.loop.new_timer(), 0

  local draw_step
  draw_step = vim.schedule_wrap(function()
    local ok, should_continue = pcall(step_action, step)
    if not (ok and should_continue and step < max_steps) then
      timer:stop()
      return
    end

    step = step + 1
    wait_time = wait_time + step_timing(step)

    -- Repeat value of `timer` seems to be rounded down to milliseconds. This
    -- means that values less than 1 will lead to timer stop repeating. Instead
    -- call next step function directly.
    if wait_time < 1 then
      timer:set_repeat(0)
      -- Use `return` to make this proper "tail call"
      return draw_step()
    else
      timer:set_repeat(wait_time)
      wait_time = wait_time - timer:get_repeat()
      timer:again()
    end
  end)

  -- Start non-repeating timer without callback execution
  timer:start(10000000, 0, draw_step)

  -- Draw step zero (at origin) immediately
  draw_step()
end

--- Generate animation timing
---
--- Each field corresponds to one family of progression which can be customized
--- further by supplying appropriate arguments.
---
--- This is a table with function elements. Call to actually get specification.
---
--- Example: >
--- local animation = require('mini.animation')
--- local gen_timing = animation.gen_timing
--- animation.setup({
---   cursor = { timing = gen_timing.linear({ duration = 100, unit = 'total' }) },
--- })
---
---@seealso: |MiniIndentscope.gen_animation|
MiniAnimate.gen_timing = {}

---@alias __timing_opts table Options that control progression. Possible keys:
---   - <easing> `(string)` - a subtype of progression. One of "in"
---     (accelerating from zero speed), "out" (decelerating to zero speed),
---     "in-out" (default; accelerating halfway, decelerating after).
---   - <duration> `(number)` - duration (in ms) of a unit. Default: 20.
---   - <unit> `(string)` - which unit's duration `opts.duration` controls. One
---     of "step" (default; ensures average duration of step to be `opts.duration`)
---     or "total" (ensures fixed total duration regardless of scope's range).
---@alias __timing_return function Timing function (see |MiniAnimate-config|).

--- Generate no animation
---
--- Show final result immediately. Usually better to use `enable` field in
--- `config` if you want to disable animation.
MiniAnimate.gen_timing.none = function()
  return function() return 0 end
end

--- Generate linear progression
---
---@param opts __timing_opts
---
---@return __timing_return
MiniAnimate.gen_timing.linear = function(opts) return H.timing_arithmetic(0, H.normalize_timing_opts(opts)) end

--- Generate quadratic progression
---
---@param opts __timing_opts
---
---@return __timing_return
MiniAnimate.gen_timing.quadratic = function(opts) return H.timing_arithmetic(1, H.normalize_timing_opts(opts)) end

--- Generate cubic progression
---
---@param opts __timing_opts
---
---@return __timing_return
MiniAnimate.gen_timing.cubic = function(opts) return H.timing_arithmetic(2, H.normalize_timing_opts(opts)) end

--- Generate quartic progression
---
---@param opts __timing_opts
---
---@return __timing_return
MiniAnimate.gen_timing.quartic = function(opts) return H.timing_arithmetic(3, H.normalize_timing_opts(opts)) end

--- Generate exponential progression
---
---@param opts __timing_opts
---
---@return __timing_return
MiniAnimate.gen_timing.exponential = function(opts) return H.timing_geometrical(H.normalize_timing_opts(opts)) end

--- Generate animation path
---
--- Animation path - callable which takes `destination` argument (2d integer
--- point in (line, col) coordinates) and returns array of relative to (0, 0)
--- places for animation to visit.
MiniAnimate.gen_path = {}

MiniAnimate.gen_path.line = function(opts)
  opts = vim.tbl_deep_extend('force', { predicate = H.default_path_predicate }, opts or {})

  return function(destination) return H.path_line(destination, opts) end
end

MiniAnimate.gen_path.angle = function(opts)
  opts = opts or {}
  local predicate = opts.predicate or H.default_path_predicate
  local first_direction = opts.first_direction or 'horizontal'

  local append_horizontal = function(res, dest_col, const_line)
    local step = H.make_step(dest_col)
    if step == 0 then return end
    for i = 0, dest_col - step, step do
      table.insert(res, { const_line, i })
    end
  end

  local append_vertical = function(res, dest_line, const_col)
    local step = H.make_step(dest_line)
    if step == 0 then return end
    for i = 0, dest_line - step, step do
      table.insert(res, { i, const_col })
    end
  end

  return function(destination)
    -- Don't animate in case of false predicate
    if not predicate(destination) then return {} end

    -- Travel along horizontal/vertical lines
    local res = {}
    if first_direction == 'horizontal' then
      append_horizontal(res, destination[2], 0)
      append_vertical(res, destination[1], destination[2])
    else
      append_vertical(res, destination[1], 0)
      append_horizontal(res, destination[2], destination[1])
    end

    return res
  end
end

MiniAnimate.gen_path.walls = function(opts)
  opts = opts or {}
  local predicate = opts.predicate or H.default_path_predicate
  local width = opts.width or 10

  return function(destination)
    -- Don't animate in case of false predicate
    if not predicate(destination) then return {} end

    -- Don't animate in case of no movement
    if destination[1] == 0 and destination[2] == 0 then return {} end

    local dest_line, dest_col = destination[1], destination[2]
    local res = {}
    for i = width, 1, -1 do
      table.insert(res, { dest_line, dest_col + i })
      table.insert(res, { dest_line, dest_col - i })
    end
    return res
  end
end

MiniAnimate.gen_path.spiral = function(opts)
  opts = opts or {}
  local predicate = opts.predicate or H.default_path_predicate
  local width = opts.width or 2

  local add_layer = function(res, w, destination)
    local dest_line, dest_col = destination[1], destination[2]
    --stylua: ignore start
    for j = -w, w-1 do table.insert(res, { dest_line - w, dest_col + j }) end
    for i = -w, w-1 do table.insert(res, { dest_line + i, dest_col + w }) end
    for j = -w, w-1 do table.insert(res, { dest_line + w, dest_col - j }) end
    for i = -w, w-1 do table.insert(res, { dest_line - i, dest_col - w }) end
    --stylua: ignore end
  end

  return function(destination)
    -- Don't animate in case of false predicate
    if not predicate(destination) then return {} end

    -- Don't animate in case of no movement
    if destination[1] == 0 and destination[2] == 0 then return {} end

    local res = {}
    for w = width, 1, -1 do
      add_layer(res, w, destination)
    end
    return res
  end
end

--- Generate animation subscroll
---
--- Subscroll - callable which takes `total_scroll` argument (single non-negative
--- integer) and returns array of non-negative integers each representing the
--- amount of lines needed to be scrolled inside corresponding step. All subscroll
--- values should sum to input `total_scroll`.
MiniAnimate.gen_subscroll = {}

MiniAnimate.gen_subscroll.equal = function(opts)
  opts = vim.tbl_deep_extend('force', { predicate = H.default_subscroll_predicate, max_output_steps = 60 }, opts or {})

  return function(total_scroll) return H.subscroll_equal(total_scroll, opts) end
end

--- Generate position
MiniAnimate.gen_position = {}

MiniAnimate.gen_position.static = function(opts)
  opts = vim.tbl_deep_extend('force', { n_steps = 25, animate_single = true }, opts or {})

  return function(win_id) return H.position_static(win_id, opts) end
end

MiniAnimate.gen_position.center = function(opts)
  opts = opts or {}
  local direction = opts.direction or 'to_center'
  local animate_single = opts.animate_single
  if animate_single == nil then animate_single = true end

  return function(win_id)
    -- Possibly don't animate single-layout window (like in open/close tabpage)
    if not animate_single and H.is_single_window(win_id) then return {} end

    local pos = vim.fn.win_screenpos(win_id)
    local row, col = pos[1] - 1, pos[2] - 1
    local height, width = vim.api.nvim_win_get_height(win_id), vim.api.nvim_win_get_width(win_id)

    local n_steps = math.max(height, width)
    local res = {}
    for step = 1, n_steps do
      -- To and from center consist from same position, just in reverse order
      -- "From" should end and "to" should start with exactly height and width
      -- of window
      local numerator = direction == 'to_center' and (step - 1) or (n_steps - step)
      local coef = numerator / n_steps

      --stylua: ignore
      res[step] = {
        relative  = 'editor',
        anchor    = 'NW',
        row       = H.round(row + 0.5 * coef * height),
        col       = H.round(col + 0.5 * coef * width),
        width     = math.ceil((1 - coef) * width),
        height    = math.ceil((1 - coef) * height),
        focusable = false,
        zindex    = 1,
        style     = 'minimal',
      }
    end

    return res
  end
end

MiniAnimate.gen_position.wipe = function(opts)
  opts = opts or {}
  local direction = opts.diration or 'to_edge'
  local animate_single = opts.animate_single
  if animate_single == nil then animate_single = true end

  return function(win_id)
    -- Possibly don't animate single-layout window (like in open/close tabpage)
    local win_container = H.get_window_parent_container(win_id)
    if not animate_single and win_container == 'single' then return {} end

    -- Get window data
    local win_pos = vim.fn.win_screenpos(win_id)
    local top_row, left_col = win_pos[1], win_pos[2]
    local win_height, win_width = vim.api.nvim_win_get_height(win_id), vim.api.nvim_win_get_width(win_id)

    -- Compute progression data
    local cur_row, cur_col = top_row, left_col
    local cur_width, cur_height = win_width, win_height

    local increment_row, increment_col, increment_height, increment_width
    local n_steps

    --stylua: ignore
    if win_container == 'col' then
      -- Determine closest top/bottom screen edge and progress to it
      local bottom_row = top_row + win_height - 1
      local is_top_edge_closer = top_row < (vim.o.lines - bottom_row + 1)

      increment_row,   increment_col    = (is_top_edge_closer and 0 or 1), 0
      increment_width, increment_height = 0,                               -1
      n_steps = win_height
    else
      -- Determine closest left/right screen edge and progress to it
      local right_col = left_col + win_width - 1
      local is_left_edge_closer = left_col < (vim.o.columns - right_col + 1)

      increment_row,   increment_col    =  0, (is_left_edge_closer and 0 or 1)
      increment_width, increment_height = -1, 0
      n_steps = win_width
    end

    -- Make step positions
    local res = {}
    for i = 1, n_steps do
      -- Reverse output if progression is from edge
      local res_ind = direction == 'to_edge' and i or (n_steps - i + 1)
      res[res_ind] = {
        relative = 'editor',
        anchor = 'NW',
        row = cur_row - 1,
        col = cur_col - 1,
        width = cur_width,
        height = cur_height,
        focusable = false,
        zindex = 1,
        style = 'minimal',
      }
      cur_row = cur_row + increment_row
      cur_col = cur_col + increment_col
      cur_height = cur_height + increment_height
      cur_width = cur_width + increment_width
    end
    return res
  end
end

--- Generate `winblend` progression
MiniAnimate.gen_winblend = {}

MiniAnimate.gen_winblend.linear = function(opts)
  opts = opts or {}
  local from = opts.from or 80
  local to = opts.to or 100
  local diff = to - from

  return function(s, n) return from + (s / n) * diff end
end

MiniAnimate.auto_cursor = function()
  -- Don't animate if disabled
  local cursor_config = H.get_config().cursor
  if not cursor_config.enable or H.is_disabled() then
    -- Reset state to not use an outdated one if enabled again
    H.cache.cursor_state = { buf_id = nil, pos = {} }
    return
  end

  -- Don't animate if inside scroll animation
  if H.cache.scroll_is_active then return end

  -- Update necessary information. NOTE: update state only on `CursorMoved` and
  -- not inside every animation step (like in scroll animation) for performance
  -- reasons: cursor movement is much more common action than scrolling.
  local prev_state, new_state = H.cache.cursor_state, H.get_cursor_state()
  H.cache.cursor_state = new_state
  H.cache.cursor_event_id = H.cache.cursor_event_id + 1

  -- Don't animate if changed buffer
  if new_state.buf_id ~= prev_state.buf_id then return end

  -- Make animation step data and possibly animate
  local animate_step = H.make_cursor_step(prev_state, new_state, cursor_config)
  if not animate_step then return end

  H.start_cursor()
  MiniAnimate.animate(animate_step.step_action, animate_step.step_timing)
end

MiniAnimate.auto_scroll = function()
  -- Don't animate if disabled
  local scroll_config = H.get_config().scroll
  if not scroll_config.enable or H.is_disabled() then
    -- Reset state to not use an outdated one if enabled again
    H.cache.scroll_state = { buf_id = nil, win_id = nil, view = {} }
    return
  end

  -- Don't animate if nothing to animate. Mostly used to distinguish
  -- `WinScrolled` due to module animation from the other ones.
  local prev_state = H.cache.scroll_state
  if prev_state.view.topline == vim.fn.line('w0') then return end

  -- Update necessary information
  local new_state = H.get_scroll_state()
  H.cache.scroll_state = new_state
  H.cache.scroll_event_id = H.cache.scroll_event_id + 1

  -- Don't animate if changed buffer or window
  if new_state.buf_id ~= prev_state.buf_id or new_state.win_id ~= prev_state.win_id then return end

  -- Don't animate if inside resize animation. This reduces computations and
  -- occasional flickering.
  if H.cache.resize_is_active then return end

  -- Make animation step data and possibly animate
  local animate_step = H.make_scroll_step(prev_state, new_state, scroll_config)
  if not animate_step then return end

  H.start_scroll(prev_state)
  MiniAnimate.animate(animate_step.step_action, animate_step.step_timing)
end

MiniAnimate.track_scroll_state = function() H.cache.scroll_state = H.get_scroll_state() end

MiniAnimate.auto_resize = function()
  -- Don't animate if disabled
  local resize_config = H.get_config().resize
  if not resize_config.enable or H.is_disabled() then
    -- Reset state to not use an outdated one if enabled again
    H.cache.resize_state = {}
    return
  end

  -- Don't animate if inside scroll animation. This reduces computations and
  -- occasional flickering.
  if H.cache.scroll_is_active then return end

  -- Update state. This also ensures that window views are up to date.
  local prev_state, new_state = H.cache.resize_state, H.get_resize_state()
  H.cache.resize_state = new_state

  -- Don't animate if there is nothing to animate (should be same layout but
  -- different sizes). This also stops triggering animation on window scrolls.
  local same_state = H.is_equal_resize_state(prev_state, new_state)
  if not (same_state.layout and not same_state.sizes) then return end

  -- Register new event only in case there is something to animate
  H.cache.resize_event_id = H.cache.resize_event_id + 1

  -- Make animation step data and possibly animate
  local animate_step = H.make_resize_step(prev_state, new_state, resize_config)
  if not animate_step then return end

  H.start_resize(prev_state)
  MiniAnimate.animate(animate_step.step_action, animate_step.step_timing)
end

MiniAnimate.auto_openclose = function(action_type)
  action_type = action_type or 'open'

  -- Don't animate if disabled
  local config = H.get_config()[action_type]
  if not config.enable or H.is_disabled() then return end

  -- Get window id to act upon
  local win_id
  if action_type == 'close' then win_id = tonumber(vim.fn.expand('<amatch>')) end
  if action_type == 'open' then win_id = math.max(unpack(vim.api.nvim_list_wins())) end

  -- Don't animate if created window is not right (valid and not floating)
  if win_id == nil or not vim.api.nvim_win_is_valid(win_id) then return end
  if vim.api.nvim_win_get_config(win_id).relative ~= '' then return end

  -- Register new event only in case there is something to animate
  local event_id_name = action_type .. '_event_id'
  H.cache[event_id_name] = H.cache[event_id_name] + 1

  -- Make animation step data and possibly animate
  local animate_step = H.make_openclose_step(action_type, win_id, config)
  if not animate_step then return end

  H.start_openclose(action_type)
  MiniAnimate.animate(animate_step.step_action, animate_step.step_timing)
end

-- Helper data ================================================================
-- Module default config
H.default_config = MiniAnimate.config

-- Cache for various operations
H.cache = {
  -- Cursor move animation data
  cursor_event_id = 0,
  cursor_is_active = false,
  cursor_state = { buf_id = nil, pos = {} },

  -- Scroll animation data
  scroll_event_id = 0,
  scroll_is_active = false,
  scroll_state = { buf_id = nil, win_id = nil, view = {} },

  -- Resize animation data
  resize_event_id = 0,
  resize_is_active = false,
  resize_state = { layout = {}, sizes = {}, views = {} },

  -- Window open animation data
  open_event_id = 0,
  open_is_active = false,
  open_active_windows = {},

  -- Window close animation data
  close_event_id = 0,
  close_is_active = false,
  close_active_windows = {},
}

-- Namespaces for module operations
H.ns_id = {
  -- Extmarks used to show cursor path
  cursor = vim.api.nvim_create_namespace('MiniAnimateCursor'),
}

-- Identifier of empty buffer used inside open/close animations
H.empty_buf_id = nil

-- Names of `User` events triggered after certain type of animation is done
H.animation_done_events = {
  cursor = 'MiniAnimateDoneCursor',
  scroll = 'MiniAnimateDoneScroll',
  resize = 'MiniAnimateDoneResize',
  open = 'MiniAnimateDoneOpen',
  close = 'MiniAnimateDoneClose',
}

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  -- General idea: if some table elements are not present in user-supplied
  -- `config`, take them from default config
  vim.validate({ config = { config, 'table', true } })
  config = vim.tbl_deep_extend('force', H.default_config, config or {})

  vim.validate({
    cursor = { config.cursor, H.is_config_cursor },
    scroll = { config.scroll, H.is_config_scroll },
    resize = { config.resize, H.is_config_resize },
    open = { config.open, H.is_config_open },
    close = { config.close, H.is_config_close },
  })

  return config
end

H.apply_config = function(config) MiniAnimate.config = config end

H.is_disabled = function() return vim.g.minianimate_disable == true or vim.b.minianimate_disable == true end

H.get_config = function(config)
  return vim.tbl_deep_extend('force', MiniAnimate.config, vim.b.minianimate_config or {}, config or {})
end

-- General animation ----------------------------------------------------------
H.trigger_done_event =
  function(animation_type) vim.cmd('doautocmd User ' .. H.animation_done_events[animation_type]) end

-- Cursor ---------------------------------------------------------------------
H.make_cursor_step = function(state_from, state_to, opts)
  local pos_from, pos_to = state_from.pos, state_to.pos
  local destination = { pos_to[1] - pos_from[1], pos_to[2] - pos_from[2] }
  local path = opts.path(destination)
  if path == nil or #path == 0 then return end

  local n_steps = #path
  local timing = opts.timing

  -- Using explicit buffer id allows correct animation stop after buffer switch
  local event_id, buf_id = H.cache.cursor_event_id, state_from.buf_id

  return {
    step_action = function(step)
      -- Undraw previous mark. Doing it before early return allows to clear
      -- last animation mark.
      H.undraw_cursor_mark(buf_id)

      -- Stop animation if another cursor movement is active. Don't use
      -- `stop_cursor()` because it will also stop parallel animation.
      if H.cache.cursor_event_id ~= event_id then return false end

      -- Don't draw outside of set number of steps or not inside current buffer
      if n_steps <= step or vim.api.nvim_get_current_buf() ~= buf_id then return H.stop_cursor() end

      -- Draw cursor mark (starting from initial zero step)
      local pos = path[step + 1]
      H.draw_cursor_mark(pos_from[1] + pos[1], pos_from[2] + pos[2], buf_id)
      return true
    end,
    step_timing = function(step) return timing(step, n_steps) end,
  }
end

H.get_cursor_state = function()
  -- Use character column to allow tracking outside of line width
  local curpos = H.getcursorcharpos()
  return { buf_id = vim.api.nvim_get_current_buf(), pos = { curpos[2], curpos[3] + curpos[4] } }
end

H.draw_cursor_mark = function(line, virt_col, buf_id)
  -- Use only absolute coordinates. Allows to not draw outside of buffer.
  if line <= 0 or virt_col <= 0 then return end

  -- Compute window column at which to place mark. Don't use explicit `col`
  -- argument because it won't allow placing mark outside of text line.
  local win_col = virt_col - vim.fn.winsaveview().leftcol
  if win_col < 1 then return end

  -- Set extmark
  local extmark_opts = {
    id = 1,
    hl_mode = 'combine',
    priority = 1000,
    right_gravity = false,
    virt_text = { { ' ', 'MiniAnimateCursor' } },
    virt_text_win_col = win_col - 1,
    virt_text_pos = 'overlay',
  }
  pcall(vim.api.nvim_buf_set_extmark, buf_id, H.ns_id.cursor, line - 1, 0, extmark_opts)
end

H.undraw_cursor_mark = function(buf_id) pcall(vim.api.nvim_buf_del_extmark, buf_id, H.ns_id.cursor, 1) end

H.start_cursor = function()
  H.cache.cursor_is_active = true
  return true
end

H.stop_cursor = function()
  H.cache.cursor_is_active = false
  H.trigger_done_event('cursor')
  return false
end

-- Scroll ---------------------------------------------------------------------
H.make_scroll_step = function(state_from, state_to, opts)
  local from_line, to_line = state_from.view.topline, state_to.view.topline

  -- Compute how subscrolling is done
  local total_scroll = H.get_n_visible_lines(from_line, to_line) - 1
  local step_scrolls = opts.subscroll(total_scroll)

  -- Don't animate if no subscroll steps is returned
  if step_scrolls == nil or #step_scrolls == 0 then return end

  -- Compute scrolling key ('\25' and '\5' are escaped '<C-Y>' and '<C-E>') and
  -- final cursor position
  local scroll_key = from_line < to_line and '\5' or '\25'
  local final_cursor_pos = { state_to.view.lnum, state_to.view.col }

  local event_id, buf_id, win_id = H.cache.scroll_event_id, state_from.buf_id, state_from.win_id
  local n_steps, timing = #step_scrolls, opts.timing
  return {
    step_action = function(step)
      -- Stop animation if another scroll is active. Don't use `stop_scroll()`
      -- because it will stop parallel animation.
      if H.cache.scroll_event_id ~= event_id then return false end

      -- Stop animation if jumped to different buffer or window. Don't restore
      -- window view as it can only operate on current window.
      local is_same_win_buf = vim.api.nvim_get_current_buf() == buf_id and vim.api.nvim_get_current_win() == win_id
      if not is_same_win_buf then return H.stop_scroll() end

      -- Preform scroll. Possibly stop on error.
      local ok, _ = pcall(H.scroll_action, scroll_key, step_scrolls[step], final_cursor_pos)
      if not ok then return H.stop_scroll(state_to) end

      -- Update current scroll state for two reasons:
      -- - Be able to distinguish manual `WinScrolled` event from one created
      --   by `H.scroll_action()`.
      -- - Be able to start manual scrolling at any animation step.
      H.cache.scroll_state = H.get_scroll_state()

      -- Properly stop animation if step is too big
      if n_steps <= step then return H.stop_scroll(state_to) end

      return true
    end,
    step_timing = function(step) return timing(step, n_steps) end,
  }
end

H.scroll_action = function(key, n, final_cursor_pos)
  -- Scroll. Allow supplying non-valid `n` for initial "scroll" which sets
  -- cursor immediately, which reduces flicker.
  if n ~= nil and n > 0 then
    local command = string.format('normal! %d%s', n, key)
    vim.cmd(command)
  end

  -- Set cursor to properly handle final cursor position
  local top, bottom = vim.fn.line('w0'), vim.fn.line('w$')
  --stylua: ignore start
  local line, col = final_cursor_pos[1], final_cursor_pos[2]
  if line < top    then line, col = top,    0 end
  if bottom < line then line, col = bottom, 0 end
  --stylua: ignore end
  vim.api.nvim_win_set_cursor(0, { line, col })
end

H.start_scroll = function(start_state)
  H.cache.scroll_is_active = true
  if start_state ~= nil then vim.fn.winrestview(start_state.view) end
  return true
end

H.stop_scroll = function(end_state)
  if end_state ~= nil then vim.fn.winrestview(end_state.view) end
  H.cache.scroll_is_active = false
  H.trigger_done_event('scroll')
  return false
end

H.get_scroll_state = function()
  return {
    buf_id = vim.api.nvim_get_current_buf(),
    win_id = vim.api.nvim_get_current_win(),
    view = vim.fn.winsaveview(),
  }
end

-- Resize ---------------------------------------------------------------------
H.make_resize_step = function(state_from, state_to, opts)
  -- Compute number of animation steps
  local n_steps = H.get_resize_n_steps(state_from, state_to)
  if n_steps == nil or n_steps <= 1 then return end

  -- Create animation step
  local event_id, timing = H.cache.resize_event_id, opts.timing

  return {
    step_action = function(step)
      -- Do nothing on initialization
      if step == 0 then return true end

      -- Stop animation if another resize animation is active. Don't use
      -- `stop_resize()` because it will also stop parallel animation.
      if H.cache.resize_event_id ~= event_id then return false end

      -- Preform animation. Possibly stop on error.
      local step_state = H.make_convex_resize_state(state_from, state_to, step / n_steps)
      -- Use `false` to not restore cursor position to avoid horizontal flicker
      local ok, _ = pcall(H.apply_resize_state, step_state, false)
      if not ok then return H.stop_resize(state_to) end

      -- Properly stop animation if step is too big
      if n_steps <= step then return H.stop_resize(state_to) end

      return true
    end,
    step_timing = function(step) return timing(step, n_steps) end,
  }
end

_G.resize_times = {}
H.start_resize = function(start_state)
  H.cache.resize_is_active = true
  table.insert(_G.resize_times, 0.000001 * vim.loop.hrtime())
  -- Don't restore cursor position to avoid horizontal flicker
  if start_state ~= nil then H.apply_resize_state(start_state, false) end
  return true
end

H.stop_resize = function(end_state)
  if end_state ~= nil then H.apply_resize_state(end_state, true) end
  H.cache.resize_is_active = false
  table.insert(_G.resize_times, 0.000001 * vim.loop.hrtime())
  H.trigger_done_event('resize')
  return false
end

H.get_resize_state = function()
  local layout = vim.fn.winlayout()

  local windows = H.get_layout_windows(layout)
  local sizes, views = {}, {}
  for _, win_id in ipairs(windows) do
    sizes[win_id] = { height = vim.api.nvim_win_get_height(win_id), width = vim.api.nvim_win_get_width(win_id) }
    views[win_id] = vim.api.nvim_win_call(win_id, function() return vim.fn.winsaveview() end)
  end

  return { layout = layout, sizes = sizes, views = views }
end

H.is_equal_resize_state = function(state_1, state_2)
  return {
    layout = vim.deep_equal(state_1.layout, state_2.layout),
    sizes = vim.deep_equal(state_1.sizes, state_2.sizes),
  }
end

H.get_layout_windows = function(layout)
  local res = {}
  local traverse
  traverse = function(l)
    if l[1] == 'leaf' then
      table.insert(res, l[2])
      return
    end
    for _, sub_l in ipairs(l[2]) do
      traverse(sub_l)
    end
  end
  traverse(layout)

  return res
end

H.apply_resize_state = function(state, full_view)
  for win_id, dims in pairs(state.sizes) do
    vim.api.nvim_win_set_height(win_id, dims.height)
    vim.api.nvim_win_set_width(win_id, dims.width)
  end

  -- Use `or {}` to allow states without `view` (mainly inside animation)
  for win_id, view in pairs(state.views or {}) do
    vim.api.nvim_win_call(win_id, function()
      -- Allow to not restore full view. It mainly solves horizontal flickering
      -- when resizing from small to big width and cursor is on the end of long
      -- line. This is especially visible for Neovim>=0.9 and high 'winwidth'.
      -- Example: `set winwidth=120 winheight=40` and hop between two
      -- vertically split windows with cursor on `$` of long line.
      if full_view then
        vim.fn.winrestview(view)
        return
      end

      -- This triggers `CursorMoved` event, but nothing can be done
      -- (`noautocmd` is of no use, see https://github.com/vim/vim/issues/2084)
      vim.api.nvim_win_set_cursor(win_id, { view.lnum, view.leftcol })
      vim.fn.winrestview({ topline = view.topline, leftcol = view.leftcol })
    end)
  end

  -- Update current resize state to be able to start another resize animation
  -- at any current animation step. Recompute state to also capture `view`.
  H.cache.resize_state = H.get_resize_state()
end

H.get_resize_n_steps = function(state_from, state_to)
  local sizes_from, sizes_to = state_from.sizes, state_to.sizes
  local max_diff = 0
  for win_id, dims_from in pairs(sizes_from) do
    local height_absidff = math.abs(sizes_to[win_id].height - dims_from.height)
    local width_absidff = math.abs(sizes_to[win_id].width - dims_from.width)
    max_diff = math.max(max_diff, height_absidff, width_absidff)
  end

  return max_diff
end

H.make_convex_resize_state = function(state_from, state_to, coef)
  local sizes_from, sizes_to = state_from.sizes, state_to.sizes
  local res_sizes = {}
  for win_id, dims_from in pairs(sizes_from) do
    res_sizes[win_id] = {
      height = H.convex_point(dims_from.height, sizes_to[win_id].height, coef),
      width = H.convex_point(dims_from.width, sizes_to[win_id].width, coef),
    }
  end

  -- Intermediate states don't have `layout` (not needed) and `views` (because
  -- leads to flicker)
  return { sizes = res_sizes }
end

-- Open/close -----------------------------------------------------------------
H.make_openclose_step = function(action_type, win_id, config)
  -- Compute position progression
  local step_positions = config.position(win_id)
  if step_positions == nil or #step_positions == 0 then return end

  -- Produce animation steps.
  local n_steps, event_id_name = #step_positions, action_type .. '_event_id'
  local timing, winblend, event_id = config.timing, config.winblend, H.cache[event_id_name]
  local float_win_id

  return {
    step_action = function(step)
      -- Stop animation if another similar animation is active. Don't use
      -- `stop_openclose()` because it will also stop parallel animation.
      if H.cache[event_id_name] ~= event_id then
        pcall(vim.api.nvim_win_close, float_win_id, true)
        return false
      end

      -- Stop animation if exceeded number of steps
      if n_steps <= step then
        pcall(vim.api.nvim_win_close, float_win_id, true)
        return H.stop_openclose(action_type)
      end

      -- Empty buffer should always be valid (might have been closed by user command)
      if H.empty_buf_id == nil or not vim.api.nvim_buf_is_valid(H.empty_buf_id) then
        H.empty_buf_id = vim.api.nvim_create_buf(false, true)
      end

      -- Set step config to window. Possibly (re)open (it could have been
      -- manually closed like after `:only`)
      local float_config = step_positions[step + 1]
      if step == 0 or not vim.api.nvim_win_is_valid(float_win_id) then
        float_win_id = vim.api.nvim_open_win(H.empty_buf_id, false, float_config)
      else
        vim.api.nvim_win_set_config(float_win_id, float_config)
      end

      local new_winblend = H.round(winblend(step, n_steps))
      vim.api.nvim_win_set_option(float_win_id, 'winblend', new_winblend)

      return true
    end,
    step_timing = function(step) return timing(step, n_steps) end,
  }
end

H.start_openclose = function(action_type)
  H.cache[action_type .. '_is_active'] = true
  return true
end

H.stop_openclose = function(action_type)
  H.cache[action_type .. '_is_active'] = false
  H.trigger_done_event(action_type)
  return false
end

-- Animation timings ----------------------------------------------------------
H.normalize_timing_opts = function(x)
  x = vim.tbl_deep_extend('force', H.get_config(), { easing = 'in-out', duration = 20, unit = 'step' }, x or {})
  H.validate_if(H.is_valid_timing_opts, x, 'opts')
  return x
end

H.is_valid_timing_opts = function(x)
  if type(x.duration) ~= 'number' or x.duration < 0 then
    return false, [[In `gen_timing` option `duration` should be a positive number.]]
  end

  if not vim.tbl_contains({ 'in', 'out', 'in-out' }, x.easing) then
    return false, [[In `gen_timing` option `easing` should be one of 'in', 'out', or 'in-out'.]]
  end

  if not vim.tbl_contains({ 'total', 'step' }, x.unit) then
    return false, [[In `gen_timing` option `unit` should be one of 'step' or 'total'.]]
  end

  return true
end

--- Imitate common power easing function
---
--- Every step is preceeded by waiting time decreasing/increasing in power
--- series fashion (`d` is "delta", ensures total duration time):
--- - "in":  d*n^p; d*(n-1)^p; ... ; d*2^p;     d*1^p
--- - "out": d*1^p; d*2^p;     ... ; d*(n-1)^p; d*n^p
--- - "in-out": "in" until 0.5*n, "out" afterwards
---
--- This way it imitates `power + 1` common easing function because animation
--- progression behaves as sum of `power` elements.
---
---@param power number Power of series.
---@param opts table Options from `MiniAnimate.gen_timing` entry.
---@private
H.timing_arithmetic = function(power, opts)
  -- Sum of first `n_steps` natural numbers raised to `power`
  local arith_power_sum = ({
    [0] = function(n_steps) return n_steps end,
    [1] = function(n_steps) return n_steps * (n_steps + 1) / 2 end,
    [2] = function(n_steps) return n_steps * (n_steps + 1) * (2 * n_steps + 1) / 6 end,
    [3] = function(n_steps) return n_steps ^ 2 * (n_steps + 1) ^ 2 / 4 end,
  })[power]

  -- Function which computes common delta so that overall duration will have
  -- desired value (based on supplied `opts`)
  local duration_unit, duration_value = opts.unit, opts.duration
  local make_delta = function(n_steps, is_in_out)
    local total_time = duration_unit == 'total' and duration_value or (duration_value * n_steps)
    local total_parts
    if is_in_out then
      -- Examples:
      -- - n_steps=5: 3^d, 2^d, 1^d, 2^d, 3^d
      -- - n_steps=6: 3^d, 2^d, 1^d, 1^d, 2^d, 3^d
      total_parts = 2 * arith_power_sum(math.ceil(0.5 * n_steps)) - (n_steps % 2 == 1 and 1 or 0)
    else
      total_parts = arith_power_sum(n_steps)
    end
    return total_time / total_parts
  end

  return ({
    ['in'] = function(s, n) return make_delta(n) * (n - s + 1) ^ power end,
    ['out'] = function(s, n) return make_delta(n) * s ^ power end,
    ['in-out'] = function(s, n)
      local n_half = math.ceil(0.5 * n)
      local s_halved
      if n % 2 == 0 then
        s_halved = s <= n_half and (n_half - s + 1) or (s - n_half)
      else
        s_halved = s < n_half and (n_half - s + 1) or (s - n_half + 1)
      end
      return make_delta(n, true) * s_halved ^ power
    end,
  })[opts.easing]
end

--- Imitate common exponential easing function
---
--- Every step is preceeded by waiting time decreasing/increasing in geometric
--- progression fashion (`d` is 'delta', ensures total duration time):
--- - 'in':  (d-1)*d^(n-1); (d-1)*d^(n-2); ...; (d-1)*d^1;     (d-1)*d^0
--- - 'out': (d-1)*d^0;     (d-1)*d^1;     ...; (d-1)*d^(n-2); (d-1)*d^(n-1)
--- - 'in-out': 'in' until 0.5*n, 'out' afterwards
---
---@param opts table Options from `MiniAnimate.gen_timing` entry.
---@private
H.timing_geometrical = function(opts)
  -- Function which computes common delta so that overall duration will have
  -- desired value (based on supplied `opts`)
  local duration_unit, duration_value = opts.unit, opts.duration
  local make_delta = function(n_steps, is_in_out)
    local total_time = duration_unit == 'step' and (duration_value * n_steps) or duration_value
    -- Exact solution to avoid possible (bad) approximation
    if n_steps == 1 then return total_time + 1 end
    if is_in_out then
      local n_half = math.ceil(0.5 * n_steps)
      if n_steps % 2 == 1 then total_time = total_time + math.pow(0.5 * total_time + 1, 1 / n_half) - 1 end
      return math.pow(0.5 * total_time + 1, 1 / n_half)
    end
    return math.pow(total_time + 1, 1 / n_steps)
  end

  return ({
    ['in'] = function(s, n)
      local delta = make_delta(n)
      return (delta - 1) * delta ^ (n - s)
    end,
    ['out'] = function(s, n)
      local delta = make_delta(n)
      return (delta - 1) * delta ^ (s - 1)
    end,
    ['in-out'] = function(s, n)
      local n_half, delta = math.ceil(0.5 * n), make_delta(n, true)
      local s_halved
      if n % 2 == 0 then
        s_halved = s <= n_half and (n_half - s) or (s - n_half - 1)
      else
        s_halved = s < n_half and (n_half - s) or (s - n_half)
      end
      return (delta - 1) * delta ^ s_halved
    end,
  })[opts.easing]
end

-- Animation paths ------------------------------------------------------------
H.path_line = function(destination, opts)
  -- Don't animate in case of false predicate
  if not opts.predicate(destination) then return {} end

  -- Travel along the biggest horizontal/vertical difference, but stop one
  -- step before destination
  local l, c = destination[1], destination[2]
  local l_abs, c_abs = math.abs(l), math.abs(c)
  local max_diff = math.max(l_abs, c_abs)

  local res = {}
  for i = 0, max_diff - 1 do
    local prop = i / max_diff
    table.insert(res, { H.round(prop * l), H.round(prop * c) })
  end
  return res
end

H.default_path_predicate = function(destination) return destination[1] < -1 or 1 < destination[1] end

-- Animation subscroll --------------------------------------------------------
H.subscroll_equal = function(total_scroll, opts)
  -- Don't animate in case of false predicate
  if not opts.predicate(total_scroll) then return {} end

  -- Don't make more than `max_output_steps` steps
  local n_steps = math.min(total_scroll, opts.max_output_steps)
  return H.divide_equal(total_scroll, n_steps)
end

H.default_subscroll_predicate = function(total_scroll) return total_scroll > 1 end

-- Animation position ---------------------------------------------------------
H.position_static = function(win_id, opts)
  -- Possibly don't animate single-layout window (like in open/close tabpage)
  if not opts.animate_single and H.is_single_window(win_id) then return {} end

  local pos = vim.fn.win_screenpos(win_id)
  local res = {}
  for i = 1, opts.n_steps do
      --stylua: ignore
      res[i] = {
        relative  = 'editor',
        anchor    = 'NW',
        row       = pos[1] - 1,
        col       = pos[2] - 1,
        width     = vim.api.nvim_win_get_width(win_id),
        height    = vim.api.nvim_win_get_height(win_id),
        focusable = false,
        zindex    = 1,
        style     = 'minimal',
      }
  end
  return res
end

H.get_window_parent_container = function(win_id)
  local f
  f = function(layout, parent_container)
    local container, second = layout[1], layout[2]
    if container == 'leaf' then
      if second == win_id then return parent_container end
      return
    end

    for _, sub_layout in ipairs(second) do
      local res = f(sub_layout, container)
      if res ~= nil then return res end
    end
  end

  -- Important to get layout of tabpage window actually belongs to (as it can
  -- already be not current tabpage)
  -- NOTE: `winlayout()` takes tabpage number (non unique), not tabpage id
  local tabpage_id = vim.api.nvim_win_get_tabpage(win_id)
  local tabpage_nr = vim.api.nvim_tabpage_get_number(tabpage_id)
  return f(vim.fn.winlayout(tabpage_nr), 'single')
end

-- Predicators ----------------------------------------------------------------
H.is_config_cursor = function(x)
  if type(x) ~= 'table' then return false, H.msg_config('cursor', 'table') end
  if type(x.enable) ~= 'boolean' then return false, H.msg_config('cursor.enable', 'boolean') end
  if not vim.is_callable(x.timing) then return false, H.msg_config('cursor.timing', 'callable') end
  if not vim.is_callable(x.path) then return false, H.msg_config('cursor.path', 'callable') end

  return true
end

H.is_config_scroll = function(x)
  if type(x) ~= 'table' then return false, H.msg_config('scroll', 'table') end
  if type(x.enable) ~= 'boolean' then return false, H.msg_config('scroll.enable', 'boolean') end
  if not vim.is_callable(x.timing) then return false, H.msg_config('scroll.timing', 'callable') end
  if not vim.is_callable(x.subscroll) then return false, H.msg_config('scroll.subscroll', 'callable') end

  return true
end

H.is_config_resize = function(x)
  if type(x) ~= 'table' then return false, H.msg_config('resize', 'table') end
  if type(x.enable) ~= 'boolean' then return false, H.msg_config('resize.enable', 'boolean') end
  if not vim.is_callable(x.timing) then return false, H.msg_config('resize.timing', 'callable') end

  return true
end

H.is_config_open = function(x)
  if type(x) ~= 'table' then return false, H.msg_config('open', 'table') end
  if type(x.enable) ~= 'boolean' then return false, H.msg_config('open.enable', 'boolean') end
  if not vim.is_callable(x.timing) then return false, H.msg_config('open.timing', 'callable') end
  if not vim.is_callable(x.position) then return false, H.msg_config('open.position', 'callable') end
  if not vim.is_callable(x.winblend) then return false, H.msg_config('open.winblend', 'callable') end

  return true
end

H.is_config_close = function(x)
  if type(x) ~= 'table' then return false, H.msg_config('close', 'table') end
  if type(x.enable) ~= 'boolean' then return false, H.msg_config('close.enable', 'boolean') end
  if not vim.is_callable(x.timing) then return false, H.msg_config('close.timing', 'callable') end
  if not vim.is_callable(x.position) then return false, H.msg_config('close.position', 'callable') end
  if not vim.is_callable(x.winblend) then return false, H.msg_config('close.winblend', 'callable') end

  return true
end

H.msg_config = function(x_name, msg) return string.format('`%s` should be %s.', x_name, msg) end

-- Utilities ------------------------------------------------------------------
H.error = function(msg) error(string.format('(mini.animate) %s', msg), 0) end

H.validate_if = function(predicate, x, x_name)
  local is_valid, msg = predicate(x, x_name)
  if not is_valid then H.error(msg) end
end

H.get_n_visible_lines = function(from_line, to_line)
  local min_line, max_line = math.min(from_line, to_line), math.max(from_line, to_line)

  -- If `max_line` is inside fold, scrol should stop on the fold (not after)
  local max_line_fold_start = vim.fn.foldclosed(max_line)
  local target_line = max_line_fold_start == -1 and max_line or max_line_fold_start

  local i, res = min_line, 1
  while i < target_line do
    res = res + 1
    local end_fold_line = vim.fn.foldclosedend(i)
    i = (end_fold_line == -1 and i or end_fold_line) + 1
  end
  return res
end

-- This is needed for compatibility with Neovim<=0.6
-- TODO: Remove after compatibility with Neovim<=0.6 is dropped
H.getcursorcharpos = vim.fn.exists('*getcursorcharpos') == 1 and vim.fn.getcursorcharpos or vim.fn.getcurpos

H.make_step = function(x) return x == 0 and 0 or (x < 0 and -1 or 1) end

H.is_single_window = function(win_id)
  local tabpage_id = vim.api.nvim_win_get_tabpage(win_id)
  return #vim.api.nvim_tabpage_list_wins(tabpage_id) == 1
end

H.round = function(x) return math.floor(x + 0.5) end

H.divide_equal = function(x, n)
  local res, coef = {}, x / n
  for i = 1, n do
    res[i] = math.floor(i * coef) - math.floor((i - 1) * coef)
  end
  return res
end

H.convex_point = function(x, y, coef) return H.round((1 - coef) * x + coef * y) end

-- `virtcol2col()` is only present in Neovim>=0.8. Earlier Neovim versions will
-- have troubles dealing with multibyte characters.
H.virtcol2col = vim.fn.virtcol2col or function(_, _, col) return col end

return MiniAnimate
