-- PROBE GFX 0.1.3 -- 한 줄씩 나타나는 화면을 **여러 시점에** 뜬다
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 헌사 화면이 한 줄씩 올라온다.  우리가 알아야 할 것은 하나다:
--
--     게임이 타일을 미리 다 올려두고 BAT 만 한 줄씩 켜는가?
--       -> 그렇다면 우리는 **그림만 바꿔 넣으면** 게임이 알아서 한 줄씩 보여준다.
--          타이밍을 맞출 일이 없고 연출도 그대로 산다.
--     아니면 줄마다 타일을 올리는가?
--       -> 마지막 줄까지 기다렸다가 통째로 넣어야 하고, 한 줄씩 나오는 연출은 사라진다.
--
-- 0.1.0 은 **Stop 을 누른 그 순간**만 뜬다.  그래서 2 줄 시점을 손으로 맞춰야
-- 했는데, 2026-09-05 첫 시도는 늦어서 4 줄이 다 그려진 뒤가 잡혔다
-- (BAT 행 1,2/5,6/9,10/13,14 가 전부 차 있었다).  손 타이밍으로는 놓치기 쉽다.
--
-- 그래서 이 판은 **BAT 이 변할 때마다 자동으로** 뜬다.  줄이 하나 늘 때마다
-- 한 벌씩 남으므로, 나중에 골라 보면 된다.
--
-- 무엇을 남기나
-- -------------
--     gfx_reveal_<시각>_step<N>.vram.bin / .cram.bin    변화 시점마다 한 벌
--     gfx_reveal_<시각>.tsv                             언제 몇 줄이 켜졌나
--
-- 판정하는 법 (덤프를 주면 이쪽에서 본다)
--     step1 에서 이미 4 줄어치 타일이 차 있다   -> 미리 올려두고 BAT 만 켠다
--     step 마다 타일이 같이 늘어난다            -> 줄마다 올린다
--
-- ⚠ 헌사 화면이 뜨기 **직전**에 올릴 것.  화면이 끝나면 Stop 해도 되고,
--   그냥 두면 변화가 멈춰 더 안 뜬다.

local MEM = emu.memType.pceVideoRam
local CRAM = emu.memType.pcePaletteRam

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfx_reveal_' .. STAMP
local out   = assert(io.open(BASE .. '.tsv', 'w'))
out:write('step\tframe\ttext_rows\tbat_hash\tnote\n')

local function say(m) emu.log(m); print(m) end

local W, ROWS = 64, 32          -- BAT 폭 64 (analyze_gfx_screen 추정치)
local SETTLE = 4                -- 변화가 이만큼 멎으면 한 벌 뜬다

local frame, step = 0, 0
local last_sig, quiet = nil, 0

local function bat_signature()
  -- BAT 을 훑어 (비배경 칸 수, 글자가 있는 행 목록) 을 만든다.
  local cnt = {}
  local row_has = {}
  for r = 0, ROWS - 1 do
    for c = 0, W - 1 do
      local i = (r * W + c) * 2
      local t = (emu.read(i, MEM, false) or 0) + ((emu.read(i + 1, MEM, false) or 0) % 16) * 256
      cnt[t] = (cnt[t] or 0) + 1
      row_has[r] = row_has[r] or {}
      row_has[r][t] = true
    end
  end
  local bg, best = 0, -1
  for t, n in pairs(cnt) do if n > best then bg, best = t, n end end
  local rows = {}
  for r = 0, ROWS - 1 do
    for t in pairs(row_has[r]) do
      if t ~= bg then rows[#rows + 1] = r; break end
    end
  end
  return table.concat(rows, ','), #rows
end

local function dump(note, rows_s, nrows)
  step = step + 1
  local p = ('%s_step%d'):format(BASE, step)
  emu.saveMemoryDump(p .. '.vram.bin', MEM)
  emu.saveMemoryDump(p .. '.cram.bin', CRAM)
  out:write(('%d\t%d\t%d\t%s\t%s\n'):format(step, frame, nrows, rows_s, note))
  out:flush()
  say(('  step%-2d f%-7d 글자 행 %2d 개  [%s]'):format(step, frame, nrows, rows_s))
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 6 ~= 0 then return end          -- 10 Hz 로만 훑는다 (8 KB 스캔이라 무겁다)

  local sig, nrows = bat_signature()
  if nrows == 0 then return end              -- 아직 글자 없음

  if sig ~= last_sig then
    last_sig, quiet = sig, 0
    return
  end
  quiet = quiet + 1
  if quiet == SETTLE then                     -- 변화가 멎었다 = 한 줄이 다 올라왔다
    dump('settled', sig, nrows)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write('#\n')
  out:write(('# 전체 %d 프레임 · 덤프 %d 벌\n'):format(frame, step))
  out:close()
  say('')
  say(('끝 -- 덤프 %d 벌'):format(step))
  say('  ' .. BASE .. '_step*.vram.bin')
  say('  ' .. BASE .. '.tsv')
end, emu.eventType.scriptEnded)

say('PROBE GFX 0.1.3-reveal-timeline armed -- 순수 관측')
say('  헌사 화면 **직전**에 올릴 것.  줄이 늘 때마다 자동으로 한 벌씩 뜬다')
say('  ' .. BASE .. '_step*.{vram,cram}.bin')
