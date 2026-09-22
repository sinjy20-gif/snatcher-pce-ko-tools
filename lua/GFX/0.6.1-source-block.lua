-- GFX 0.6.1 -- 원본 그래픽 블록 뜨기  ★순수 관측 · 쓰기 0 B
--
-- 0.6.0 이 왜 빈손이었나 (2026-09-09 실측)
-- ---------------------------------------------------------------------------
-- 경로는 맞았다. `$7061` 신원 확인됨 · 히트 5,981 · 프레임 3553-6241 (45 초).
-- 그런데 P·N·헤더가 **전부 $FF** 로 나왔다. 내가 제로페이지를 `$0000` 에서 읽었기
-- 때문이다. HuC6280 의 제로페이지는 **`$2000-$20FF`** 다. `$0000` 대는 VDC 포트라
-- 읽으면 $FF 가 나온다.
--
--     ⚠ 이 사실은 저장소 여러 곳에 이미 적혀 있었다 (r5 빌더 주석 포함).
--
-- 0.6.0 이 그래도 알려준 것
--   MPR4/5/6 = $6B/$6C/$6D ~ $71/$72/$73  (6 조합)
--   -> 그래픽 데이터는 **CD-RAM 뱅크**에 있다. 디스크에서 읽어온 것이다.
--      뱅크 번호로 디스크 위치를 못 구한다 -> **바이트를 떠서 검색**해야 한다.
--   $3B00 이 원본 지문과 맞은 적 0 회 -> 지문에만 기대면 안 된다
--
-- 0.6.1 이 바꾼 것
-- ---------------------------------------------------------------------------
--   1. 제로페이지를 `$2000 + zp` 로 읽는다                        ← 진짜 고침
--   2. 지문을 기다리지 않는다. 핸들러 **입구**에서 레코드를 직접 읽어
--      [뱅크][종류][VRAM][P] 를 잡는다 (Y 는 getState 로 읽는다)
--   3. 블록마다 앞 512 B 만 뜬다. 디스크에서 위치를 찾는 데는 그거면 충분하고,
--      8 KB 씩 뜨면 주행이 느려진다
--   4. 같은 (뱅크,P) 는 한 번만 뜬다
--
-- 판정
--   VRAM 이 $16A0 인 블록이 있다      -> ★그게 헌정. 바로 디스크에서 찾는다
--   없고 블록 목록만 나온다           -> 목록의 VRAM 분포를 보고 헌정 화면을 고른다
--   히트는 있는데 레코드가 이상하다   -> 핸들러 입구 훅 지점을 다시 잡는다
--
-- 쓰는 법  이것만 로드 · 부팅 -> **헌정 화면을 지나고** 조금 더 · Stop
-- 산출물   C:/snatcher/dump/gfxsrc_0_6_1_<시각>_hits.tsv
--          C:/snatcher/dump/gfxsrc_0_6_1_<시각>_blk_<뱅크>_<P>.bin   블록 앞 512 B
--          C:/snatcher/dump/gfxsrc_0_6_1_<시각>_summary.txt

local ZP      = 0x2000         -- ★ HuC6280 제로페이지. 0.6.0 이 여기서 틀렸다
local DECOMP  = 0x7061
local H_DEF   = 0x6F60         -- 기본 그래픽 핸들러
local H_08    = 0x6FC8         -- 종류 $08
local H_04    = 0x7019         -- 종류 $04
local BLIT80, BLIT20 = 0x71EE, 0x7256
local BUF     = 0x3B00
local WIN_END = 0xE000
local DUMP_BYTES = 512
local MAX_DUMPS  = 80

local IDENT = { 0xC2, 0xB1, 0x12, 0x10, 0x03 }      -- $7061 신원
local SIG = { 0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
              0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00 }

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxsrc_0_6_1_' .. STAMP

local function say(m) emu.log(m); print(m) end

local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end
local function rd16(a) return rd(a) + rd(a + 1) * 256 end
local function zp(a) return rd(ZP + a) end            -- ★
local function zp16(a) return rd16(ZP + a) end        -- ★

local function regs()
  local ok, s = pcall(emu.getState)
  if not (ok and s) then return {} end
  return s
end
local function regY(s) return s['cpu.y'] or s['y'] or -1 end
local function mpr(s, i)
  return s['cpu.mpr[' .. i .. ']'] or s['mpr' .. i]
      or s['memoryManager.mpr[' .. i .. ']'] or -1
end

local hits, dumps, sigSeen = 0, 0, 0
local identOk = nil
local pend = nil               -- 핸들러 입구에서 잡은 레코드
local seen = {}                -- (뱅크,P) -> true
local frame = 0

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.startFrame)

