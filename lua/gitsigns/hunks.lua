local Sign = require('gitsigns.signs').Sign
local StatusObj = require('gitsigns.status').StatusObj

local M = {Hunk = {Node = {}, }, }
























local Hunk = M.Hunk

function M.create_hunk(start_a, count_a, start_b, count_b)
   local removed = { start = start_a, count = count_a }
   local added = { start = start_b, count = count_b }

   local hunk = {
      start = added.start,
      lines = {},
      removed = removed,
      added = added,
   }

   if added.count == 0 then

      hunk.dend = added.start
      hunk.vend = hunk.dend
      hunk.type = "delete"
   elseif removed.count == 0 then

      hunk.dend = added.start + added.count - 1
      hunk.vend = hunk.dend
      hunk.type = "add"
   else

      hunk.dend = added.start + math.min(added.count, removed.count) - 1
      hunk.vend = hunk.dend + math.max(added.count - removed.count, 0)
      hunk.type = "change"
   end

   return hunk
end

function M.parse_diff_line(line)
   local diffkey = vim.trim(vim.split(line, '@@', true)[2])



   local pre, now = unpack(vim.tbl_map(function(s)
      return vim.split(string.sub(s, 2), ',')
   end, vim.split(diffkey, ' ')))

   local hunk = M.create_hunk(
   tonumber(pre[1]), (tonumber(pre[2]) or 1),
   tonumber(now[1]), (tonumber(now[2]) or 1))

   hunk.head = line

   return hunk
end

function M.process_hunks(hunks)
   local signs = {}
   for _, hunk in ipairs(hunks) do
      local count = hunk.type == 'add' and hunk.added.count or hunk.removed.count
      for i = hunk.start, hunk.dend do
         local topdelete = hunk.type == 'delete' and i == 0
         local changedelete = hunk.type == 'change' and hunk.removed.count > hunk.added.count and i == hunk.dend

         signs[topdelete and 1 or i] = {
            type = topdelete and 'topdelete' or changedelete and 'changedelete' or hunk.type,
            count = i == hunk.start and count,
         }
      end
      if hunk.type == "change" then
         local add, remove = hunk.added.count, hunk.removed.count
         if add > remove then
            local count_diff = add - remove
            for i = 1, count_diff do
               signs[hunk.dend + i] = {
                  type = 'add',
                  count = i == 1 and count_diff,
               }
            end
         end
      end
   end

   return signs
end

