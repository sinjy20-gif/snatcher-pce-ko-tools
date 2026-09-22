-- PROBE_SATB_DUMP 0.1.0
--
-- 무엇을 재나
-- ------------
-- 프레임 끝 시점의 SATB 64 엔트리를 전부 디코드해서, **게임의 살아 있는 엔트리와
-- 우리 엔트리를 나란히** 놓는다.
--
-- 왜 필요한가
--   PROBE_SAT_AFTER_PUSH 0.1.0 이 $6527 에 15,600 회 걸려 우리 엔트리를 계속
--   다시 썼는데도 글자가 안 보인다.  지금까지 확인된 것은 전부 통과다:
--
--     패턴      VRAM byte $F200 에 도착 (poc_patterns 와 일치)
--     SAT       byte $2140 에 우리 값이 정확히 도착
--     훅 자리    $6527 은 게임 SAT 루프의 끝이 맞다
--
--   그러면 남은 것은 **엔트리 형식**이다.  게임 엔트리는 화면에 나오고 우리 것은
--   안 나오므로, 둘을 나란히 보면 어느 필드가 다른지 드러난다.
--
--   추측으로 필드 뜻을 맞히는 것은 오늘 밤 이미 여러 번 빗나갔다.
--   실제로 동작하는 표본과 비교하는 편이 빠르다.
--
-- 출력  C:/snatcher/dump/probe_satb_dump_0_1_0_<날짜>.tsv   (읽기만 한다)
--
-- 쓰는 법  음성 대사 장면에서 몇 초 두면 저장된다.

local VRAM = emu.memType.pceVideoRam
local SATB_BYTE = 0x2000                 -- VDC 워드 $1000 = Mesen 바이트 $2000
local OURS = 40
local CGY = { [0]=16, [1]=32, [2]=64, [3]=64 }

local frames, saved = 0, false

local function w(i) return (emu.read(i, VRAM) or 0) + (emu.read(i+1, VRAM) or 0) * 0x100 end

local function dump()
  local name = string.format('C:/snatcher/dump/probe_satb_dump_0_1_0_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if f == nil then emu.log('저장 실패') return end
  f:write('slot\traw\ty_raw\tx_raw\tpat_raw\tattr\tscreen_x\tscreen_y\tpat_word\twidth\theight\tpal\tprio\tnote\n')

  local live = {}
  for s = 0, 63 do
    local o = SATB_BYTE + s * 8
    local y, x, p, a = w(o), w(o+2), w(o+4), w(o+6)
    local raw = string.format('%02X %02X %02X %02X %02X %02X %02X %02X',
        emu.read(o,VRAM) or 0, emu.read(o+1,VRAM) or 0, emu.read(o+2,VRAM) or 0, emu.read(o+3,VRAM) or 0,
        emu.read(o+4,VRAM) or 0, emu.read(o+5,VRAM) or 0, emu.read(o+6,VRAM) or 0, emu.read(o+7,VRAM) or 0)
    local sx, sy = x - 32, y - 64
    local patw = math.floor(p / 2) * 64
    local wid = (math.floor(a / 256) % 2 == 1) and 32 or 16
    local hgt = CGY[math.floor(a / 4096) % 4]
    local pal = a % 16
    local prio = (math.floor(a / 128) % 2 == 1) and 'front' or 'back'
    local note = (s == OURS) and '<<< 우리' or ''
    local alive = not (y == 0 and x == 0 and p == 0 and a == 0)
    if alive then
      live[#live+1] = s
      f:write(string.format('%d\t%s\t%04X\t%04X\t%04X\t%04X\t%d\t%d\t%04X\t%d\t%d\t%d\t%s\t%s\n',
              s, raw, y, x, p, a, sx, sy, patw, wid, hgt, pal, prio, note))
    end
  end
  f:close()

  emu.log(string.format('--- SATB (프레임 %d) · 살아있는 엔트리 %d 개 ---', frames, #live))
  for _, s in ipairs(live) do
    local o = SATB_BYTE + s * 8
    local y, x, p, a = w(o), w(o+2), w(o+4), w(o+6)
    emu.log(string.format('  slot %2d  y=%-4d x=%-4d pat=$%04X attr=$%04X  %dx%d pal=%d %s%s',
        s, y - 64, x - 32, math.floor(p/2)*64, a,
        (math.floor(a/256) % 2 == 1) and 32 or 16, CGY[math.floor(a/4096) % 4], a % 16,
        (math.floor(a/128) % 2 == 1) and 'front' or 'back',
        (s == OURS) and '   <<< 우리' or ''))
  end
  emu.log('-> ' .. name)
end

emu.addEventCallback(function()
  frames = frames + 1
  if frames == 180 and not saved then saved = true; dump() end
end, emu.eventType.endFrame)

emu.addEventCallback(function() dump() end, emu.eventType.scriptEnded)

emu.log('PROBE_SATB_DUMP 0.1.0 loaded')
emu.log('  3 초 뒤 자동 저장.  정지할 때 한 번 더.  게임은 안 건드린다')
