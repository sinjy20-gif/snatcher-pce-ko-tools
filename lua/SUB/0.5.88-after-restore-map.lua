-- SUB 0.5.88 -- CD-DA 복원 직후 게임이 VRAM 어디에 쓰는지 전부 본다 (관측 전용)
--
-- 왜 대역을 정하지 않나
-- ---------------------------------------------------------------------------
-- 0.5.87 로 `$7900-$7DBF` 는 지웠다.
-- ```
-- RESTORE_WRITE 0 · EXIT_STATE sel=$02 mawr=$1000 · 복원 직후 300 프레임 LEAK 0
-- 그런데도 챕터1 부터 접수처까지 계속 깨진다
-- ```
-- 그러니 원인은 그 대역 밖이다.  이번엔 **범위를 안 정하고** 복원 직후 몇 프레임
-- 동안 VRAM 에 실린 word 를 전부 모아 구간으로 묶는다.
--
-- 무엇이 보이나
-- ---------------------------------------------------------------------------
-- ```
-- 게임의 SATB 업로드가 $1000 으로 제대로 가는가        (0.4.6.57 은 MAWR=$1000 을 남긴다)
-- 게임이 다른 어디에 쓰는가 · 그게 우리가 건드린 자리와 겹치는가
-- 우리 엔진이 복원 뒤에도 뭔가 쓰고 있는가             (있으면 안 된다)
-- ```
--
-- 판정에 쓰는 기준선
-- ```
-- .48  복원 끝 MAWR $7DC0   -> 그 자리가 검은색으로 깨진다
-- .57  복원 끝 MAWR $1000   -> 같은 자리가 빨강/파랑 줄무늬로 깨진다
-- ```
-- 두 판에서 이 지도를 각각 뜨면 **어느 구간이 달라지는지**가 곧 원인이다.
-- 같은 파일로 두 번 돌리면 된다 (BIOS/CUE 만 바꾼다).
--
-- 디코더는 0.5.75 / 0.5.80 의 검증된 것 그대로.  소유자는 exec 플래그로 가린다.
-- PC 조회는 새 구간을 처음 볼 때만 한다.
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 창(30 프레임) 이 끝나면 그 자리에서 지도를 찍는다.  언로드 불필요.
--
--   BIOS  build/patch/0.4.6.57  (그리고 비교용으로 build/patch/0.4.6.48)
--   Power Cycle -> 이 파일만 로드 -> 스킵하지 말고 CD-DA -> 챕터1 진입까지
--
-- 산출물  C:/snatcher/dump/after_restore_0_5_88_<시각>.tsv

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/after_restore_0_5_88_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

local A_ENTRY = 0x5B83
local A_RESTORE_57, A_RESTORE_48 = 0x5BE8, 0x5BEC   -- .57 / .48 의 restore 라벨
local ENG_LO, ENG_HI = 0x5B80, 0x5E1E
local CTL_LO, CTL_HI = 0x5D34, 0x5D35
local WINDOW = 30                                    -- 복원 뒤 볼 프레임 수

local frame = 0
local function rd(a) return emu.read(a, MEM) or -1 end
local function say(f, ...) emu.log(string.format(f, ...)) end
local function rec(ev, f, ...)
  local d = select('#', ...) > 0 and string.format(f, ...) or (f or '')
  out:write(string.format('%d\t%s\t%s\n', frame, ev, d)); out:flush()
end
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  local v = s['cpu.pc'] or (s.cpu and s.cpu.pc)
  return type(v) == 'number' and math.floor(v) or -1
end
local function isHelper()
  return rd(A_ENTRY) == 0xAD and rd(A_ENTRY + 1) == 0x30 and rd(A_ENTRY + 2) == 0x5D
end

local selReg, mawr = 0, 0
local inEngine = false
local armed, armedAt, done = false, nil, false

-- 구간 수집: {lo, hi, count, owner, pc}
local runs, cur = {}, nil
local function flush()
  if cur then runs[#runs + 1] = cur; cur = nil end
end
local function note(word, owner)
  if cur and cur.owner == owner and word == cur.hi + 1 then
    cur.hi = word; cur.n = cur.n + 1; return
  end
  flush()
  cur = { lo = word, hi = word, n = 1, owner = owner, pc = pcNow(), f = frame }
end

emu.addMemoryCallback(function(address)
  if not inEngine then inEngine = true end
  if (rd(address) or 0) == 0x60 then inEngine = false end
end, emu.callbackType.exec, ENG_LO, ENG_HI, CPU, MEM)

local function onRestore()
  if done or armed or not isHelper() then return end
  local base = ((rd(CTL_HI) & 0xFF) << 8) | (rd(CTL_LO) & 0xFF)
  if base ~= 0x7900 then return end                  -- CD-DA 만
  armed, armedAt = true, frame
  say('0.5.88 · %df  CD-DA 복원 감지 -- 이후 %d 프레임의 VRAM 기입을 모은다',
      frame, WINDOW)
  rec('armed', 'base=$%04X', base)
end
for _, a in ipairs({ A_RESTORE_57, A_RESTORE_48 }) do
  emu.addMemoryCallback(onRestore, emu.callbackType.exec, a, a, CPU, MEM)
end

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0 then mawr = (mawr & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 2 then
      if armed and not done and #runs < 400 then
        note(mawr & 0x7FFF, inEngine and 'engine' or 'game')
      end
      mawr = (mawr + 1) & 0xFFFF
    end
  end
end, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if armed and not done and frame - armedAt >= WINDOW then
    done = true; flush()
    -- 같은 구간이 여러 번 나오면 합쳐서 센다
    local agg, order = {}, {}
    for _, r in ipairs(runs) do
      local k = string.format('%s $%04X-$%04X', r.owner, r.lo, r.hi)
      if not agg[k] then agg[k] = { n = 0, hits = 0, pc = r.pc }; order[#order + 1] = k end
      agg[k].n = agg[k].n + r.n; agg[k].hits = agg[k].hits + 1
    end
    say('0.5.88 ========= 복원 뒤 %d 프레임의 VRAM 지도 (구간 %d 종) =========',
        WINDOW, #order)
    for i = 1, math.min(#order, 24) do
      local k = order[i]; local v = agg[k]
      say('   %-26s word %5d · %d 회 · 첫 pc $%04X', k, v.n, v.hits, v.pc)
      rec('range', '%s words=%d hits=%d pc=$%04X', k, v.n, v.hits, v.pc)
    end
    if #order > 24 then say('   ... 그 밖 %d 구간 (TSV 참조)', #order - 24) end
    local eng = 0
    for _, r in ipairs(runs) do if r.owner == 'engine' then eng = eng + r.n end end
    say('   우리 엔진이 이 창에서 쓴 word = %d  %s', eng,
        eng == 0 and '(정상 -- 복원 뒤엔 안 써야 한다)' or '★ 복원 뒤에도 쓰고 있다')
    rec('summary', 'ranges=%d engine_words=%d', #order, eng)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  rec('end', 'armed=%s done=%s', tostring(armed), tostring(done))
  out:close(); say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.88-after-restore-map armed -- 순수 관측 · 게임 무수정 · 화면 무간섭')
say('  복원 직후 %d 프레임 동안 VRAM 기입을 구간으로 묶어 찍는다', WINDOW)
say('  0.4.6.57 과 0.4.6.48 로 각각 한 번씩 돌려 비교한다')
say('  덤프 : ' .. PATH)
