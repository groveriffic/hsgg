{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.ByteString as BS
import Data.Word (Word8)
import System.Exit (exitFailure)

import Z80

-- ---------------------------------------------------------------------------
-- RAM layout  (just below the stack at 0xDFF0)
-- ---------------------------------------------------------------------------

sprX, sprY :: AddrExpr
sprX = Lit 0xC000
sprY = Lit 0xC001

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
-- D-pad input helpers
-- ---------------------------------------------------------------------------
-- Port 0xDC bits 0-3 are the D-pad (Up/Down/Left/Right), active-low: a
-- cleared bit means the button is held.  Caller must load port 0xDC into B
-- before invoking these helpers.  Registers clobbered: A, F.

moveNeg :: Int -> AddrExpr -> Word8 -> Asm ()
moveNeg bitN valAddr minVal = do
  skip <- freshLabel "_negSkip"
  bit bitN B
  jr_cc NZ (LabelRef skip)        -- bit set = not pressed
  ldAnn valAddr
  cpAn minVal
  jr_cc Z (LabelRef skip)         -- already at min, don't wrap
  dec A
  stnn valAddr
  rawLabel skip

movePos :: Int -> AddrExpr -> Word8 -> Asm ()
movePos bitN valAddr maxVal = do
  skip <- freshLabel "_posSkip"
  bit bitN B
  jr_cc NZ (LabelRef skip)
  ldAnn valAddr
  cpAn maxVal
  jr_cc Z (LabelRef skip)
  inc A
  stnn valAddr
  rawLabel skip

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

  -- Initialise sprite position in RAM
  ldi A 124
  stnn sprX
  ldi A 72
  stnn sprY

  -- Turn on display
  enableDisplay

  -- -------------------------------------------------------------------------
  -- Main loop: wait for VBlank, sample D-pad, update SAT, repeat.
  -- D-pad bits on port 0xDC: 0=Up, 1=Down, 2=Left, 3=Right (active-low).
  -- -------------------------------------------------------------------------
  mainLoop <- defineLabel "mainloop"

  waitVBlank

  inA 0xDC
  ld B A

  moveNeg 0 sprY minSprY    -- Up:    Y--
  movePos 1 sprY maxSprY    -- Down:  Y++
  moveNeg 2 sprX minSprX    -- Left:  X--
  movePos 3 sprX maxSprX    -- Right: X++

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
