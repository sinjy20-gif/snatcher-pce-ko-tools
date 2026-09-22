-- GFX 0.4.3 -- 업로더가 돌 때 MPR7 이 누구인가  ★순수 관측 · 쓰기 0 B
--
-- 왜 재나 (2026-09-09)
-- ---------------------------------------------------------------------------
-- `0.6.3-diag-gfx-nosig` 실기 결과: **지문을 절대 안 맞는 값으로 두어 주입이
-- 0 회인데도 배경이 깨진다.**  방아쇠가 아니라 **패치 자리**가 범인이다.
-- (r1~r4 실패 원인이 "타이틀 지문 오탐" 으로 기록돼 있었는데 그건 아니었다 --
--  프로브 두 판에서 그 지문은 부팅·타이틀에 한 번도 안 걸린다)
--
-- 프롤로그 재현은 정상이었다.  원본 `$7256` 여섯 바이트
--
--     A4 97        LDY $97
--     9F 11 14     BBS1 $11, $726F
--     82           CLX
--     ($725C       LDA $3B00,X)
--
-- 을 훅이 `LDY $97 / LDA $11 / AND #2 / BNE alt / CLX` 로 그대로 재현하고,
-- `PHY` 를 한 경로는 전부 `PLY` 를 지나며, `alt` 는 `PLA/PLA/JMP $726F` 다.
-- 스택도 레지스터도 맞다.  그러면 남는 것은 **점프가 어디로 가느냐**다.
--
-- ★ 가설
-- ---------------------------------------------------------------------------
-- 훅은 `$7256` 을 `JSR $FF74` 로 바꾼다.  `$FF74` 는 CPU `$E000-$FFFF` = **MPR7**.
-- 그런데 이 프로젝트엔 이미 기록이 있다:
--
--     CPU $E000-$FFFF 는 뱅크가 둘 -- MPR7 $00 원본 BIOS / $01 우리
--
-- `$7256` 은 Track 02 코드다.  그게 돌 때 MPR7 이 **원본** 이면 `JSR $FF74` 는
-- 우리 게이트가 아니라 원본 BIOS 의 임의 코드로 뛴다.  그러면 지문·무장과
-- 무관하게 처음부터 폭주한다 -- 실기 관측과 정확히 맞는다.
--
-- 무엇을 세나
-- ---------------------------------------------------------------------------
--   `$725C` 실행마다 MPR0..7 을 읽어 **MPR7 값의 분포**를 센다.
--   ⚠ 이 프로브는 **정상 `0.6.2`** 에 올린다.  깨진 진단판이 필요 없다 --
--     "업로더가 돌 때 MPR7 이 무엇인가" 는 게임의 성질이지 패치의 성질이 아니다.
--
-- 판정
--   MPR7 이 한 값으로 고정이고 그게 우리 뱅크    -> 이 가설 기각.  다른 데를 판다
--   MPR7 이 원본 뱅크인 진입이 하나라도 있다     -> ★확정.  훅을 MPR7 에 두면 안 된다
--                                                  (Track 02 쪽 동굴이나 MPR 고정 필요)
--
-- 쓰는 법
--   1) `build/patch/0.6.2` · 이 프로브만 로드
--   2) 부팅 -> 타이틀 -> 헌정 (0.4.2 와 같은 구간)
--   3) Stop -> _summary.txt
--
-- 산출물  C:/snatcher/dump/gfxmpr_0_4_3_<시각>_hits.tsv / _summary.txt

local UPLOADER = 0x725C
local REPORT   = 600
local MAX_ROWS = 3000

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxmpr_0_4_3_' .. STAMP

local hout = assert(io.open(BASE .. '_hits.tsv', 'w'))
hout:write('frame\tmpr0\tmpr1\tmpr2\tmpr3\tmpr4\tmpr5\tmpr6\tmpr7\n')
hout:flush()

local function say(m) emu.log(m); print(m) end

local function readMpr()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return nil end
  local out = {}
  for i = 0, 7 do
    local v = s['cpu.mpr[' .. i .. ']']
        or s['mpr' .. i]
        or s['memoryManager.mpr[' .. i .. ']']
    if type(v) ~= 'number' then return nil end
    out[i] = v & 0xFF
  end
  return out
end

local frame, hits, rows = 0, 0, 0
local mpr7 = {}          -- MPR7 값 -> 횟수
local combo = {}         -- MPR0..7 조합 -> 횟수
local firstFrame = {}

emu.addMemoryCallback(function()
  hits = hits + 1
  local m = readMpr()
  if not m then return end
  mpr7[m[7]] = (mpr7[m[7]] or 0) + 1
  local key = ''
  for i = 0, 7 do key = key .. string.format('%02X ', m[i]) end
  key = key:sub(1, -2)
  if combo[key] == nil then firstFrame[key] = frame end
  combo[key] = (combo[key] or 0) + 1
  if rows < MAX_ROWS then
    rows = rows + 1
    hout:write(('%d\t%s\n'):format(frame, key:gsub(' ', '\t')))
  end
end, emu.callbackType.exec, UPLOADER, UPLOADER, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % REPORT == 0 then
    local parts = {}
    for v, n in pairs(mpr7) do parts[#parts + 1] = ('$%02X x%d'):format(v, n) end
    table.sort(parts)
    say(('f%d  업로더 진입 %d · MPR7 %s')
        :format(frame, hits, #parts > 0 and table.concat(parts, ' · ') or '-'))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  hout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end
  put(('프레임 %d · `$%04X` 진입 %d 회'):format(frame, UPLOADER, hits))
  put('')
  put('MPR7 값 분포 (★ 이것이 판정이다)')
  local vals = {}
  for v in pairs(mpr7) do vals[#vals + 1] = v end
  table.sort(vals)
  for _, v in ipairs(vals) do
    put(('   $%02X   %d 회'):format(v, mpr7[v]))
  end
  if #vals == 0 then
    put('   ★ 진입이 0 이다.  구간을 안 지났거나 훅 주소가 다르다')
  elseif #vals == 1 then
    put(('   -> MPR7 이 $%02X 하나로 고정이다.'):format(vals[1]))
    put('      그 값이 **우리 BIOS 뱅크**면 이 가설은 기각이다.')
    put('      원본 뱅크면 ★확정 -- $FF74 훅은 원본 BIOS 로 뛴다.')
  else
    put('   ★★ MPR7 이 여러 값이다 -- 업로더가 뱅크 두 개에서 돈다.')
    put('      $FF74 에 훅을 두면 그중 한쪽에서는 우리 코드가 아니다.  확정.')
  end
  put('')
  put('MPR0..7 조합 (많은 순)')
  local rowsC = {}
  for k, n in pairs(combo) do rowsC[#rowsC + 1] = { k = k, n = n } end
  table.sort(rowsC, function(a, b) return a.n > b.n end)
  for i = 1, math.min(#rowsC, 12) do
    put(('   %s   %d 회  (처음 f%d)')
        :format(rowsC[i].k, rowsC[i].n, firstFrame[rowsC[i].k]))
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('GFX 0.4.3-mpr-at-uploader armed -- $725C 진입 때 MPR7 을 센다 · 쓰기 0 B')
say('  ★ 정상 0.6.2 에 올린다 (진단판 아님).  부팅 -> 타이틀 -> 헌정')
say('  ' .. BASE .. '_hits.tsv')
