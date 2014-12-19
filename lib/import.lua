local log = require('./log')
local makeChroot = require('creationix/coro-fs').chroot
local git = require('creationix/git')
local gitFrame = git.frame
local encodeTag = git.encoders.tag
local modes = git.modes
local sign = require('creationix/ssh-rsa').sign
local pathJoin = require('luvi').path.join


return function (config, storage, base, tag, message)
  if not (config.key and config.name and config.email) then
    error("Please run `lit auth` to configure your username")
  end

  local fs = makeChroot(base)

  local function saveAs(type, body)
    return assert(storage:save(gitFrame(type, body)))
  end

  local function importBlob(path)
    log("import blob", path)
    return saveAs("blob", fs.readFile(path))
  end

  local function importLink(path)
    log("import link", path)
    return saveAs("blob", fs.readlink(path))
  end

  local function importTree(path)
    log("import tree", path)
    local items = {}
    fs.scandir(path, function (entry)
      if string.sub(entry.name, 1, 1) == '.' then return end
      local fullPath = pathJoin(path, entry.name)
      local item = { name = entry.name }
      if entry.type == "directory" then
        item.mode = modes.tree
        item.hash = importTree(fullPath)
      elseif entry.type == "file" then
        local stat = fs.stat(fullPath)
        if bit.band(stat.mode, 73) > 0 then
          item.mode = modes.exec
        else
          item.mode = modes.file
        end
        item.hash = importBlob(fullPath)
      elseif entry.type == "link" then
        item.mode = modes.sym
        item.hash = importLink(fullPath)
      else
        p(path, entry)
        error("Unsupported type " .. entry.type)
      end
      items[#items + 1] = item
    end)
    return saveAs("tree", items)
  end


  local hash

  local function import()
    log("import", base)
    local stat = assert(fs.stat('.'))
    local typ
    if stat.type == "directory" then
      hash = importTree('.')
      typ = "tree"
    elseif stat.type == "file" then
      hash = importBlob('.')
      typ = "blob"
    end

    log("signing tag", tag)
    hash = saveAs("tag", sign(encodeTag({
      object = hash,
      type = typ,
      tag = tag,
      tagger = {
        name = config.name,
        email = config.email,
        date = now()
      },
      message = message
    }), config.key))
    storage:write(tag, hash)
  end

  storage:begin()
  local success, err = pcall(import)
  if success then
    storage:commit()
  else
    storage:rollback()
    error(err)
  end

  return tag, hash
end
