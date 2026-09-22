-- GAUDI KEYPAD BG 0.2.1 -- runtime-only 8x16 Hangul artwork proof.
-- No CPU RAM, disc image or save data write. It only replaces the currently
-- displayed keypad's BG VRAM after verifying the original 64-wide BAT layout.
--
-- 0.2.0 wrote only the bytes that differ from the capture, which leaves an
-- earlier POC's ink in place wherever the new payload returns a byte to its
-- captured value -- the strokes then double up on screen. 0.2.1 writes every
-- byte of the ranges the payload owns, so a re-run always lands on a clean
-- cell no matter what ran before it.
local BASE = "C:/snatcher/dump/gaudi_keypad_vram_v010.bin"
local TARGET = "C:/snatcher/build/gfx/gaudi_keypad/gaudi_keypad_hangul_8x16_poc_vram.bin"
local SPANS = "C:/snatcher/build/gfx/gaudi_keypad/gaudi_keypad_hangul_8x16_poc_writes.tsv"
local VRAM = emu.memType.pceVideoRam
local function readall(path) local f=assert(io.open(path,"rb"));local d=f:read("*a");f:close();return d end
local base,target=readall(BASE),readall(TARGET)
assert(#base==0x10000 and #target==0x10000,"Gaudi 8x16 payload size mismatch")
local function same(at) return (emu.read(at,VRAM)or 0)==string.byte(base,at+1) and (emu.read(at+1,VRAM)or 0)==string.byte(base,at+2) end
-- Verify the group divider beside each key row, not the glyph cells themselves:
-- an earlier runtime POC may already have replaced glyph VRAM when this script
-- is reloaded. Physical BAT is $0000 and 64 cells wide, and a key row's top
-- tile is 33, 35 or 37; column 3 is the divider and is never rewritten.
assert(same((33*64+3)*2) and same((35*64+3)*2) and same((37*64+3)*2),"not the Gaudi keypad frame")
local n,spans=0,0
for line in io.lines(SPANS) do
  local offset,length=line:match("^(%d+)\t(%d+)$")
  if offset then
    offset,length=tonumber(offset),tonumber(length)
    for at=offset,offset+length-1 do emu.write(at,string.byte(target,at+1),VRAM);n=n+1 end
    spans=spans+1
  end
end
assert(spans>0,"no write ranges loaded -- rebuild the payload first")
emu.log(string.format("GAUDI KEYPAD BG 0.2.1 8x16 POC -- %d bytes over %d ranges (runtime-only)",n,spans))
