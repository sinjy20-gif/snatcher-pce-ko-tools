-- UI POC 0.2.1: preload the corrected AC payload only.
local INPUT="C:/snatcher/build/subtitles/subtitle_line_ui_payload_v0_2_1.bin"
local BASE=0x1C0500
local ac=emu.memType.pceArcadeCardRam
local f=assert(io.open(INPUT,"rb")); local d=f:read("a"); f:close()
assert(#d>0 and #d<=0x480,"invalid UI payload")
for i=1,#d do emu.write(BASE+i-1,string.byte(d,i),ac) end
for i=1,#d do assert((emu.read(BASE+i-1,ac)or -1)==string.byte(d,i),"AC read-back mismatch") end
emu.log(string.format("SUBTITLE UI 0.2.1 AC PRELOAD PASS: %d B -> $%06X",#d,BASE))
