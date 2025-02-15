---@class snacks.image.doc
local M = {}

---@class snacks.image.Hover
---@field img snacks.image.Placement
---@field win snacks.win
---@field buf number

---@type table<string, {setup:(fun():vim.treesitter.Query), query?:vim.treesitter.Query|false}>
M._queries = {
  markdown = {
    setup = function()
      return vim.treesitter.query.parse("markdown_inline", [[(image (link_destination) @image) @anchor]])
    end,
  },
  html = {
    setup = function()
      return vim.treesitter.query.parse(
        "html",
        [[
          (element
            (start_tag
              (tag_name) @tag (#eq? @tag "img")
              (attribute
              (attribute_name) @attr_name (#eq? @attr_name "src")
              (quoted_attribute_value (attribute_value) @image)
              )
            )
          ) @anchor
          (self_closing_tag
            (tag_name) @tag (#eq? @tag "img")
            (attribute
              (attribute_name) @attr_name (#eq? @attr_name "src")
              (quoted_attribute_value (attribute_value) @image)
            )
          ) @anchor
        ]]
      )
    end,
  },
  css = {
    setup = function()
      return vim.treesitter.query.parse(
        "css",
        [[
          (declaration
            (call_expression
              (function_name) @fn (#eq? @fn "url")
              (arguments  [(plain_value) @image (string_value (string_content) @image)]))
          ) @anchor
        ]]
      )
    end,
  },
}

local hover ---@type snacks.image.Hover?

function M.queries()
  local ret = {} ---@type vim.treesitter.Query[]
  for _, query in pairs(M._queries) do
    if query.query == nil then
      local ok, q = pcall(query.setup)
      query.query = ok and q or false
    end
    if query.query then
      table.insert(ret, query.query)
    end
  end
  return ret
end

---@param buf number
---@param src string
function M.resolve(buf, src)
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
  local s = Snacks.image.config.resolve and Snacks.image.config.resolve(file, src) or nil
  if s then
    return s
  end
  local dir = vim.fs.dirname(file)
  if src:find("^%.") or (not src:find("^%w%w+://") and src:find("^%w")) then
    src = vim.fs.normalize(dir .. "/" .. src)
  end
  return src
end

---@param buf number
---@param from? number
---@param to? number
function M.find(buf, from, to)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return {}
  end
  parser:parse(from and to and { from, to } or true)
  local ret = {} ---@type {id:string, pos:snacks.image.Pos, src:string}[]
  parser:for_each_tree(function(tstree)
    if not tstree then
      return
    end
    for _, query in ipairs(M.queries()) do
      for _, match in query:iter_matches(tstree:root(), buf, from and from - 1 or nil, to and to - 1 or nil) do
        local src, pos, nid ---@type string, snacks.image.Pos, string
        for id, nodes in pairs(match) do
          local name = query.captures[id]
          for _, node in ipairs(nodes) do
            if name == "image" then
              src = vim.treesitter.get_node_text(node, buf)
              src = M.resolve(buf, src)
            elseif name == "anchor" then
              local range = { node:range() }
              pos = { range[1] + 1, range[2] }
              nid = node:id()
            end
          end
        end
        if src and pos and nid then
          ret[#ret + 1] = { id = nid, pos = pos, src = src }
        end
      end
    end
  end)
  return ret
end

function M.hover_close()
  if hover then
    hover.win:close()
    hover.img:close()
    hover = nil
  end
end

function M.hover()
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_get_current_buf()

  if hover and hover.win.win == current_win and hover.win:valid() then
    return
  end

  if hover and (not hover.win:valid() or hover.buf ~= current_buf or vim.fn.mode() ~= "n") then
    M.hover_close()
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local img = M.find(current_buf, cursor[1], cursor[1] + 1)[1]
  if not img then
    return M.hover_close()
  end

  if hover and hover.img.img.src ~= img.src then
    M.hover_close()
  elseif hover then
    hover.img:update()
    return
  end

  local win = Snacks.win(Snacks.win.resolve(Snacks.image.config.doc, "snacks_image", {
    show = false,
    enter = false,
  }))
  win:open_buf()
  local updated = false
  local o = Snacks.config.merge({}, Snacks.image.config.doc, {
    on_update_pre = function()
      if hover and not updated then
        updated = true
        local loc = hover.img:state().loc
        win.opts.width = loc.width
        win.opts.height = loc.height
        win:show()
      end
    end,
    inline = false,
  })
  hover = {
    win = win,
    buf = current_buf,
    img = Snacks.image.placement.new(win.buf, img.src, o),
  }
end

---@param buf number
function M.inline(buf)
  local imgs = {} ---@type table<string, snacks.image.Placement>
  return function()
    local found = {} ---@type table<string, boolean>
    for _, i in ipairs(M.find(buf)) do
      local img = imgs[i.id]
      if not img then
        img = Snacks.image.placement.new(
          buf,
          i.src,
          Snacks.config.merge({}, Snacks.image.config.doc, {
            pos = i.pos,
            inline = true,
          })
        )
        imgs[i.id] = img
      else
        img:update()
      end
      found[i.id] = true
    end
    for nid, img in pairs(imgs) do
      if not found[nid] then
        img:close()
        imgs[nid] = nil
      end
    end
  end
end

---@param buf number
function M.attach(buf)
  if vim.b[buf].snacks_image_attached then
    return
  end
  vim.b[buf].snacks_image_attached = true
  local inline = Snacks.image.config.doc.inline and Snacks.image.terminal.env().placeholders
  local float = Snacks.image.config.doc.float and not inline

  if not inline and not float then
    return
  end

  local group = vim.api.nvim_create_augroup("snacks.image.markdown." .. buf, { clear = true })

  local update = inline and M.inline(buf) or M.hover

  if inline then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      buffer = buf,
      callback = vim.schedule_wrap(update),
    })
  else
    vim.api.nvim_create_autocmd({ "BufWritePost", "CursorMoved", "ModeChanged", "BufLeave" }, {
      group = group,
      buffer = buf,
      callback = vim.schedule_wrap(update),
    })
  end
  vim.schedule(update)
end

return M
