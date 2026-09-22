-- SUB 0.3.5-allvoice-guard -- allvoice + **고른 뒤 누가 그 자리를 가져가는지** 감시
--
-- 왜
-- --
-- allocator 가 SKIP 0 인데도 초상화 아래가 깨진다.  자리를 못 찾은 게 아니라
-- **고른 뒤에 게임이 그 자리를 가져간** 것으로 보인다.
--
--     고를 때(count_ok)   그 순간 참조 안 되는 블록을 고른다
--     그 뒤              게임이 초상화 스프라이트를 올리며 같은 자리를 쓴다
--     → allocator 는 미래를 모른다
--
-- 이 판은 자막이 떠 있는 **동안 매 프레임** SATB 를 훑어, 우리 블록
-- (base ~ base+0x4BF)을 가리키는 슬롯이 생기는지 본다.  생기면 그 순간을
-- 한 번만 기록한다 -- 그게 증거다.
--
-- 읽는 법
-- -------
--     INTRUDER  슬롯 N  패턴 $XXXX      게임이 우리 자리를 가리켰다  ★ 시점 문제 확정
--     (아무것도 안 나옴)                 다른 원인.  BAT 나 팔레트 쪽을 봐야 한다
--
-- 로그는 0.3.5-allvoice 와 같은 파일에 쌓인다.

local OUT = 'C:/snatcher/snatcher_tool/logs/allocator_skip_log.tsv'
local N = 19 * 0x40                       -- 한 조각 1,216 word

local armed, frag, skip, intrude = 0, 0, 0, 0
local curBase, reported = nil, {}

local f = io.open(OUT, 'a')
if f and f:seek('end') == 0 then f:write('time\tkind\tline\n') end

local realLog = emu.log
local function put(kind, msg)
  realLog(msg)
  if f then
    f:write(string.format('%s\t%s\t%s\n', os.date('%H:%M:%S'), kind, msg))
    f:flush()
  end
end

emu.log = function(msg)
  local kind = 'info'
  if msg:find('SKIP') then kind, skip = 'skip', skip + 1
  elseif msg:find('armed') then kind, armed = 'armed', armed + 1
  elseif msg:find('selected') then
    kind, frag = 'frag', frag + 1
    local hex = msg:match('%$(%x%x%x%x)')
    if hex then curBase, reported = tonumber(hex, 16), {} end
  end
  put(kind, msg)
end

SUB_ALLOCATOR_VERSION = '0.3.5-allvoice-guard'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = true
dofile('C:/snatcher/lua/POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR_0_3_1.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = nil

local VRAM = emu.memType.pceVideoRam

-- ⚠ Mesen 의 pceVideoRam 은 **바이트 주소**다 (08-26 에 한 번 당했다).
-- SATB 는 바이트 $2000 · 항목 8 B · 패턴은 +4.  패턴 -> 워드는 pattern << 5.
local function rb(at) return emu.read(at, VRAM) or 0 end

emu.addEventCallback(function()
  emu.drawString(4, 4, string.format('음성 %d  조각 %d', armed, frag), 0xFFFFFF, 0x000000)
  if skip > 0 then
    emu.drawString(4, 14, string.format('SKIP %d', skip), 0xFF4040, 0x000000)
  end
  if intrude > 0 then
    emu.drawString(4, 24, string.format('침범 %d  <- 남이 우리 자리를 씀', intrude),
                   0xFFA000, 0x000000)
  end
  if not curBase then return end

  for slot = 0, 63 do
    local at = 0x2000 + slot * 8
    local pattern = rb(at + 4) | (rb(at + 5) << 8)
    local attr = rb(at + 6) | (rb(at + 7) << 8)
    local first = (pattern & 0x07FF) << 5
    if (attr & 0x0F) ~= 0x0F then          -- 팔레트 F 는 우리 자막이다.  제외
      local width = ((attr & 0x0100) ~= 0) and 2 or 1
      local hcode = (attr >> 12) & 0x03
      local height = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
      local last = first + width * height * 0x40 - 1
      if last >= curBase and first < curBase + N and not reported[slot] then
        reported[slot] = true
        intrude = intrude + 1
        put('intrude', string.format(
            'INTRUDER 슬롯 %d 패턴 $%04X~$%04X 팔레트 %X · 우리 $%04X~$%04X',
            slot, first, last, attr & 0x0F, curBase, curBase + N - 1))
      end
    end
  end
end, emu.eventType.startFrame)

realLog('SUB 0.3.5-allvoice-guard -- 고른 뒤 우리 자리를 가져가는 슬롯을 잡는다')
realLog('  로그 ' .. OUT)
