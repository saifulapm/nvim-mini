---@alias   var_one   fun(type: string, data: any)
---@alias var_two Another data structure.
---   Its description spans over multiple lines.
---@alias %bad_name* This alias has bad name and should still work.

--- This is a file to test 'mini-dev.doc'
---
---@param x %bad_name*

local M = {}

---@title Second block
---
---@param a string Some string. List of items:
---   - Item 1.
---   - Item 2.
---@param b number Number.
---
---@return boolean
---
---@usage `M.fun(1, 2)`
function M.fun(a, b)
  return true
end

--- TITLE FOR `fun2`
---@text
--- This illustrates some code:
--- >
---   require('mini.doc').setup()
--- <
---@param x var_one
---@param y var_two
---@param z var_three
---@alias var_three This alias shouldn't be applied to previous line as it is
---   defined after it.
---@text
--- Some text after parameters.
M.fun2 = function(x, y, z)
  return x + y + z
end

--- ANNOTATION FOR SOME CLASS TABLE
---
---@class User
---
---@field login string User login.
---@field password string User password.
---@tag User user
M.User = {}

--- Private method that shouldn't be present in output
---@private
M._private_user = {}

--- Test for enclosing type
---
---@param a number Should work.
---@param b number[] Should work.
---@param c number|nil Should work.
---@param d table<string, number> Should work.
---@param e fun(a: string, b:number) Should work.
---@param f fun(a: string, b:number): table Should work.
---@param g NUMBER Shouldn't work.
---@param a_function function Should enclose second `function`.
---@param function_a function Should enclose second `function`.
---@param a_function_a function Should enclose second `function`.
---@param afunction function Should enclose second `function`.
---
---@return number Should work.
---@return ... Should work.

---@signature HELLO.WORLD(x, y)
---
---@text Test of `@eval` section as automatization of `config` documentation
---
---@eval a -= 1
---
---@eval _G.been_here = true
---
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
M.tab = {
  -- Some functional setting
  --minidoc_replace_start a = <function>,
  a = function()
    return 1 + 1
  end,
  --minidoc_replace_end
  -- A very important setting
  b = 2,
  c = {
    d = 3,
    e = 4,
  },
}
--minidoc_afterlines_end

return M