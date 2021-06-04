local Sign = require('gitsigns.signs').Sign
local StatusObj = require('gitsigns.status').StatusObj

local record M
  record Hunk
    enum Type
      "add"
      "change"
      "delete"
    end

    type: Type
    head: string
    lines: {string}
    start: integer
    dend: integer
    vend: integer

    record Node
      start: integer
      count: integer
    end

    added: Node
    removed: Node
  end
end

local Hunk = M.Hunk

function M.create_hunk(start_a: integer, count_a: integer, start_b: integer, count_b: integer): Hunk
  local removed = { start = start_a, count = count_a }
  local added   = { start = start_b, count = count_b }

  local hunk: Hunk = {
    start   = added.start,
    lines   = {},
    removed = removed,
    added   = added
  }

  if added.count == 0 then
    -- delete
    hunk.dend = added.start
    hunk.vend = hunk.dend
    hunk.type = "delete"
  elseif removed.count == 0 then
    -- add
    hunk.dend = added.start + added.count - 1
    hunk.vend = hunk.dend
    hunk.type = "add"
  else
    -- change
    hunk.dend = added.start + math.min(added.count, removed.count) - 1
    hunk.vend = hunk.dend + math.max(added.count - removed.count, 0)
    hunk.type = "change"
  end

  return hunk
end

function M.parse_diff_line(line: string): Hunk
  local diffkey = vim.trim(vim.split(line, '@@', true)[2])

  -- diffKey: "-xx,n +yy"
  -- pre: {xx, n}, now: {yy}
  local pre, now = unpack(vim.tbl_map(function(s: string): {string}
    return vim.split(string.sub(s, 2), ',')
  end, vim.split(diffkey, ' ')) as {{string}})

  local hunk = M.create_hunk(
    tonumber(pre[1]) as integer, (tonumber(pre[2]) or 1) as integer,
    tonumber(now[1]) as integer, (tonumber(now[2]) or 1) as integer
  )
  hunk.head = line

  return hunk
end

function M.process_hunks(hunks: {Hunk}): {integer:Sign}
  local signs = {}
  for _, hunk in ipairs(hunks) do
    local count = hunk.type == 'add' and hunk.added.count or hunk.removed.count
    for i = hunk.start, hunk.dend do
      local topdelete = hunk.type == 'delete' and i == 0
      local changedelete = hunk.type == 'change' and hunk.removed.count > hunk.added.count and i == hunk.dend
      -- topdelete signs get placed one row lower
      signs[topdelete and 1 or i] = {
        type = topdelete and 'topdelete' or changedelete and 'changedelete' or hunk.type,
        count = i == hunk.start and count
      }
    end
    if hunk.type == "change" then
      local add, remove = hunk.added.count, hunk.removed.count
      if add > remove then
        local count_diff = add - remove
        for i = 1, count_diff do
          signs[hunk.dend + i] = {
            type = 'add',
            count = i == 1 and count_diff
          }
        end
      end
    end
  end

  return signs
end

function M.create_patch(relpath: string, hunks: {Hunk}, mode_bits: string, invert: boolean): {string}
  invert = invert or false

  local results = {
    string.format('diff --git a/%s b/%s', relpath, relpath),
    'index 000000..000000 '..mode_bits,
    '--- a/'..relpath,
    '+++ b/'..relpath,
  }

  for _, process_hunk in ipairs(hunks) do
    local start, pre_count, now_count =
    process_hunk.removed.start, process_hunk.removed.count, process_hunk.added.count

    if process_hunk.type == 'add' then
      start = start + 1
    end

    local lines = process_hunk.lines

    if invert then
      pre_count, now_count = now_count, pre_count

      lines = vim.tbl_map(function(l: string): string
        if vim.startswith(l, '+') then
          l = '-'..string.sub(l, 2, -1)
        elseif vim.startswith(l, '-') then
          l = '+'..string.sub(l, 2, -1)
        end
        return l
      end, lines) as {string}
    end

    table.insert(results, string.format('@@ -%s,%s +%s,%s @@', start, pre_count, start, now_count))
    for _, line in ipairs(lines) do
      table.insert(results, line)
    end
  end

  return results
end

function M.get_summary(hunks: {Hunk}, head: string): StatusObj
  local status = { added = 0, changed = 0, removed = 0, head = head }

  for _, hunk in ipairs(hunks) do
    if hunk.type == 'add' then
      status.added = status.added + hunk.added.count
    elseif hunk.type == 'delete' then
      status.removed = status.removed + hunk.removed.count
    elseif hunk.type == 'change' then
      local add, remove = hunk.added.count, hunk.removed.count
      local min = math.min(add, remove)
      status.changed = status.changed + min
      status.added   = status.added   + add - min
      status.removed = status.removed + remove - min
    end
  end

  return status
