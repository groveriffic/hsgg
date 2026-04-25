{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.ByteString as BS
import Data.Word (Word8)
import System.Exit (exitFailure)

import Z80

-- ---------------------------------------------------------------------------
-- RAM layout  (just below the stack at 0xDFF0)
-- ---------------------------------------------------------------------------

sprX, sprY, sprDX, sprDY :: AddrExpr
sprX  = Lit 0xC000
sprY  = Lit 0xC001
sprDX = Lit 0xC002
sprDY = Lit 0xC003

-- ---------------------------------------------------------------------------
-- Screen / sprite constants
-- ---------------------------------------------------------------------------

-- GG display is 160×144; sprites are 8×8.
--
-- Horizontal: the GG LCD shows a 160-pixel window of the VDP's 256-wide
-- scanline starting at column 48.  Columns 0–47 are left overscan and never
-- appear on screen; the right edge of the visible area is column 207.
-- For an 8-wide sprite: minX = 48 (left edge flush), maxX = 200 (right edge
-- at column 207).
--
-- Vertical: the GG LCD shows SMS VDP lines 24–167 (a 24-line top crop of the
-- 192-line Mode 4 output, symmetric with the horizontal crop).  The VDP also
-- has a Y+1 offset — a sprite with SAT Y=n has its top pixel on scan line n+1.
-- For an 8-tall sprite:
--   minY = 23  → top pixel on VDP line 24  = GG line 0   (flush with top)
--   maxY = 159 → bottom pixel on VDP line 167 = GG line 143 (flush with bottom)
minSprX, maxSprX :: Word8
minSprX = 48
maxSprX = 200   -- 48 + 160 - 8

minSprY, maxSprY :: Word8
minSprY = 23    -- top pixel on GG line 0  (VDP line 24, Y+1 offset)
maxSprY = 159   -- bottom pixel on GG line 143 (VDP line 167, Y+1+7 offset)

-- ---------------------------------------------------------------------------
-- Tile data
-- ---------------------------------------------------------------------------

-- Tile 0: solid white (palette index 1)
solidTile :: Tile
solidTile = tile (replicate 8 (replicate 8 1))

-- Tile 1: checkerboard (palette indices 0 = black, 2 = red)
checkerTile :: Tile
checkerTile = tile
  [ [0,2,0,2,0,2,0,2]
  , [2,0,2,0,2,0,2,0]
  , [0,2,0,2,0,2,0,2]
  , [2,0,2,0,2,0,2,0]
  , [0,2,0,2,0,2,0,2]
  , [2,0,2,0,2,0,2,0]
  , [0,2,0,2,0,2,0,2]
  , [2,0,2,0,2,0,2,0]
  ]

-- ---------------------------------------------------------------------------
-- Axis-update helper
-- ---------------------------------------------------------------------------
-- Emits Z80 code to move a sprite coordinate by its delta and bounce it
-- between minVal and maxVal (inclusive).  Both value and delta are in RAM.
-- Registers clobbered: A, F.

updateAxis :: AddrExpr -> AddrExpr -> Word8 -> Word8 -> Asm ()
updateAxis valAddr deltaAddr minVal maxVal = do
  goNeg <- freshLabel "_goNeg"
  decOk <- freshLabel "_decOk"
  done  <- freshLabel "_axisDone"

  -- Branch on sign bit of delta (0xFF = -1 has bit 7 set)
  ldAnn deltaAddr
  bit 7 A
  jr_cc NZ (LabelRef goNeg)

  -- Moving in positive direction: val++
  ldAnn valAddr
  inc A
  stnn valAddr
  cpAn (maxVal + 1)        -- carry set iff A < maxVal+1 (still in range)
  jr_cc CF (LabelRef done)
  ldi A maxVal             -- clamp to max
  stnn valAddr
  ldi A 0xFF               -- delta = -1
  stnn deltaAddr
  jr (LabelRef done)

  rawLabel goNeg
  -- Moving in negative direction: check BEFORE decrement to avoid Word8 wrap.
  -- If val==minVal we'd decrement to 255 (wraps unsigned), which passes cp.
  ldAnn valAddr
  cpAn minVal
  jr_cc NZ (LabelRef decOk) -- A != minVal: safe to decrement
  -- Already at minVal: reverse direction, leave val unchanged
  ldi A 1                   -- delta = +1
  stnn deltaAddr
  jr (LabelRef done)

  rawLabel decOk
  dec A
  stnn valAddr
  -- fall through to done

  rawLabel done

-- ---------------------------------------------------------------------------
-- Main demo program
-- ---------------------------------------------------------------------------

demo :: Asm ()
demo = do
  org 0x0000
  di
  ld16n SP 0xDFF0

  -- VDP init (display off while loading data)
  vdpInit

  -- Background palette (entries 0–15)
  setPalette 0
    [ black, white, red,     green
    , blue,  cyan,  magenta, yellow
    , ggColor 15 8  0   -- orange
    , ggColor  8 0 15   -- purple
    , ggColor  0 8  8   -- teal
    , ggColor 15 15 8   -- cream
    , ggColor  5 5  5   -- dark grey
    , ggColor 10 10 10  -- light grey
    , ggColor 15 10 0   -- gold
    , ggColor  0 15 10  -- mint
    ]

  -- Sprite palette (entries 16–31): greyscale ramp
  setPalette 16
    [ ggColor n n n | n <- [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] ]

  -- Load tile data into VRAM
  loadTiles 0 [solidTile, checkerTile]

  -- Fill background with the solid white tile (tile 0, palette 0, index 1 = white)
  fillNameTable 0 0

  -- Sprite 0: checkerboard tile (tile 1) at initial position (124, 72)
  initSpriteEntry 0 124 72 1
  terminateSprites 1        -- no sprites after index 0

  -- Initialise animation state in RAM
  ldi A 124
  stnn sprX
  ldi A 72
  stnn sprY
  ldi A 1
  stnn sprDX
  stnn sprDY

  -- Turn on display
  enableDisplay

  -- -------------------------------------------------------------------------
  -- Main loop: wait for VBlank, update position, write to SAT, repeat
  -- -------------------------------------------------------------------------
  mainLoop <- defineLabel "mainloop"

  waitVBlank

  -- Update X coordinate (bounces between minSprX and maxSprX)
  updateAxis sprX sprDX minSprX maxSprX

  -- Update Y coordinate (bounces between minSprY and maxSprY)
  updateAxis sprY sprDY minSprY maxSprY

  -- Write new X to SAT (A must hold the value before calling updateSpriteX)
  ldAnn sprX
  updateSpriteX 0

  -- Write new Y to SAT
  ldAnn sprY
  updateSpriteY 0

  jp (LabelRef mainLoop)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  let result = assemble defaultROMConfig demo
  case result of
    Left err -> do
      putStrLn $ "Error: " <> show err
      exitFailure
    Right rom -> do
      BS.writeFile "demo.gg" rom
      putStrLn $ "Wrote demo.gg (" <> show (BS.length rom) <> " bytes)"
