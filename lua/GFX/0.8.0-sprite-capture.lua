-- GFX 0.8.0 -- 아무 장면의 스프라이트를 통째로 뜬다  (스프라이트 한글화 1단계)
--
-- 0.7.3(타이틀 전용)을 일반화한 판.  두 가지를 고쳤다.
--
--   ① **블록 목록을 미리 몰라도 된다.**  VRAM 64 KB 를 통째로 뜬다.
--      0.7.3 은 목록이 박혀 있어서 목록에 없는 스프라이트를 놓쳤다
--      (타이틀에서 `$6E00` 이 빠져 첫 줄 꼬리를 못 봤다).
--
--   ② ★ **한 프레임이 아니라 구간 내내 모은다.**  스프라이트는 프레임마다 바뀐다.
--      2026-09-15 에 타이틀을 한 프레임만 떠서 목록을 확정했다가, 그 프레임에
--      안 떠 있던 스프라이트를 놓쳐 화면에 잔상이 남았다.
--      여기서는 **살아 있었던 (패턴,크기) 를 전부** 모아 둔다.
--
-- 쓰는 법
--   LABEL 을 장면 이름으로 바꾸고, 그 장면이 뜨기 **전에** 올린다.
--   장면을 한 바퀴 보고 F(코드 브레이크) 를 누르면 그 시점까지 모은 것을 남긴다.
--   아무 키도 안 누르면 SETTLE 프레임마다 자동으로 덮어쓴다.
--
--   LABEL 후보:  moscow / after50 / neokobe / title2
--
-- 산출물  C:/snatcher/dump/sprite_<LABEL>_<시각>_*
--           _vram_full.bin    64 KB   -- 디스크 블록 찾기에 쓴다
--           _sprites.tsv      ★ 구간 내내 살아 있었던 스프라이트 전부
--           _sprites_last.tsv 마지막 프레임의 화면 그대로 (자리 확인용)
--           _cram.bin         원본 색.  ★ 없으면 미리보기가 거짓말을 한다
--
-- Mesen: Script -> Settings -> Restrictions -> Allow I/O and OS 를 켤 것.
-- 게임 RAM/VRAM/CRAM 에 한 바이트도 쓰지 않는다.

local LABEL  = "moscow"
local SETTLE = 300          -- 이 프레임마다 자동 저장 (5 초)

local VRAM = emu.memType.pceVideoRam
local CRAM = emu.memType.pcePaletteRam
local SPR  = emu.memType.pceSpriteRam

local OUT = "C:/snatcher/dump"
local stamp = os.date("%Y%m%d_%H%M%S")
local prefix = OUT .. "/sprite_" .. LABEL .. "_" .. stamp

local frame = 0
local seen = {}             -- "pat|w|h|pal" -> 처음/마지막 프레임 · 대표 좌표
local seen_n = 0

local function byte(mem, at) return emu.read(at, mem) or 0 end
local function word(mem, at) return byte(mem, at) | (byte(mem, at + 1) << 8) end

local function write_binary(path, mem, at, n)
  local f = assert(io.open(path, "wb"))
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.char(byte(mem, at + i)) end
  f:write(table.concat(t)); f:close()
end

local function decode(slot)
  local at = slot * 8
  local y, x = word(SPR, at), word(SPR, at + 2)
  local p, a = word(SPR, at + 4), word(SPR, at + 6)
  if (y | x | p | a) == 0 then return nil end
  local w = ((a & 0x0100) ~= 0) and 32 or 16
  local hc = (a >> 12) & 3
  local h = (hc == 0 and 16) or (hc == 1 and 32) or 64
  return {
    slot = slot, pat = (p & 0x07FF) * 32, w = w, h = h,
    pal = a & 0x0F, front = ((a & 0x0080) ~= 0),
    sx = (x - 0x20) & 0xFFFF, sy = (y - 0x40) & 0xFFFF,
  }
end

local function scan()
  for slot = 0, 63 do
    local s = decode(slot)
    if s then
      local k = string.format("%04X|%d|%d|%d", s.pat, s.w, s.h, s.pal)
      local e = seen[k]
      if not e then
        seen[k] = { s = s, first = frame, last = frame, n = 1 }
        seen_n = seen_n + 1
      else
        e.last = frame; e.n = e.n + 1
        -- 화면 안쪽 좌표를 대표로 남긴다 (화면 밖에 세워둔 것보다 쓸모 있다)
        if s.sx < 512 and e.s.sx >= 512 then e.s = s end
      end
    end
  end
end

local HEAD = "pattern_word\twidth\theight\tpalette\tpriority\tscreen_x\tscreen_y\t"
          .. "slot\tfirst_frame\tlast_frame\tframes\n"

local function dump_seen(path)
  local list = {}
  for _, e in pairs(seen) do list[#list + 1] = e end
  table.sort(list, function(a, b)
    if a.s.sy ~= b.s.sy then return a.s.sy < b.s.sy end
    return a.s.sx < b.s.sx
  end)
  local f = assert(io.open(path, "w"))
  f:write(HEAD)
  for _, e in ipairs(list) do
    local s = e.s
    f:write(string.format("%04X\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n",
      s.pat, s.w, s.h, s.pal, s.front and "front" or "back",
      s.sx, s.sy, s.slot, e.first, e.last, e.n))
  end
  f:close()
end

local function dump_last(path)
  local f = assert(io.open(path, "w"))
  f:write(HEAD)
  for slot = 0, 63 do
    local s = decode(slot)
    if s then
      f:write(string.format("%04X\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n",
        s.pat, s.w, s.h, s.pal, s.front and "front" or "back",
        s.sx, s.sy, s.slot, frame, frame, 1))
    end
  end
  f:close()
end

local function dump(reason)
  write_binary(prefix .. "_vram_full.bin", VRAM, 0, 0x10000)
  write_binary(prefix .. "_cram.bin", CRAM, 0, 0x400)
  dump_seen(prefix .. "_sprites.tsv")
  dump_last(prefix .. "_sprites_last.tsv")
  emu.log(string.format("SPRITE CAPTURE [%s] %s · 프레임 %d · 모은 스프라이트 %d 종 -> %s_*",
    LABEL, reason, frame, seen_n, prefix))
end

emu.addEventCallback(function()
  frame = frame + 1
  scan()
  if frame % SETTLE == 0 then dump("auto") end
end, emu.eventType.startFrame)

emu.addEventCallback(function() dump("key_F") end, emu.eventType.codeBreak)

emu.log("GFX SPRITE CAPTURE 0.8.0  [" .. LABEL .. "]  읽기 전용")
emu.log("  장면 뜨기 전에 올리고 한 바퀴 본 뒤 F.  " .. SETTLE .. " 프레임마다 자동 저장도 된다")
emu.log("  ★ 한 프레임이 아니라 구간 내내 살아 있던 스프라이트를 전부 모은다")
