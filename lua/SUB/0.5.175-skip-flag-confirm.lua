-- SUB 0.5.175 -- 스킵 깃발 후보 확인 (짧은 감시 목록)
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 0.5.174 가 스킵 직후 바뀌는 주소를 580 곳 찾았다.  너무 많다 -- 스킵하면
-- 장면이 통째로 바뀌어 RAM 이 요동치기 때문이다.  그중 **가장 빠른 것들**만
-- 남겨 놓고, 이번엔 반대를 본다:
--
--     0.5.174 가 답한 것    스킵하면 바뀌나?          -> 아래 후보 전부 예
--     ★이 프로브가 답할 것   재생 중엔 정말 안 바뀌나?  -> 이게 진짜 조건이다
--
-- 깃발이 되려면 셋을 다 만족해야 한다:
--     1  트랙 17 재생 내내 **한 값**으로 가만히 있는다
--     2  스킵하면 즉시 바뀐다                    (0.5.174 로 확인됨)
--     3  자연 종료에도 바뀐다                    (안 바뀌어도 되지만 알면 좋다)
--
-- 어떻게 쓰나  -- ★두 번 돌린다
-- -------------------------------
--   A) 스킵 없이 완주   오프닝을 끝까지 둔다.  1 번과 3 번을 본다
--   B) 스킵            자막 3~4 개 뒤 스킵.  2 번을 재확인한다
--
--   각각 끝날 때 요약이 찍힌다.  A 에서 "재생 중 변화 0" 인 주소만 쓸 수 있다.
--
-- 산출물  C:/snatcher/dump/skip_confirm_0_5_175_<시각>.tsv

local MEM = emu.memType.pceMemory

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/skip_confirm_0_5_175_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tphase\taddr\told\tnew\n')

local function say(m) emu.log(m); print(m) end

local TRACK_AT, TRACK_BCD = 0x20A2, 0x17

-- 0.5.174 가 뽑은 빠른 후보 (+1 ~ +5)
local CAND = {
  0x222D, 0x222E, 0x222F, 0x2230, 0x2231,   -- +1  5 B 연속 $08 -> $00
  0x3C00, 0x3CF0, 0x3CF2,                   -- +1
  0x20E4,                                   -- +3
  0x2018, 0x201D,                           -- +4 / +5
  0x20FE, 0x2280, 0x2228,                   -- +5 / +10
  TRACK_AT,                                 -- 대조군.  지금 쓰는 신호 (+620)
}

local frame = 0
local playing, playFrom = false, nil
local stoppedAt = nil
local last = {}
local playChanges = {}     -- 재생 중 변화 수  ★0 이어야 쓸 수 있다
local playValue = {}       -- 재생 중 값 (첫 관측)
local afterFirst = {}      -- 정지 뒤 처음 바뀐 프레임(상대)

for _, a in ipairs(CAND) do
  last[a] = -1; playChanges[a] = 0; playValue[a] = nil
end

emu.addEventCallback(function()
  frame = frame + 1
  local trk = emu.read(TRACK_AT, MEM, false) or 0

  if not playing and trk == TRACK_BCD then
    playing, playFrom = true, frame
    for _, a in ipairs(CAND) do
      playValue[a] = emu.read(a, MEM, false) or 0
      last[a] = playValue[a]
    end
    say(('트랙 17 재생 시작 f%d -- 후보 %d 개 감시'):format(frame, #CAND))
    return
  end
  if not playing then return end

  if trk ~= TRACK_BCD and not stoppedAt then
    stoppedAt = frame
    say(('★CD-DA 정지 (기존 신호 $20A2)  f%d  -- 재생 %d 프레임')
          :format(frame, frame - playFrom))
  end

  for _, a in ipairs(CAND) do
    local v = emu.read(a, MEM, false) or 0
    if v ~= last[a] then
      local prev = last[a]
      last[a] = v
      local phase = stoppedAt and 'AFTER' or 'PLAY'
      if not stoppedAt then
        playChanges[a] = playChanges[a] + 1
        if playChanges[a] <= 3 then
          say(('  ⚠재생 중 변화  f%-7d $%04X  $%02X -> $%02X  (깃발 자격 상실)')
                :format(frame, a, prev, v))
        end
      elseif not afterFirst[a] then
        afterFirst[a] = frame - stoppedAt
      end
      out:write(('%d\t%s\t%04X\t%02X\t%02X\n'):format(frame, phase, a, prev, v))
      out:flush()
    end
  end

  if frame % 900 == 0 then
    say(('심박 f%-7d  트랙=$%02X  재생 %d 프레임')
          :format(frame, trk, playFrom and (frame - playFrom) or 0))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  if not playing then
    say('★트랙 17 재생을 못 봤다 -- 오프닝을 틀었는지 확인할 것')
    out:close(); say('  ' .. PATH); return
  end
  say(('결과 -- 재생 f%d 부터, 정지 %s')
        :format(playFrom, stoppedAt and ('f' .. stoppedAt) or '(안 멈춤)'))
  say('')
  say('  주소    재생중값  재생중변화   정지뒤 첫변화')
  out:write('#\n# 주소\t재생중값\t재생중변화\t정지뒤첫변화\n')
  local good = {}
  for _, a in ipairs(CAND) do
    local pv = playValue[a] or 0
    local pc = playChanges[a]
    local af = afterFirst[a]
    local mark = ''
    if pc == 0 then
      mark = af and ('   ★깃발 후보 (+' .. af .. ')') or '   (정지 뒤에도 안 변함)'
      if af then good[#good + 1] = a end
    else
      mark = '   ✘재생 중에 변한다'
    end
    local line = ('  $%04X   $%02X       %-6d      %s%s')
                   :format(a, pv, pc, af and ('+' .. af) or '-', mark)
    say(line)
    out:write(('# %04X\t%02X\t%d\t%s\n'):format(a, pv, pc, af or '-'))
  end
  out:close()
  say('')
  if #good > 0 then
    local parts = {}
    for _, a in ipairs(good) do parts[#parts + 1] = ('$%04X'):format(a) end
    say('  ★쓸 수 있는 후보: ' .. table.concat(parts, ' '))
    say('   그중 정지 뒤 첫변화가 가장 작은 것을 고른다.')
  else
    say('  ★쓸 수 있는 후보가 없다 -- 전부 재생 중에도 변한다.')
    say('   그러면 $E018(CD_PAUSE) 훅이거나, 자막 5 개를 감수하거나 둘 중 하나다.')
  end
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.175-skip-flag-confirm armed -- 순수 관측')
say('  ★두 번 돌린다:  A) 스킵 없이 완주   B) 자막 3~4 개 뒤 스킵')
say('  A 에서 "재생 중 변화 0" 인 주소만 깃발이 될 수 있다')
say('  ' .. PATH)