local hout = assert(io.open(BASE .. '_hits.tsv', 'w'))
hout:write('hit\tframe\tkind\tvram\tP\theader\tN\tbody\ttable\tbank04\tmpr4\tdumped\n')

-- 핸들러 입구: 스크립트 스트림에서 레코드를 그대로 읽는다.
-- 진입 시 Y 는 VRAM 주소 바이트를 가리킨다 (기본·$08 경로).
local function onHandler(kind)
  return function()
    local s = regs()
    local y = regY(s)
    local base = zp16(0x08)
    if y < 0 or base < 0 then pend = nil; return end
    pend = {
      kind = kind,
      vram = rd(base + y) + rd(base + y + 1) * 256,
      p    = rd(base + y + 2) + rd(base + y + 3) * 256,
      bank = zp(0x04),
    }
  end
end

emu.addMemoryCallback(onHandler('def'), emu.callbackType.exec, H_DEF, H_DEF, CPU, MEM)
emu.addMemoryCallback(onHandler('$08'), emu.callbackType.exec, H_08, H_08, CPU, MEM)
emu.addMemoryCallback(onHandler('$04'), emu.callbackType.exec, H_04, H_04, CPU, MEM)

emu.addMemoryCallback(function()
  if identOk == nil then
    identOk = true
    for i = 1, #IDENT do
      if rd(DECOMP + i - 1) ~= IDENT[i] then identOk = false end
    end
    say(identOk and '★ $7061 신원 확인됨' or '⚠ $7061 바이트가 다르다 -- 다른 오버레이')
  end
  if not identOk then return end

  hits = hits + 1
  local s = regs()
  local p    = zp16(0x00)
  local bank = zp(0x04)
  local hdr  = zp(0x16)
  local n    = zp(0x10)
  local body = zp16(0x12)
  local tbl  = zp16(0x14)
  local kind = pend and pend.kind or '?'
  local vram = pend and pend.vram or -1

  local key = string.format('%02X_%04X', bank % 256, p % 65536)
  local did = 0
  if not seen[key] and dumps < MAX_DUMPS and p >= 0x8000 and p < WIN_END then
    seen[key] = true
    dumps = dumps + 1
    did = 1
    local len = math.min(DUMP_BYTES, WIN_END - p)
    local f = assert(io.open(BASE .. '_blk_' .. key .. '.bin', 'wb'))
    for i = 0, len - 1 do f:write(string.char(rd(p + i) % 256)) end
    f:close()
    say(string.format('블록 #%d  종류 %s  VRAM $%04X  P=$%04X  헤더 $%02X  N=%d  뱅크 $%02X',
                      dumps, kind, vram % 65536, p, hdr, n, bank))
  end

  hout:write(string.format('%d\t%d\t%s\t$%04X\t$%04X\t$%02X\t%d\t$%04X\t$%04X\t$%02X\t$%02X\t%d\n',
    hits, frame, kind, vram % 65536, p, hdr, n, body, tbl, bank, mpr(s, 4), did))
end, emu.callbackType.exec, DECOMP, DECOMP, CPU, MEM)

local function onBlit()
  return function()
    for i = 1, #SIG do
      if rd(BUF + i - 1) ~= SIG[i] then return end
    end
    sigSeen = sigSeen + 1
    if sigSeen <= 3 then
      say(string.format('★ $3B00 이 원본 지문과 일치 (프레임 %d)', frame))
    end
  end
end
emu.addMemoryCallback(onBlit(), emu.callbackType.exec, BLIT80, BLIT80, CPU, MEM)
emu.addMemoryCallback(onBlit(), emu.callbackType.exec, BLIT20, BLIT20, CPU, MEM)

emu.addEventCallback(function()
  hout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function w(m) s:write(m .. '\n'); say(m) end
  w('GFX 0.6.1 -- 원본 그래픽 블록 뜨기')
  w(string.format('$7061 히트 %d · 서로 다른 블록 %d · 지문 일치 %d', hits, dumps, sigSeen))
  if dumps == 0 then
    w('★ 블록을 하나도 못 떴다. P 가 $8000-$DFFF 밖이라는 뜻 -- hits.tsv 를 볼 것.')
  else
    w('★ 다음: 뜬 .bin 을 디스크 논리 이미지에서 바이트 검색해 위치를 확정한다.')
    w('  VRAM $16A0 인 줄이 있으면 그게 헌정이다.')
  end
  s:close()
end, emu.eventType.scriptEnded)

say('GFX 0.6.1 로드됨 -- 헌정 화면을 지나가고 Stop. 덤프: ' .. BASE)
