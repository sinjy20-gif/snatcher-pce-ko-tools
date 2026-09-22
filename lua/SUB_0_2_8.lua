-- SUB 0.2.8 -- first AC preload lifecycle + reception UI order (read-only).
-- Load before pressing Start.  Run either no-skip or skip to the reception
-- action UI, then Stop.  This script writes only its TSV log.
local MEM, CPU, AC = emu.memType.pceMemory, emu.memType.cpu, emu.memType.pceArcadeCardRam
local OUT = string.format('C:/snatcher/dump/sub_0_2_8_preload_order_%s.tsv', os.date('%Y%m%d_%H%M%S'))
local f = assert(io.open(OUT, 'w'))
local frame, seq, pending = 0, 0, {}
local HELPER = { [0xBD13] = 'INIT_START', [0xBD40] = 'INIT_OK',
                 [0xBDB9] = 'PACK_LOAD', [0xBDFF] = 'PACK_READY',
                 -- The helper cave is $BCxx through the $A000 window, but the
                 -- title spawn maps bank $69 at $6000.  Both are the same code.
                 [0xBCEF] = 'TITLE_CACHE_WIPE_A000',
                 [0x7CEF] = 'TITLE_CACHE_WIPE_6000',
                 [0xBE0E] = 'COPY_RECORD' }

local function r(at, kind) return emu.read(at, kind) or 0 end
local function hex(at, n, kind)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', r(at + i, kind)) end
  return table.concat(t, ' ')
end
local function src(at)
  local t = {}
  for i = 0, 31 do
    local b = r(at + i, MEM); t[#t + 1] = string.format('%02X', b)
    if b == 0xFF then break end
  end
  return table.concat(t, ' ')
end
local function queue(event, detail)
  pending[#pending + 1] = { event = event, detail = detail or '' }
end
local function titleDetail()
  -- title_cache_wipe begins with LDY #$0A / LDA ($FA),Y / CMP #$95.
  -- Record exactly the byte used by that branch; no state is changed.
  local base = r(0x00FA, MEM) | (r(0x00FB, MEM) << 8)
  return string.format('spawn=%04X sig=%02X code=%s', base,
    r(base + 0x0A, MEM), hex(0x7CEF, 16, CPU))
end
local function flush(item)
  seq = seq + 1
  -- AC $10000 is the helper state page: magic + pack loaded flags.
  f:write(string.format('%d\t%d\t%s\t%s\t%s\t%s\t%s\n', frame, seq,
    item.event, item.detail, hex(0x10000, 12, AC), hex(0x5B80, 16, MEM),
    hex(0x7FEC, 19, MEM)))
  f:flush()
  emu.log(string.format('SUB 0.2.8 %s %s', item.event, item.detail))
end

f:write('frame\tseq\tevent\tdetail\tac_state_10000\tcache_5b80\tprivate_7fec\n')
for address, name in pairs(HELPER) do
  emu.addMemoryCallback(function()
    queue(name, (name == 'TITLE_CACHE_WIPE_A000' or name == 'TITLE_CACHE_WIPE_6000')
      and titleDetail() or '')
  end, emu.callbackType.exec,
    address, address, emu.cpuType.pce, CPU)
end
emu.addMemoryCallback(function()
  local ptr = r(0x3471, MEM) | (r(0x3472, MEM) << 8)
  if ptr == 0x3499 or ptr == 0x349A then
    queue('RECEPTION_UI', string.format('ptr=%04X src=%s', ptr, src(ptr)))
  end
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)
emu.addEventCallback(function()
  frame = frame + 1
  for _, item in ipairs(pending) do flush(item) end
  pending = {}
end, emu.eventType.endFrame)
emu.addEventCallback(function() f:close() end, emu.eventType.scriptEnded)

emu.log('SUB 0.2.8 loaded -- AC preload / title wipe / reception UI order, read-only')
emu.log('  output: ' .. OUT)
emu.log('  Start부터 켜 둔 채 노스킵 또는 스킵으로 접수처 액션 UI를 연 뒤 Stop')
