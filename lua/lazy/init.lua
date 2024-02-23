---@class Lazy: LazyCommands
local M = {}
M._start = 0

-- 在这里对全局的require函数进行了重载。
-- 因此，在调用require函数来加载模块时，如果是初次调用，则会对模块进行分析。但是我不知道分析结果在哪里保存，估计是在track()函数实现的模块中吧？？
-- 如果之前已经加载过，则使用原始的require()来加载模块
local function profile_require()
  -- done用于记录已经被分析过的模块，避免重复分析
  local done = {} ---@type table<string, true>

  -- r变量用来存放原始的require函数，以便在分析结束后回复正常的require行为
  local r = require

  -- 将全局的require函数重载
  _G.require = function(modname)
    -- package.loaded是一个记录已加载模块的表。当我们加载一个模块的时候，Lua会检查package.loaded表中是否已经存在该模块，如果存在，则直接返回对应的模块表；如果不存在，则进行模块加载，并将其对应的模块表存储到package.loaded表中以供下次使用。
    -- Util用于记录"lazy.core.util"模块表
    local Util = package.loaded["lazy.core.util"]
    if Util and not done[modname] then
      -- 如果"lazy.core.util"模块被加载，但是未被分析过,则进入到这里

      done[modname] = true

      -- 记录模块加载开始
      Util.track({ require = modname })
      local ok, ret = pcall(function()
        -- 使用pcall安全地调用原始的require函数，并将结果存储在ret变量中
        -- 获取指定模块的已打包大小。其中，modname为要查询的模块名称
        return vim.F.pack_len(r(modname))
      end)
      -- 记录模块加载结束
      Util.track()

      if not ok then
        error(ret, 2)
      end

      -- 将vim.F.pack_len()函数返回的模块已打包大小转换为可读的字符串形式
      return vim.F.unpack_len(ret)
    else
      -- 如果指定modname已经被分析过，则直接使用require函数加载就可以
      return r(modname)
    end
  end
end

