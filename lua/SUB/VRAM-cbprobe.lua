-- SUB 0.4.54-cbprobe -- write 콜백이 어떤 등록 형태에서 실제로 뜨는지 잰다
--
-- 0.4.53 실행에서 ctrl:0 ★DEAD 가 나왔다.  매 프레임 반드시 써지는 SATB
-- 테이블($1000-$10FF word)에도 write 콜백이 한 번도 안 떴다는 뜻이다.
-- 같은 등록 방식을 쓰는 0.4.26 의 "147,247 프레임 write 0 -> SUMMARY_PASS" 도
-- 따라서 근거가 되지 못한다.  둘 다 계측기가 죽은 채 0 을 찍었을 수 있다.
--
-- 이 스크립트는 후보를 고르지 않는다.  **어떤 등록 형태가 살아 있는지만** 잰다.
-- 읽기 전용이고, 아무것도 쓰지 않는다.
--
-- 재는 것:
--
--   V1  VRAM · cpuType=nil        <- 0.4.26 / 0.4.53 이 쓴 형태
--   V2  VRAM · cpuType=pce
--   V3  VRAM · 4 인자 (cpu/mem 생략)
--   V4  pceMemory zero page · cpuType=pce      <- 양성 대조.  이게 0 이면
--                                                 콜백 기구 자체가 죽은 것
--   V5  VDC 데이터 포트 write (CPU 버스)       <- VRAM 이 실제로 써지는 경로
--
-- V4 가 뜨고 V1~V3 가 안 뜨면: Mesen 이 pceVideoRam 에 write 콜백을 주지
-- 않는다는 뜻이다.  그러면 VRAM 감시는 VDC 포트를 훅해서 MAWR 로 주소를
-- 재구성하는 방식으로 다시 짜야 한다 (V5 가 그 가능성을 본다).
--
-- 켜고 아무 장면이나 5~10 초 두었다가 Stop.  콘솔과 화면에 결과가 뜬다.

local VRAM = emu.memType.pceVideoRam
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_54_cbprobe_' .. stamp .. '.tsv'

local hits = { V1 = 0, V2 = 0, V3 = 0, V4 = 0, V5 = 0 }
local installed = {}
local frame, closed = 0, false

-- 매 프레임 반드시 써지는 VRAM 범위: SATB 테이블.
local SATB_LO, SATB_HI = 0x1000 * 2, 0x10FF * 2 + 1

local function try(name, fn)
  local ok, err = pcall(fn)
  installed[name] = ok and 'ok' or ('ERR:' .. tostring(err))
  return ok
end

try('V1', function()
  emu.addMemoryCallback(function() hits.V1 = hits.V1 + 1 end,
    emu.callbackType.write, SATB_LO, SATB_HI, nil, VRAM)
end)

try('V2', function()
  emu.addMemoryCallback(function() hits.V2 = hits.V2 + 1 end,
    emu.callbackType.write, SATB_LO, SATB_HI, CPU, VRAM)
end)

try('V3', function()
  emu.addMemoryCallback(function() hits.V3 = hits.V3 + 1 end,
    emu.callbackType.write, SATB_LO, SATB_HI)
end)

-- 양성 대조.  zero page 는 게임이 쉬지 않고 쓴다.  여기가 0 이면 콜백 기구
-- 자체가 죽은 것이고, 위 결과는 아무 의미가 없다.
try('V4', function()
  emu.addMemoryCallback(function() hits.V4 = hits.V4 + 1 end,
    emu.callbackType.write, 0x0000, 0x00FF, CPU, MEM)
end)

-- VDC 는 CPU 버스의 I/O 페이지에 있다.  MPR 로 뱅크 $FF 가 매핑된 자리에
-- 보이므로 CPU 주소는 실행 시점에 따라 다르다.  넓게 걸어 두고 뜨는지만 본다.
try('V5', function()
  emu.addMemoryCallback(function() hits.V5 = hits.V5 + 1 end,
    emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)
end)

-- 이 빌드가 어떤 memType 을 아는지도 같이 남긴다.
local memNames = {}
for k in pairs(emu.memType) do memNames[#memNames + 1] = tostring(k) end
table.sort(memNames)

emu.addEventCallback(function()
  frame = frame + 1
  local function line(y, name, note)
    local n = hits[name]
    emu.drawString(4, y, string.format('%s %-8d %s', name, n, note),
                   n > 0 and 0x40FF40 or 0xFF6060, 0x000000)
  end
  emu.drawString(4, 4, string.format('0.4.54 cbprobe  f=%d', frame),
                 0xFFFFFF, 0x000000)
  line(14, 'V1', 'VRAM cpu=nil  (0.4.26/46 방식)')
  line(24, 'V2', 'VRAM cpu=pce')
  line(34, 'V3', 'VRAM 4-arg')
  line(44, 'V4', 'zeropage  <- 양성 대조')
  line(54, 'V5', 'CPU $0000-03FF (VDC 포트 가능성)')
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true
  local f = io.open(OUT, 'w')
  if f then
    f:write('variant\tinstalled\thits\tframes\tnote\n')
    local notes = {
      V1 = 'VRAM cpuType=nil (0.4.26/0.4.53 이 쓴 형태)',
      V2 = 'VRAM cpuType=pce',
      V3 = 'VRAM 4-arg',
      V4 = 'pceMemory zeropage (양성 대조)',
      V5 = 'pceMemory $0000-$03FF (VDC 포트 가능성)',
    }
    for _, k in ipairs({ 'V1', 'V2', 'V3', 'V4', 'V5' }) do
      f:write(string.format('%s\t%s\t%d\t%d\t%s\n',
        k, installed[k] or 'n/a', hits[k], frame, notes[k]))
    end
    f:write('memtypes\t\t0\t0\t' .. table.concat(memNames, ',') .. '\n')
    f:close()
  end

  emu.log('SUB 0.4.54-cbprobe 결과 (frames=' .. frame .. ')')
  for _, k in ipairs({ 'V1', 'V2', 'V3', 'V4', 'V5' }) do
    emu.log(string.format('  %s  install=%-6s hits=%d', k, installed[k] or 'n/a', hits[k]))
  end
  if hits.V4 == 0 then
    emu.log('  ★ 양성 대조(V4)가 0 이다.  콜백 기구 자체가 안 돈다.')
    emu.log('    등록 인자 문제가 아니라 더 앞단이다.  V1~V3 결과는 볼 필요 없다.')
  elseif hits.V1 == 0 and hits.V2 == 0 and hits.V3 == 0 then
    emu.log('  ★ 콜백은 도는데(V4>0) VRAM 만 전부 0 이다.')
    emu.log('    -> Mesen 이 pceVideoRam 에 write 콜백을 주지 않는다.')
    emu.log('    -> 0.4.26 의 SUMMARY_PASS 는 무효.  VRAM 감시를 다시 짜야 한다.')
  else
    emu.log('  살아 있는 VRAM 등록 형태가 있다.  그 형태로 0.4.53 을 고치면 된다.')
  end
  emu.log('SUB 0.4.54 saved: ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.54-cbprobe loaded -- 읽기 전용 · 5~10 초 두었다가 Stop')
for _, k in ipairs({ 'V1', 'V2', 'V3', 'V4', 'V5' }) do
  emu.log(string.format('  %s install=%s', k, installed[k] or 'n/a'))
end
emu.log('  memType: ' .. table.concat(memNames, ', '))
emu.log('  output: ' .. OUT)
