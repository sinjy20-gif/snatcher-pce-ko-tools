-- ★ HQ 0.3.1 -- STATE($7FDF) 가 진짜 그 자리인가?  MPR 을 같이 본다 (2026-09-06)
--
-- 0.2.0 이 무엇을 보여줬나
-- ----------------------
-- 국장실에서 `state` 가 **02 와 EA 사이를 매 프레임 오간다.**
--
--     9405  st=EA  slot=532480B1  pc=7617
--     9406  st=02  slot=532480B1  pc=6C3D
--     9407  st=EA  ...
--
-- `EA` 는 STATE 값이 아니다 (유효값 0·1·2·3).  `EA` = NOP 이다 -- 그 주소에서
-- **코드가 읽히고 있다.**
--
-- $7FDF 는 $6000-$7FFF 페이지 = **MPR3** 에 있다.  Super CD 는 이 페이지에
-- 뱅크를 갈아 끼운다.  게임이 다른 뱅크를 매핑한 순간 우리 STATE 는 그 자리에
-- 없다.  그러면:
--
--     CD-DA 끝 -> 스케줄러가 STATE=3 을 쓴다 -> ★엉뚱한 뱅크에 쓴다
--              -> 상주부는 3 을 못 본다 -> 슬롯 반납 안 됨 -> UI 복귀 실패
--
-- 슬롯 $5B80 은 $4000-$5FFF = MPR2 다.  그것도 같이 본다.
--
-- 이 판이 확인하는 것
-- ------------------
--   1  MPR0..7 을 매 행에 찍는다.  st=EA 인 프레임의 MPR3 이 평소와 다른가
--   2  st 가 정상일 때의 MPR3 값(=우리 뱅크)을 알아낸다
--   3  그 뱅크가 언제 밀려나는지 시간순으로 남긴다
--
-- ★ 스크립트를 처음 로드하면 `emu.getState()` 의 키 목록을 한 번 로그에 찍는다.
--   MPR 키 이름이 판마다 달라서, 못 찾으면 그 목록을 보고 이름을 고친다.
--
-- 읽기 전용.  화면에 아무것도 안 그린다.
--
-- 쓰는 법
--     Power Cycle -> 이 파일 하나만 -> 트랙 3 을 국장실까지 -> 막히면 20 초 더
--
-- 산출  dump/hq_0_3_0_mpr_state_<시각>.tsv

local VERSION = '0.3.1'
local MEM = emu.memType.pceMemory

local STATE_AT = 0x7FDF
local SLOT     = 0x5B80
local CD_RAW   = 0x26F9
local CD_BCD   = 0x20A2

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_mpr_state_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\twhy\tstate\tslot\tcd_raw\tcd_bcd\tmpr\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end

-- ★ MPR 키 이름을 처음 한 번만 찾아 둔다.
local mprKeys = nil
local function findMprKeys(s)
  local cands = {}
  for i = 0, 7 do
    -- ★ 0.3.1 실측: MesenCE 의 PCE 키는 `memoryManager.mpr[N]` 이다.
    --   0.3.0 은 이 이름을 후보에 안 넣어 mpr 칸이 전부 `??` 로 나왔다.
    local names = { 'memoryManager.mpr[' .. i .. ']',
                    'cpu.mpr' .. i, 'mpr' .. i, 'cpu.mpr[' .. i .. ']' }
    for _, n in ipairs(names) do
      if s[n] ~= nil then cands[i] = n; break end
    end
  end
  return cands
end

local function mprHex(s)
  if mprKeys == nil then mprKeys = findMprKeys(s) end
  local t = {}
  for i = 0, 7 do
    local k = mprKeys[i]
    t[#t + 1] = k and string.format('%02X', s[k] or 0) or '??'
  end
  return table.concat(t, ' ')
end

local function slotHex()
  local t = {}
  for i = 0, 3 do t[#t + 1] = string.format('%02X', rb(SLOT + i)) end
  return table.concat(t)
end

local frame, prev, lastChange, stalled, rows = 0, nil, 0, false, 0
local dumpedKeys = false

local function emit(v, why)
  out:write(string.format('%d\t%s\t%02X\t%s\t%02X\t%02X\t%s\t%04X\n',
    frame, why, v.state, v.slot, v.raw, v.bcd, v.mpr, v.pc))
  out:flush()
  rows = rows + 1
end

emu.addEventCallback(function()
  frame = frame + 1
  local s = emu.getState() or {}

  if false and not dumpedKeys then
    dumpedKeys = true
    local names = {}
    for k, _ in pairs(s) do names[#names + 1] = tostring(k) end
    table.sort(names)
    emu.log('getState 키 ' .. #names .. ' 개:')
    -- 40 개씩 끊어 찍는다 (로그 창이 한 줄을 자른다)
    local line = {}
    for _, n in ipairs(names) do
      line[#line + 1] = n
      if #line == 8 then emu.log('   ' .. table.concat(line, ' ')); line = {} end
    end
    if #line > 0 then emu.log('   ' .. table.concat(line, ' ')) end
  end

  local v = {
    state = rb(STATE_AT), slot = slotHex(),
    raw = rb(CD_RAW), bcd = rb(CD_BCD),
    mpr = mprHex(s),
    pc = s['cpu.pc'] or s['cpu.programCounter'] or 0,
  }
  local k = table.concat({ v.state, v.slot, v.raw, v.bcd, v.mpr }, '|')

  if prev == nil then
    emit(v, 'start'); prev, lastChange = k, frame; return
  end
  if k ~= prev then
    emit(v, 'change'); prev, lastChange = k, frame; stalled = false; return
  end
  if not stalled and frame - lastChange > 300 then
    emit(v, 'STALL300'); stalled = true
    emu.log(string.format('★ STALL -- state=%02X mpr=%s', v.state, v.mpr))
  end
  if frame % 600 == 0 then emit(v, 'beat') end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- STATE 자리와 MPR 을 같이 본다 · 읽기 전용')
emu.log('  $7FDF 는 MPR3($6000-$7FFF) · $5B80 은 MPR2($4000-$5FFF)')
emu.log('  -> ' .. OUT)