---@overload fun(opts: LazyConfig)
---@overload fun(spec:LazySpec, opts: LazyConfig)
-- [[
-- M.setup(): lazy.nvim的初始化函数
-- ]]
function M.setup(spec, opts)
  -- 如果形参spec是一个表，且有一个spec.spec的属性，则opts=spec
  -- 否则，opts表中追加一个opts.spec属性，值为spec
  if type(spec) == "table" and spec.spec then
    ---@cast spec LazyConfig
    opts = spec
  else
    opts = opts or {}
    opts.spec = spec
  end

  -- M._start是一个全局变量，用于记录lazy.nvim插件管理器的启动的时间
  -- vim.loop.hrtime()用于提供高分辨率的时间戳
  M._start = M._start == 0 and vim.loop.hrtime() or M._start

  -- vim.g.lazy_did_setup是一个全局变量，用于知识lazy.nvim插件管理器是否已经完成初始化。0: 未初始化；1：已初始化。
  -- 如果vim.g.lazy_did_setup为真，则说明之前已经加载过了，此时应该弹出警告信息
  if vim.g.lazy_did_setup then
    -- vim.notify(msg, level, opts)是一个Neovim内置的API接口，用于显示通知消息。
    -- 其中，
    --   msg: 待显示的文本
    --   level: 消息的级别
    --     vim.log.levels.INFO : 普通信息
    --     vim.log.levels.WARN : 警告信息
    --     vim.log.levels.ERROR : 错误信息
    --   opts： 可选参数表，可以包含以下键值对：
    --     title: 消息标题
    --     icon: 消息图标
    --     timeout: 消息超时时间
    --
    -- 这里，是有报一个警告信息
    return vim.notify(
      "Re-sourcing your config is not supported with lazy.nvim",
      vim.log.levels.WARN,
      { title = "lazy.nvim" }
    )
  end

  -- 记录lazy.nvim已经完成初始化
  vim.g.lazy_did_setup = true

  -- vim.go.loadplugins是一个Lua函数，用于加载和管理Go语言插件。它提供了更加便捷和高效的方式来使用Go语言插件，并与lazy.nvim的配置和命令进行整合。
  -- 如果该函数不存在，则说明不支持Go，则直接返回，不往下执行。以免发生错误
  if not vim.go.loadplugins then
    return
  end

  -- 如果nvim的版本低于0.8.0，则报错，返回
  if vim.fn.has("nvim-0.8.0") ~= 1 then
    return vim.notify("lazy.nvim requires Neovim >= 0.8.0", vim.log.levels.ERROR, { title = "lazy.nvim" })
  end

  -- lazy.nvim需要使用LuaJIT编译的Neovim。如果不是，则报错返回
  if not (pcall(require, "ffi") and jit and jit.version) then
    return vim.notify("lazy.nvim requires Neovim built with LuaJIT", vim.log.levels.ERROR, { title = "lazy.nvim" })
  end

  local start = vim.loop.hrtime()

  -- use the Neovim cache if available
  -- vim.loader是nvim在0.9.1+版本中引入的。如果有，lazy.nvim插件的缓存功能(lazy.core.cache)直接使用vim.loader
  if vim.loader and vim.fn.has("nvim-0.9.1") == 1 then
    package.loaded["lazy.core.cache"] = vim.loader
  end

  -- 加载lazy.nvim核心模块中的cache功能，用Cache变量引用
  local Cache = require("lazy.core.cache")

  -- 这段用于读取lazy.nvim插件的配置，并根据配置启动或禁用缓存功能。只有在缓存功能启动的情况下，才会调用Cache.enable()来启动缓存。
  -- 从opts表中分别去performance,cache,enabled的值,它们都不能为false
  -- enable_cache为真，表示缓存功能启动。
  local enable_cache = vim.tbl_get(opts, "performance", "cache", "enabled") ~= false
  -- load module cache before anything else
  if enable_cache then
    Cache.enable()
  end

  -- 检查配置项opts中是否使能了对模块加载的性能分析。如果使能，则开启性能分析功能。即，调用profile_require()。
  if vim.tbl_get(opts, "profiling", "require") then
    profile_require()
  end

  -- LazyStart键用于跟踪lazy.nvim初始化过程的开始时间
  require("lazy.stats").track("LazyStart")

  -- 加载lazy.core.util模块，提供各种实用工具函数
  local Util = require("lazy.core.util")

  -- 加载lazy.core.config模块，负责处理插件配置
  local Config = require("lazy.core.config")

  -- 加载lazy.core.loader模块，负责加载插件
  local Loader = require("lazy.core.loader")

  -- package.loaders表中的第3个位置插入Loader.loader
  table.insert(package.loaders, 3, Loader.loader)

  -- 检查用户是否在配置中启用了加载器分析
  -- 检查vim.loader功能是否可用，只有在0.9.1+版本中可用。
  -- 如果可用，则vim.loader._profile({ loaders = true })
  -- 否则，Cache._profile_loaders()
  if vim.tbl_get(opts, "profiling", "loader") then
    if vim.loader then
      -- 0.9.1+使用vim.loader的分析功能
      vim.loader._profile({ loaders = true })
    else
      -- 旧版本使用这个备用的分析机制
      Cache._profile_loaders()
    end
  end

  -- 跟踪lazy.nvim插件设置的开始
  Util.track({ plugin = "lazy.nvim" }) -- setup start

  -- 测量加载核心模块所需的时间
  Util.track("module", vim.loop.hrtime() - start)

  -- load config
  -- 跟踪配置加载的开始
  Util.track("config")

  -- 根据opts表初始化插件配置
  Config.setup(opts)

  -- 跟踪配置加载的结束
  Util.track()

  -- setup loader and handlers
  -- 设定自定义加载器和任何插件管理事件处理程序
  Loader.setup()

  -- correct time delta and loaded
  -- 计算并跟踪时间差
  local delta = vim.loop.hrtime() - start
  Util.track().time = delta -- end setup
  -- 更新lazy.nvim插件信息
  -- 加载时间设置为delta
  -- 插件来源设置为init.lua
  if Config.plugins["lazy.nvim"] then
    Config.plugins["lazy.nvim"]._.loaded = { time = delta, source = "init.lua" }
  end

  -- load plugins with lazy=false or Plugin.init
  -- 开始加载lazy=false标记的插件和具有Plugin.init()的插件
  -- lazy=false: 这种标记的插件会在启动的时候立即被加载，而不是按需加载
  -- Plugin.init(): 插件中包含这个函数时，会在加载的时候自动执行
  Loader.startup()

  -- all done!
  -- 执行功能所有用户定义的以"LazyDone"为模式的自动命令，但不包括模式行中的自动命令。
  vim.api.nvim_exec_autocmds("User", { pattern = "LazyDone", modeline = false })
  -- 记录一个LazyDone的性能指标
  require("lazy.stats").track("LazyDone")
end

function M.stats()
  return require("lazy.stats").stats()
end

function M.bootstrap()
  local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
  if not vim.loop.fs_stat(lazypath) then
    vim.fn.system({
      "git",
      "clone",
      "--filter=blob:none",
      "https://github.com/folke/lazy.nvim.git",
      "--branch=stable", -- latest stable release
      lazypath,
    })
  end
  vim.opt.rtp:prepend(lazypath)
end

---@return LazyPlugin[]
function M.plugins()
  return vim.tbl_values(require("lazy.core.config").plugins)
end

setmetatable(M, {
  __index = function(_, key)
    return function(...)
      return require("lazy.view.commands").commands[key](...)
    end
  end,
})

return M
