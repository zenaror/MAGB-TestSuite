; Minimal Game Boy Color hardware register definitions.
;
; Deliberately not the full community hardware.inc (github.com/gbdev/hardware.inc)
; -- only what this CGB-only TestSuite actually touches. Add registers here as
; new modules need them; don't paste in the whole thing speculatively.

; ---- Serial port (Mobile Adapter GB link) -------------------------------
DEF rSB EQU $FF01 ; Serial transfer data
DEF rSC EQU $FF02 ; Serial transfer control

DEF SC_XFER_START    EQU %10000000 ; Start a transfer (also busy flag while set)
DEF SC_CLOCK_INT     EQU %00000001 ; Internal clock (GBC is the serial master)
DEF SC_CLOCK_SPEED   EQU %00000010 ; CGB double-speed serial clock (256 KHz)
; See docs/protocol-notes.md: SC must be written in two steps -- clock/speed
; bits first, then a second write adding the start bit. A single combined
; write was confirmed (on the GBDK implementation) to leave a real Mobile
; Adapter emulation seeing only idle bytes forever.

; ---- CPU speed switch (KEY1) --------------------------------------------
DEF rKEY1 EQU $FF4D
DEF KEY1_PREPARE_SWITCH EQU %00000001

; ---- Interrupts -----------------------------------------------------------
DEF rIE EQU $FFFF
DEF rIF EQU $FF0F
DEF IEF_VBLANK EQU %00000001

; ---- LCD ------------------------------------------------------------------
DEF rLCDC EQU $FF40
DEF LCDC_ON       EQU %10000000
DEF LCDC_BG_ON    EQU %00000001
; BG/window tile data select: 1 = tiles addressed unsigned from $8000
; (tile N at $8000+N*16); 0 = signed from $9000 (tile 0 at $9000, tiles
; 128-255 at $8800-$8FFF). text.asm's LoadFont copies the font to
; $8000, so this bit must be set whenever the BG is enabled -- without
; it the PPU reads tile data from $9000 instead and every character
; renders as garbage/blank (found the hard way: a first attempt at the
; text renderer built and ran, but showed a totally blank screen).
DEF LCDC_BG_TILEDATA EQU %00010000

DEF rSTAT EQU $FF41
DEF STATF_BUSY EQU %00000010 ; STAT bit 1: set while BCPS/OCPS writes would be unsafe outside VBlank/HBlank

; ---- CGB background color palette (BCPS/BCPD) -----------------------------
DEF rBCPS EQU $FF68
DEF BCPS_AUTO_INCREMENT EQU %10000000

DEF rBCPD EQU $FF69

; ---- LCD status / line counter --------------------------------------------
DEF rLY EQU $FF44

; ---- Joypad -----------------------------------------------------------
DEF rP1 EQU $FF00

; Bits 5/4 pick which button group's state is readable in bits 3-0 at
; any one time (the GB joypad only ever exposes 4 lines) -- 0 selects a
; group, same active-low convention as the input bits themselves.
; joypad.asm's ReadJoypad reads both groups in turn and combines them;
; nothing else should write rP1 directly.
DEF P1_SELECT_DPAD    EQU %00100000 ; bit5=1 (buttons deselected), bit4=0 (d-pad selected)
DEF P1_SELECT_BUTTONS EQU %00010000 ; bit4=1 (d-pad deselected), bit5=0 (buttons selected)
DEF P1_SELECT_NONE    EQU %00110000 ; both deselected -- idle value ReadJoypad leaves rP1 in

; ReadJoypad's/ReadJoypadPressed's returned bitmask (already inverted
; from rP1's active-low input bits: 1 = held/pressed here).
DEF PAD_RIGHT  EQU %00000001
DEF PAD_LEFT   EQU %00000010
DEF PAD_UP     EQU %00000100
DEF PAD_DOWN   EQU %00001000
DEF PAD_A      EQU %00010000
DEF PAD_B      EQU %00100000
DEF PAD_SELECT EQU %01000000
DEF PAD_START  EQU %10000000
