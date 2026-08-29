; Minimal Game Boy Color hardware register definitions.
;
; Deliberately not the full community hardware.inc (github.com/gbdev/hardware.inc)
; -- only what this CGB-only TestSuite actually touches. Add registers here as
; new modules need them; don't paste in the whole thing speculatively.

; ---- Serial port (Mobile Adapter GB link) -------------------------------
rSB EQU $FF01 ; Serial transfer data
rSC EQU $FF02 ; Serial transfer control

SC_XFER_START    EQU %10000000 ; Start a transfer (also busy flag while set)
SC_CLOCK_INT     EQU %00000001 ; Internal clock (GBC is the serial master)
SC_CLOCK_SPEED   EQU %00000010 ; CGB double-speed serial clock (256 KHz)
; See docs/protocol-notes.md: SC must be written in two steps -- clock/speed
; bits first, then a second write adding the start bit. A single combined
; write was confirmed (on the GBDK implementation) to leave a real Mobile
; Adapter emulation seeing only idle bytes forever.

; ---- CPU speed switch (KEY1) --------------------------------------------
rKEY1 EQU $FF4D
KEY1_PREPARE_SWITCH EQU %00000001

; ---- Interrupts -----------------------------------------------------------
rIE EQU $FFFF
rIF EQU $FF0F
IEF_VBLANK EQU %00000001

; ---- LCD ------------------------------------------------------------------
rLCDC EQU $FF40
LCDC_ON       EQU %10000000
LCDC_BG_ON    EQU %00000001
; BG/window tile data select: 1 = tiles addressed unsigned from $8000
; (tile N at $8000+N*16); 0 = signed from $9000 (tile 0 at $9000, tiles
; 128-255 at $8800-$8FFF). text.asm's LoadFont copies the font to
; $8000, so this bit must be set whenever the BG is enabled -- without
; it the PPU reads tile data from $9000 instead and every character
; renders as garbage/blank (found the hard way: a first attempt at the
; text renderer built and ran, but showed a totally blank screen).
LCDC_BG_TILEDATA EQU %00010000

rSTAT EQU $FF41
STATF_BUSY EQU %00000010 ; STAT bit 1: set while BCPS/OCPS writes would be unsafe outside VBlank/HBlank

; ---- CGB background color palette (BCPS/BCPD) -----------------------------
rBCPS EQU $FF68
BCPS_AUTO_INCREMENT EQU %10000000

rBCPD EQU $FF69

; ---- LCD status / line counter --------------------------------------------
rLY EQU $FF44
