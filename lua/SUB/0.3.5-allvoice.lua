-- SUB 0.3.5-allvoice -- 0.3.5 와 같은데 **모든 음성**에서 돌고, SKIP 을 센다
--
-- 왜
-- --
-- 0.3.5 는 SUB_ALLOCATOR_TARGET_END = 0x6800 이라 그 음성 하나에서만 붙는다.
-- 케이브 문지기가 음성 하나만 통과시키던 때에 맞춘 값이다.
--
-- allvoice BIOS(Syscard3_galmuri_0.4.6.10_allvoice.pce)를 끼우면 모든 음성이
-- 자막을 띄우므로 allocator 도 모든 음성에서 돌아야 짝이 맞는다.
-- 본체의 필터가 이렇게 생겨서, nil 이면 통째로 빠진다:
--
--     if TARGET_END and endAddr ~= TARGET_END then return end
--
-- 무엇을 재나
-- -----------
-- 이번 주행의 목적은 하나다 -- **자리를 못 찾는 장면이 있는가.**
--
--     SKIP 0        allocator 를 그대로 네이티브로 옮겨도 된다
--     SKIP 잦음     탐색 범위($6000-$7B00 · 0x100 간격)부터 넓혀야 한다
--
-- 그래서 emu.log 를 가로채 파일로도 남기고, 화면에 누적 숫자를 띄운다.
-- 로그창을 안 보고 있어도 SKIP 이 나면 화면에서 바로 보인다.

local OUT = 'C:/snatcher/snatcher_tool/logs/allocator_skip_log.tsv'

local armed, frag, skip = 0, 0, 0

-- 로그 파일: 이어 쓴다.  주행을 나눠 해도 누적된다.
local f = io.open(OUT, 'a')
if f and f:seek('end') == 0 then
  f:write('time\tkind\tline\n')
end

local realLog = emu.log

-- 본체는 emu.log 로만 말한다.  여기서 가로채면 본체를 한 줄도 안 고쳐도 된다.
emu.log = function(msg)
  realLog(msg)
  local kind = 'info'
  if msg:find('SKIP') then
    kind = 'skip'; skip = skip + 1
  elseif msg:find('armed') then
    kind = 'armed'; armed = armed + 1
  elseif msg:find('selected') then
    kind = 'frag'; frag = frag + 1
  end
  if f then
    f:write(string.format('%s\t%s\t%s\n', os.date('%H:%M:%S'), kind, msg))
    f:flush()
  end
end

SUB_ALLOCATOR_VERSION = '0.3.5-allvoice'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = nil            -- ★ 0.3.5 와 다른 곳은 여기뿐이다
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = true
dofile('C:/snatcher/lua/POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR_0_3_1.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = nil

-- 화면 표시.  SKIP 이 0 이면 조용하고, 하나라도 나면 눈에 띄게 남긴다.
emu.addEventCallback(function()
  emu.drawString(4, 4, string.format('음성 %d  조각 %d', armed, frag), 0xFFFFFF, 0x000000)
  if skip > 0 then
    emu.drawString(4, 14, string.format('SKIP %d  <- 자리 못 찾음', skip),
                   0xFF4040, 0x000000)
  end
end, emu.eventType.startFrame)

realLog('SUB 0.3.5-allvoice -- 모든 음성에서 돈다 · SKIP 을 센다')
realLog('  로그 ' .. OUT)