function M.create_patch(relpath, hunks, mode_bits, invert)
   invert = invert or false

   local results = {
      string.format('diff --git a/%s b/%s', relpath, relpath),
      'index 000000..000000 ' .. mode_bits,
      '--- a/' .. relpath,
      '+++ b/' .. relpath,
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

         lines = vim.tbl_map(function(l)
            if vim.startswith(l, '+') then
               l = '-' .. string.sub(l, 2, -1)
            elseif vim.startswith(l, '-') then
               l = '+' .. string.sub(l, 2, -1)
            end
            return l
         end, lines)
      end

      table.insert(results, string.format('@@ -%s,%s +%s,%s @@', start, pre_count, start, now_count))
      for _, line in ipairs(lines) do
         table.insert(results, line)
      end
   end

   return results
end

function M.get_summary(hunks, head)
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
         status.added = status.added + add - min
         status.removed = status.removed + remove - min
      end
   end

   return status
end

function M.find_hunk(lnum, hunks)
   for _, hunk in ipairs(hunks) do
      if lnum == 1 and hunk.start == 0 and hunk.vend == 0 then
         return hunk
      end

      if hunk.start <= lnum and hunk.vend >= lnum then
         return hunk
      end
   end
end

function M.find_nearest_hunk(lnum, hunks, forwards, wrap)
   local ret
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

function M.extract_removed(hunk)
   return vim.tbl_map(function(l)
      return string.sub(l, 2, -1)
   end, vim.tbl_filter(function(l)
      return vim.startswith(l, '-')
   end, hunk.lines))
end

local gap_between_regions = 5


local function get_lcs(s1, s2)
   if s1 == '' or s2 == '' then
      return ''
   end

   local matrix = {}
   for i = 1, #s1 + 1 do
      matrix[i] = {}
      for j = 1, #s2 + 1 do
         matrix[i][j] = 0
      end
   end

   local maxlength = 0
   local endindex = #s1

   for i = 2, #s1 + 1 do
      for j = 2, #s2 + 1 do
         if s1:sub(i, i) == s2:sub(j, j) then
            matrix[i][j] = 1 + matrix[i - 1][j - 1]
            if matrix[i][j] > maxlength then
               maxlength = matrix[i][j]
               endindex = i
            end
         end
      end
   end

   return s1:sub(endindex - maxlength + 1, endindex)
end

Lcs = get_lcs

vim.cmd([[
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

]])






local function common_prefix(a, b)
   local len = math.min(#a, #b)
   if len == 0 then
      return -1
   end
   for i = 0, len do
      if a:sub(i, i) ~= b:sub(i, i) then
         return i - 1
      end
   end
   return len
end







local function common_suffix(a, b, start)
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

local Region = {}

local function diff(rline, aline, rlinenr, alinenr, rprefix, aprefix, regions, whole_line)
   print(string.format("diff '%s' '%s' %d %d %d %d", rline, aline, rlinenr, alinenr, rprefix, aprefix))

   local start = whole_line and 2 or 1
   local prefix = common_prefix(rline:sub(start), aline:sub(start))
   if whole_line then
      prefix = prefix + 1
   end
   local rsuffix, asuffix = common_suffix(rline, aline, prefix + 1)


   local rtext = rline:sub(prefix + 1, rsuffix - 1)
   local atext = aline:sub(prefix + 1, asuffix - 1)

   print('rline: ' .. #rline)
   print('aline: ' .. #aline)

   print('rsuffix: ' .. rsuffix)
   print('asuffix: ' .. asuffix)

   print('rtext: ' .. rtext)
   print('atext: ' .. atext)


   if rtext == '' then
      if not whole_line or #atext ~= #aline then
         regions[#regions + 1] = { alinenr, '+', aprefix + prefix + 1, aprefix + asuffix - 1 }
         print('regions1 += ' .. vim.inspect(regions[#regions]))
      end
      print('R1')
      return
   end


   if atext == '' then
      if not whole_line or #rtext ~= #rline then
         regions[#regions + 1] = { rlinenr, '-', rprefix + prefix + 1, rprefix + rsuffix - 1 }
         print('regions2 += ' .. vim.inspect(regions[#regions]))
      end
      print('R2')
      return
   end


   local j = vim.fn.stridx(atext, rtext)
   if j ~= -1 then
      regions[#regions + 1] = { alinenr, '+', aprefix + prefix + 1, aprefix + prefix + j }
      print('regions3 += ' .. vim.inspect(regions[#regions]))
      regions[#regions + 1] = { alinenr, '+', aprefix + prefix + 1 + j + #rtext, aprefix + asuffix - 1 }
      print('regions4 += ' .. vim.inspect(regions[#regions]))
      print('R3')
      return
   end


   local k = vim.fn.stridx(rtext, atext)
   if k ~= -1 then
      regions[#regions + 1] = { rlinenr + 1, '-', rprefix + prefix, rprefix + prefix + k }
      print('regions5 += ' .. vim.inspect(regions[#regions]))
      regions[#regions + 1] = { rlinenr + 1, '-', rprefix + prefix + k + #atext, rprefix + rsuffix - 1 }
      print('regions6 += ' .. vim.inspect(regions[#regions]))
      print('R4')
      return
   end


   local lcs = get_lcs(rtext, atext)
   print('lcs = ' .. lcs)

   if #lcs > gap_between_regions then
      local redits = vim.split(rtext, lcs, true)
      local aedits = vim.split(atext, lcs, true)
      print('redits = ' .. vim.inspect(redits))
      print('aedits = ' .. vim.inspect(aedits))
      print('diff1')
      diff(redits[1], aedits[1], rlinenr, alinenr, rprefix + prefix + 1, aprefix + prefix + 1, regions, false)
      print('diff2')
      diff(redits[2], aedits[2], rlinenr, alinenr, rprefix + prefix + 1 + #redits[2] + #lcs, aprefix + prefix + 1 + #aedits[1] + #lcs, regions, false)
      print('R5')
      return
   end




   if not whole_line or ((prefix ~= 0 or rsuffix ~= #rline) and prefix + 1 < rsuffix) then
      regions[#regions + 1] = { rlinenr, '-', rprefix + prefix, rprefix + rsuffix - 1 }
      print('regions7 += ' .. vim.inspect(regions[#regions]))
   end


   if not whole_line or ((prefix ~= 0 or asuffix ~= #aline) and prefix + 1 < asuffix) then
      regions[#regions + 1] = { alinenr, '+', aprefix + prefix, aprefix + asuffix - 1 }
      print('regions8 += ' .. vim.inspect(regions[#regions]))
   end
   print('R6')
end
























function M.process(hunk_body)

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

      local rline = hunk_body[i]
      local aline = hunk_body[i + removed]

      print('diff0')
      diff(rline, aline, i, i + removed, 0, 0, regions, true)
   end

   return regions
end

return M
