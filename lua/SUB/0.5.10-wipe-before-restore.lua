-- SUB 0.5.10 -- 복원 직전에 자막 스프라이트를 먼저 지운다 (순서 A/B.  쓰기 있음)
--
-- 여기까지 확정된 것
-- ---------------------------------------------------------------------------
--     0.4.6.16   헬퍼 백업/복원 대상을 $7900 -> $1600 으로 바로잡음 (디스크 2 바이트)
--     0.5.9      왕복 무손실.  6/6 음성에서 다른 워드 0/1216
--                백업 비영 **899/1216** 이 6 회 내내 동일
--                -> $1600-$1ABF 는 실제로 쓰이는 자리다.  백업/복원은 필요한 기능이다
--
-- 그런데 대사 종료/조각 전환에 **1 프레임짜리 깨진 화면**이 대사 자리에 뜬다.
--
-- 가설 -- 순서 문제
-- ---------------------------------------------------------------------------
-- 우리 자막 스프라이트 19 개는 패턴 소스로 `$1600` 을 가리킨다.  그런데 헬퍼의
-- 복원은 **표시 구간 한복판(line 34~168)** 에서 그 자리에 원본을 덮어쓴다.
-- 그 사이 SATB 의 옛 스프라이트는 여전히 `$1600` 을 가리키고 있으므로,
-- 그 프레임에 스프라이트가 **복원 중인(글리프가 아닌) 데이터를 글자로 그린다.**
--
-- 주소 수정 전에는 왜 안 보였나: 복원이 `$7900` 을 건드렸으니 `$1600` 엔 글자가
-- 그대로 남아 스프라이트가 계속 멀쩡한 글자를 그렸다.
--
-- 이 판
-- ---------------------------------------------------------------------------
-- 헬퍼의 **복원 경로 진입점 `$5BE4`** 에 걸어, 복원이 한 바이트도 쓰기 전에
-- `$1600` 을 가리키는 SATB/Sprite RAM 슬롯을 먼저 0 으로 만든다.
--
--     사라지면   순서 문제 확정.  진짜 해법은 §6-5 -- 조각마다 복원하지 말고
--                **음성 끝에 1 회**.  그러면 중간 노출 자체가 없어진다
--     남으면     순서가 아니다.  복원이 표시 구간에 있는 것 자체가 문제거나
--                다른 경로다
--
-- ⚠ 이 판은 **쓰기를 한다** (SATB/Sprite RAM 0 채우기).  진단용이지 출하용이 아니다.
-- ★ wiped 가 0 이면 판정하지 말 것 -- 훅이 안 걸렸거나 슬롯을 못 찾은 것이다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  디스크는 0.4.6.16-reviewed 여야 한다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam
local SPR  = emu.memType.pceSpriteRam

local RESTORE_ENTRY = 0x5BE4        -- 헬퍼 복원 경로 진입점 (디스어셈 확인)
local BASE = 0x1600                 -- 글리프 base (word)
local BLOCK_WORDS = 19 * 0x40
local SATB_BYTE = 0x2000            -- VRAM 바이트 주소 = word $1000 (0.4.48 과 동일)

local function rb(at, kind)
  local ok, v = pcall(emu.read, at, kind)
  if not ok or type(v) ~= 'number' then return 0 end
  return v
end

local function wz(at, kind)
  local ok = pcall(emu.write, at, 0, kind)
  return ok
end

-- 0.4.48 의 판정과 같다: 팔레트 15 · 패턴이 우리 블록을 가리킴
local function pointsAtBase(pattern, attr)
  if (attr & 0x0F) ~= 0x0F then return false end
  local first = (pattern & 0x07FF) << 5
  local width = ((attr & 0x0100) ~= 0) and 2 or 1
  local hcode = (attr >> 12) & 0x03
  local height = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
  local last = first + width * height * 0x40 - 1
  return last >= BASE and first < BASE + BLOCK_WORDS
end

local function wipeTable(kind, origin)
  local n = 0
  for slot = 0, 63 do
    local at = origin + slot * 8
    local pattern = rb(at + 4, kind) | (rb(at + 5, kind) << 8)
    local attr    = rb(at + 6, kind) | (rb(at + 7, kind) << 8)
    if pointsAtBase(pattern, attr) then
      for b = 0, 7 do wz(at + b, kind) end
      n = n + 1
    end
  end
  return n
end

local hits, wipedV, wipedS = 0, 0, 0

emu.addMemoryCallback(function()
  hits = hits + 1
  local v = wipeTable(VRAM, SATB_BYTE)
  local s = wipeTable(SPR, 0)
  wipedV = wipedV + v
  wipedS = wipedS + s
  if v > 0 or s > 0 then
    emu.log(string.format(
      'SUB 0.5.10 ★ PRE-RESTORE WIPE #%d · VRAM SATB %d칸 · Sprite RAM %d칸',
      hits, v, s))
  end
end, emu.callbackType.exec, RESTORE_ENTRY, RESTORE_ENTRY, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 74, string.format(
    '0.5.10 복원직전 훅 %d회 · 누적 SATB %d · Sprite %d',
    hits, wipedV, wipedS), hits > 0 and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

emu.log(string.format(
  'SUB 0.5.10-wipe-before-restore armed -- $%04X 진입 시 $%04X 참조 슬롯을 먼저 지운다',
  RESTORE_ENTRY, BASE))
emu.log('  ★ 훅 0 회면 판정하지 말 것 · 디스크는 0.4.6.16-reviewed 여야 한다')
emu.log('  ⚠ 이 판은 쓰기를 한다.  진단용이다')
