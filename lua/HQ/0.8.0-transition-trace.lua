-- ★ HQ 0.8.0 -- 장면 전환 추적.  **되는 판과 안 되는 판을 비교하기 위한** 판이다
--
-- 왜 이 판인가
-- ------------
-- 소유자 지적 (2026-09-06):
--
--     "가설을 세워두고 측정을 이어가면서 결론을 만들어야지
--      추측만으로 빌드를 계속 쌓는건 난 아니라 보는데?"
--
-- 맞다.  0.5.15/16/17/18 은 전부 추측 위에 구웠다.  이 판은 굽지 않고 잰다.
--
-- 여기까지 **잰 것**과 **추측인 것**
-- --------------------------------
-- 잰 것:
--   1  35.4 초에 게임이 $5B85~$5B88 에 쓴다.  그때 STATE=02
--        pc = 9C27 / 9C46 / 9C63 / 9C80
--   2  같은 pc 가 무장 전(frame 4577, STATE=00)에도 같은 자리에 썼다
--   3  $5B80-$5E1E 는 게임의 스크립트 VM 데이터 스택 (9/1 문서 실측)
--   4  트랙 3 내내 STATE=02.  STATE=3 이 안 나온다
--   5  CD-DA 자동 진행으로 갈 때만 깨진다.  걸어 들어가면 멀쩡
--
-- 추측인 것 (아직 증거 없음):
--   · 그 쓰기가 파손의 **원인**이다        -- 시간이 겹칠 뿐이다
--   · 헬퍼 entry 가 덮여 진행이 막힌다     -- 덮인 뒤를 안 쫓았다
--
-- ★ 그리고 소유자가 낸 반례가 아직 안 풀렸다:
--     "저게 장소 전환일뿐 기계 입장에선 그냥 같은 화면 전환 아님?"
--   화면 전환은 오프닝에도 도처에 있다.  내 모델이 옳다면 오프닝도 깨져야 하는데
--   안 깨진다.  그러니 모델이 최소한 불완전하다.
--
-- 이 판이 하는 일
-- --------------
-- **매 프레임 한 줄**을 남긴다 -- frame · pc · pc구역 · STATE · cd_raw · ready.
-- 거기에 슬롯 접근 사건을 끼워 넣는다.  즉 **완전한 시간표**다.
--
-- 그러면 같은 장면을 두 판으로 찍어 **차이나는 지점**을 찾을 수 있다:
--
--     되는 판    build/patch/0.5.10   (트랙 3 자막 없음.  정상 확인됨)
--     안되는 판  build/patch/0.5.18   (또는 지금 깨지는 판)
--
-- 두 로그에서 "게임 PC 가 갈라지는 첫 프레임" 이 곧 답이다.
--
-- 읽기 전용.  화면에 아무것도 안 그린다.
--
-- 쓰는 법
--     Power Cycle -> 이 파일 하나만 -> 트랙 3 을 자동 진행으로 국장실 지나
--     막히면 20 초 더 두고 스크립트 정지 (파일이 닫힌다)
--     ★같은 짓을 0.5.10 에서도 한 번.  두 파일을 같이 줄 것
--
-- 산출  dump/hq_0_8_0_transition_<시각>.tsv        (매 프레임 한 줄)

local VERSION = '0.8.0'
local MEM = emu.memType.pceMemory

local SLOT_LO, SLOT_HI = 0x5B80, 0x5E1E
local STATE_AT = 0x7FDF
local READY_AT = 0x5CC6
local CD_RAW   = 0x26F9
local CD_BCD   = 0x20A2

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_transition_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\tpc\tzone\tstate\tready\tcd_raw\tcd_bcd\tevent\n')

local function rb(at) return emu.read(at, MEM) or 0 end

-- ★ 구역 분류.  0.7.0 은 이걸 엉성하게 해서 우리 코드를 "게임" 으로 찍었다.
local function zone(pc)
  if pc >= SLOT_LO and pc <= SLOT_HI then return 'slot' end      -- 렌더러/헬퍼
  if pc >= 0x7F00 and pc <= 0x7FFF then return 'resident' end    -- 상주부
  if pc >= 0xEC00 and pc <= 0xF0FF then return 'sched' end       -- 스케줄러 $ECF9-
  if pc >= 0xF100 and pc <= 0xFFFF then return 'bios' end        -- 뱅크1 · 무장
  return 'game'
end

local frame, rows = 0, 0
local pending = {}          -- 이번 프레임에 생긴 사건들
local seenEvent = {}        -- "kind|pc|addr" -> 횟수 (같은 것 반복 억제)

local function note(kind, address, value)
  local s = emu.getState() or {}
  local pc = s['cpu.pc'] or 0
  local z = zone(pc)
  if z == 'slot' then return end                 -- 우리 코드가 자기 안을 도는 것
  local key = kind .. '|' .. pc .. '|' .. address
  seenEvent[key] = (seenEvent[key] or 0) + 1
  if seenEvent[key] > 6 then return end          -- 같은 사건 6 번까지만
  pending[#pending + 1] = string.format('%s@%04X:%04X=%s(%s)',
    kind, pc, address, value and string.format('%02X', value) or '--', z)
end

emu.addMemoryCallback(function(a, v) note('R', a, v) end,
  emu.callbackType.read, SLOT_LO, SLOT_HI, emu.cpuType.pce, MEM)
emu.addMemoryCallback(function(a, v) note('W', a, v) end,
  emu.callbackType.write, SLOT_LO, SLOT_HI, emu.cpuType.pce, MEM)
emu.addMemoryCallback(function(a, v)
  local s = emu.getState() or {}
  pending[#pending + 1] = string.format('STATE=%02X@%04X',
    v or 0, s['cpu.pc'] or 0)
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local s = emu.getState() or {}
  local pc = s['cpu.pc'] or 0
  out:write(string.format('%d\t%04X\t%s\t%02X\t%02X\t%02X\t%02X\t%s\n',
    frame, pc, zone(pc), rb(STATE_AT), rb(READY_AT), rb(CD_RAW), rb(CD_BCD),
    #pending == 0 and '' or table.concat(pending, ' ')))
  rows = rows + 1
  pending = {}
  if frame % 600 == 0 then out:flush() end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
  emu.log(string.format('★ 저장 완료 %d 프레임 -> %s', frame, OUT))
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- 매 프레임 시간표 · 읽기 전용')
emu.log('  구역: slot / resident / sched / bios / game')
emu.log('  ★같은 장면을 0.5.10(되는 판) 과 지금 판, 두 번 찍어 비교할 것')
emu.log('  -> ' .. OUT)
