-- Stage 0.2.1: preload only PHA/PLA/JMP $40A4 into AC; no renderer data.
local INPUT="C:/snatcher/build/subtitles/subtitle_irq_stage_0_2_1.bin"
local BASE=0x1C0500
local ac=emu.memType.pceArcadeCardRam
local f=assert(io.open(INPUT,"rb")); local d=f:read("a"); f:close()
assert(#d==5,"unexpected IRQ-stage payload")
for i=1,#d do emu.write(BASE+i-1,string.byte(d,i),ac) end
for i=1,#d do assert((emu.read(BASE+i-1,ac)or -1)==string.byte(d,i),"AC read-back mismatch") end
emu.log("SUBTITLE 0.2.1 AC PRELOAD PASS: 5 B -> $1C0500")