end

function M.find_hunk(lnum: number, hunks: {Hunk}): Hunk
  for _, hunk in ipairs(hunks) do
    if lnum == 1 and hunk.start == 0 and hunk.vend == 0 then
      return hunk
    end

    if hunk.start <= lnum and hunk.vend >= lnum then
      return hunk
    end
  end
end

function M.find_nearest_hunk(lnum: number, hunks: {Hunk}, forwards: boolean, wrap: boolean): Hunk
  local ret: Hunk
  if forwards then
    for i = 1, #hunks do
      local hunk = hunks[i]
      if hunk.start > lnum then
        ret = hunk
        break
      end
    end
  else
    for i = #hunks, 1, -1 do
      local hunk = hunks[i]
      if hunk.vend < lnum then
        ret = hunk
        break
      end
    end
  end
  if not ret and wrap then
    ret = hunks[forwards and 1 or #hunks]
  end
  return ret
end

function M.extract_removed(hunk: Hunk): {string}
  return vim.tbl_map(function(l: string): string
    return string.sub(l, 2, -1)
  end, vim.tbl_filter(function(l: string): boolean
    return vim.startswith(l, '-')
  end, hunk.lines)) as {string}
end

local gap_between_regions = 5

-- get_lcs('hello', 'hheloooo') == 'hel'
local function get_lcs(s1: string, s2: string): string
  if s1 == '' or s2 == '' then
    return ''
  end

  local matrix: {{integer}} = {}
  for i = 1, #s1+1 do
    matrix[i] = {}
    for j = 1, #s2+1 do
      matrix[i][j] = 0
    end
  end

  local maxlength = 0
  local endindex = #s1

  for i = 2, #s1 + 1 do
    for j = 2, #s2 + 1 do
      if s1:sub(i, i) == s2:sub(j, j) then
        matrix[i][j] = 1 + matrix[i-1][j-1]
        if matrix[i][j] > maxlength then
          maxlength = matrix[i][j]
          endindex = i
        end
      end
    end
  end

  return s1:sub(endindex - maxlength + 1, endindex)
end

global Lcs = get_lcs

vim.cmd[[
function! Lcs(s1, s2)
  if empty(a:s1) || empty(a:s2)
    return ''
  endif

  let matrix = map(repeat([repeat([0], len(a:s2)+1)], len(a:s1)+1), 'copy(v:val)')

  let maxlength = 0
  let endindex = len(a:s1)

  for i in range(1, len(a:s1))
    for j in range(1, len(a:s2))
      if a:s1[i-1] ==# a:s2[j-1]
        let matrix[i][j] = 1 + matrix[i-1][j-1]
        if matrix[i][j] > maxlength
          let maxlength = matrix[i][j]
          let endindex = i - 1
        endif
      endif
    endfor
  endfor

  return a:s1[endindex - maxlength + 1 : endindex]
endfunction

]]

-- Returns 0-based index of last character of common prefix
-- If there is no common prefix, returns -1.
--
-- a, b - strings
--
local function common_prefix(a: string, b: string): integer
  local len = math.min(#a, #b)
  if len == 0 then
    return -1
  end
  for i = 0, len do
    if a:sub(i,i) ~= b:sub(i,i) then
      return i - 1
    end
  end
  return len
end

-- Returns 0-based indices of start of common suffix
--
-- a, b - strings
-- start - 0-based index to start from
--
-- common_suffix('', '', 0) ==
local function common_suffix(a: string, b: string, start: integer): integer, integer
  local sa, sb = #a, #b
  while sa >= start and sb >= start do
    if a:sub(sa, sa) == b:sub(sb, sb) then
      sa = sa - 1
      sb = sb - 1
    else
      break
    end
  end
  return sa, sb
end

local type Region = {integer, string, integer, integer}

local function diff(rline: string, aline: string, rlinenr: integer, alinenr: integer, rprefix: integer, aprefix: integer, regions: {Region}, whole_line: boolean)
  print(string.format("diff '%s' '%s' %d %d %d %d", rline, aline, rlinenr, alinenr, rprefix, aprefix))
  -- diff marker does not count as a difference in prefix
  local start = whole_line and 2 or 1
  local prefix = common_prefix(rline:sub(start), aline:sub(start))
  if whole_line then
    prefix = prefix + 1
  end
  local rsuffix, asuffix = common_suffix(rline, aline, prefix+1)

  -- region of change (common prefix and suffix removed)
  local rtext = rline:sub(prefix+1, rsuffix-1)
  local atext = aline:sub(prefix+1, asuffix-1)

  print('rline: '..#rline)
  print('aline: '..#aline)

  print('rsuffix: '..rsuffix)
  print('asuffix: '..asuffix)

  print('rtext: '..rtext)
  print('atext: '..atext)

  -- singular insertion
  if rtext == '' then
    if not whole_line or #atext ~= #aline then -- not whole line
      regions[#regions+1] = {alinenr, '+', aprefix+prefix+1, aprefix+asuffix-1}
      print('regions1 += '..vim.inspect(regions[#regions]))
    end
    print('R1')
    return
  end

  -- singular deletion
  if atext == '' then
    if not whole_line or #rtext ~= #rline then -- not whole line
      regions[#regions+1] = {rlinenr, '-', rprefix+prefix+1, rprefix+rsuffix-1}
      print('regions2 += '..vim.inspect(regions[#regions]))
    end
    print('R2')
    return
  end

  -- two insertions
  local j = vim.fn.stridx(atext, rtext)
  if j ~= -1 then
    regions[#regions+1] = {alinenr, '+', aprefix+prefix+1         , aprefix+prefix+j}
      print('regions3 += '..vim.inspect(regions[#regions]))
    regions[#regions+1] = {alinenr, '+', aprefix+prefix+1+j+#rtext, aprefix+asuffix-1}
      print('regions4 += '..vim.inspect(regions[#regions]))
    print('R3')
    return
  end

  -- two deletions
  local k = vim.fn.stridx(rtext, atext)
  if k ~= -1 then
    regions[#regions+1] = {rlinenr+1, '-', rprefix+prefix         , rprefix+prefix+k}
      print('regions5 += '..vim.inspect(regions[#regions]))
    regions[#regions+1] = {rlinenr+1, '-', rprefix+prefix+k+#atext, rprefix+rsuffix-1}
      print('regions6 += '..vim.inspect(regions[#regions]))
    print('R4')
    return
  end

  -- two edits
  local lcs = get_lcs(rtext, atext)
  print('lcs = '..lcs)
  -- TODO do we need to ensure we don't get more than 2 elements when splitting?
  if #lcs > gap_between_regions then
    local redits = vim.split(rtext, lcs, true)
    local aedits = vim.split(atext, lcs, true)
    print('redits = '..vim.inspect(redits))
    print('aedits = '..vim.inspect(aedits))
    print('diff1')
    diff(redits[1], aedits[1], rlinenr, alinenr, rprefix+prefix+1                , aprefix+prefix+1                , regions, false)
    print('diff2')
    diff(redits[2], aedits[2], rlinenr, alinenr, rprefix+prefix+1+#redits[2]+#lcs, aprefix+prefix+1+#aedits[1]+#lcs, regions, false)
    print('R5')
    return
  end

  -- fall back to highlighting entire changed area

  -- if a change (but not the whole line)
  if not whole_line or ((prefix ~= 0 or rsuffix ~= #rline) and prefix+1 < rsuffix) then
    regions[#regions+1] = {rlinenr, '-', rprefix+prefix, rprefix+rsuffix-1}
      print('regions7 += '..vim.inspect(regions[#regions]))
  end

  -- if a change (but not the whole line)
  if not whole_line or ((prefix ~= 0 or asuffix ~= #aline) and prefix+1 < asuffix) then
    regions[#regions+1] = {alinenr, '+', aprefix+prefix, aprefix+asuffix-1}
      print('regions8 += '..vim.inspect(regions[#regions]))
  end
  print('R6')
end

-- Calculates the changed portions of lines.
--
-- Based on:
--
-- - diff-highlight (included with git)
--   https://github.com/git/git/blob/master/contrib/diff-highlight/DiffHighlight.pm
--
-- - Diff Strategies, Neil Fraser
--   https://neil.fraser.name/writing/diff/
--
--
-- Returns a list of intra-line changed regions.
-- Each element is a list:
--
--   [
--     line number (1-based),
--     type ('+' or '-'),
--     start column (1-based, inclusive),
--     stop column (1-based, inclusive),
--   ]
--
-- Args:
--   hunk_body - list of lines
function M.process(hunk_body: {string}): {Region}
  -- Check whether we have the same number of lines added as removed.
  local removed, added = 0, 0
  for _, line in ipairs(hunk_body) do
    if line:sub(1, 1) == '-' then
      removed = removed + 1
    elseif line:sub(1, 1) == '+' then
      added = added + 1
    end
  end

  if removed ~= added then
    return {}
  end

  local regions = {}

  for i = 1, removed do
    -- pair lines by position
    local rline = hunk_body[i]
    local aline = hunk_body[i + removed]

    print('diff0')
    diff(rline, aline, i, i+removed, 0, 0, regions, true)
  end

  return regions
end

return M
