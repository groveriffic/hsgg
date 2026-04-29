{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.ByteString as BS
import Data.Word (Word8)
import System.Exit (exitFailure)

import Z80
import GameGear
import GameGear.Sym (writeSymFile)

-- ---------------------------------------------------------------------------
-- RAM layout
-- ---------------------------------------------------------------------------

sprX, sprY :: AddrExpr
sprX = Lit 0xC000
sprY = Lit 0xC001

-- Tone channel sequencer state (3 bytes each: ptr lo, ptr hi, duration)
ramMelPtrLo, ramMelPtrHi, ramMelDur :: AddrExpr
ramMelPtrLo = Lit 0xC002
ramMelPtrHi = Lit 0xC003
ramMelDur   = Lit 0xC004

ramBasPtrLo, ramBasPtrHi, ramBasDur :: AddrExpr
ramBasPtrLo = Lit 0xC005
ramBasPtrHi = Lit 0xC006
ramBasDur   = Lit 0xC007

ramHarPtrLo, ramHarPtrHi, ramHarDur :: AddrExpr
ramHarPtrLo = Lit 0xC008
ramHarPtrHi = Lit 0xC009
ramHarDur   = Lit 0xC00A

-- Noise channel state
ramNoiseDur, ramNoiseEnv :: AddrExpr
ramNoiseDur = Lit 0xC00B
ramNoiseEnv = Lit 0xC00C

-- ---------------------------------------------------------------------------
-- Note frequencies: N = round(3579545 / (32 * hz))
-- ---------------------------------------------------------------------------

-- Four Seasons – Spring (E major): E F# G# A B C# D# E
-- Quarter note = 30 frames at 60 fps (~120 BPM)
nE4, nFs4, nGs4, nA4, nB4, nCs5, nDs5, nE5, nFs5, nGs5 :: Note
nE4  = quantizeHz 329.63
nFs4 = quantizeHz 369.99
nGs4 = quantizeHz 415.30
nA4  = quantizeHz 440.00
nB4  = quantizeHz 493.88
nCs5 = quantizeHz 554.37
nDs5 = quantizeHz 622.25
nE5  = quantizeHz 659.26
nFs5 = quantizeHz 739.99
nGs5 = quantizeHz 830.61

nE3, nA3, nB3 :: Note
nE3 = quantizeHz 164.81
nA3 = quantizeHz 220.00
nB3 = quantizeHz 246.94

-- ---------------------------------------------------------------------------
-- Screen / sprite constants
-- ---------------------------------------------------------------------------

minSprX, maxSprX :: Word8
minSprX = 48
maxSprX = 200   -- 48 + 160 - 8

minSprY, maxSprY :: Word8
minSprY = 23    -- top pixel on GG line 0  (VDP line 24, Y+1 offset)
maxSprY = 159   -- bottom pixel on GG line 143 (VDP line 167, Y+1+7 offset)

-- ---------------------------------------------------------------------------
-- Tile data
-- ---------------------------------------------------------------------------

solidTile :: Tile
solidTile = tile (replicate 8 (replicate 8 1))

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
-- Port 0xDC bits 0-3 are the D-pad (Up/Down/Left/Right), active-low.
-- Caller must load port 0xDC into B before invoking.  Clobbers A, F.

moveNeg :: Int -> AddrExpr -> Word8 -> Asm ()
moveNeg bitN valAddr minVal = do
  skip <- freshLabel "_negSkip"
  bit bitN B
  jr_cc NZ (LabelRef skip)
  ldAnn valAddr
  cpAn minVal
  jr_cc Z (LabelRef skip)
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

  -- Jump over all inline tables and subroutines to init code.
  initLbl <- freshLabel "_init"
  jp (LabelRef initLbl)

  -- Music tables – Vivaldi, Four Seasons Op.8 No.1 "Spring" (E major)
  -- ~1890 frames ≈ 31.5 s per loop at 60 fps / 120 BPM
  melodyLbl <- emitToneTable
    -- Phrase A: fanfare on E5, cadence to B4, ascending run
    [ ToneNote nE5  15, ToneNote nE5  15, ToneNote nE5  15, ToneNote nE5  15
    , ToneNote nCs5 30, ToneNote nB4  30
    , ToneNote nE5  30, ToneNote nGs5 30, ToneNote nFs5 30, ToneNote nE5  30
    -- Phrase A answer: stepwise descent and half-cadence
    , ToneNote nDs5 15, ToneNote nE5  15, ToneNote nFs5 30, ToneNote nE5  30
    , ToneNote nDs5 30, ToneNote nCs5 30, ToneNote nB4  60
    -- Bird-call episode: twittering semiquaver figures
    , ToneNote nE5  15, ToneNote nFs5 15, ToneNote nE5  15, ToneNote nDs5 15
    , ToneNote nCs5 30, ToneNote nB4  30, ToneNote nA4  30, ToneNote nGs4 30
    , ToneNote nFs4 30, ToneNote nGs4 30, ToneNote nA4  30, ToneNote nB4  30
    , ToneNote nCs5 30, ToneNote nDs5 30, ToneNote nE5  60
    -- Ritornello return: fanfare + running bass line
    , ToneNote nE5  15, ToneNote nE5  15, ToneNote nE5  15, ToneNote nE5  15
    , ToneNote nCs5 30, ToneNote nB4  30
    , ToneNote nE5  30, ToneNote nGs5 30, ToneNote nFs5 30, ToneNote nE5  30
    , ToneNote nDs5 30, ToneNote nCs5 30, ToneNote nB4  30, ToneNote nE5  30
    -- Contrasting episode: descending E-major scale and ascent
    , ToneNote nE5  30, ToneNote nDs5 30, ToneNote nCs5 30, ToneNote nB4  30
    , ToneNote nA4  30, ToneNote nGs4 30, ToneNote nFs4 30, ToneNote nE4  30
    , ToneNote nFs4 30, ToneNote nGs4 30, ToneNote nA4  30, ToneNote nB4  30
    , ToneNote nCs5 60, ToneNote nB4  60
    -- Final fanfare and cadence
    , ToneNote nE5  15, ToneNote nE5  15, ToneNote nE5  15, ToneNote nE5  15
    , ToneNote nGs5 30, ToneNote nFs5 30, ToneNote nE5  30, ToneNote nDs5 30
    , ToneNote nCs5 30, ToneNote nB4  30, ToneNote nE5  60, ToneNote nE5  60
    , LoopBack
    ]
  -- Bass: I–V–IV–V arpeggiation in half-note pulses (16 × 120 = 1920 frames)
  bassLbl <- emitToneTable
    [ ToneNote nE3 120, ToneNote nB3 120, ToneNote nA3 120, ToneNote nB3 120
    , ToneNote nE3 120, ToneNote nB3 120, ToneNote nA3 120, ToneNote nE3 120
    , ToneNote nE3 120, ToneNote nE3 120, ToneNote nA3 120, ToneNote nA3 120
    , ToneNote nE3 120, ToneNote nB3 120, ToneNote nB3 120, ToneNote nE3 120
    , LoopBack
    ]
  -- Harmony: chord tones a third above the bass
  harmonyLbl <- emitToneTable
    [ ToneNote nGs4 120, ToneNote nDs5 120, ToneNote nCs5 120, ToneNote nDs5 120
    , ToneNote nGs4 120, ToneNote nDs5 120, ToneNote nA4  120, ToneNote nGs4 120
    , ToneNote nGs4 120, ToneNote nGs4 120, ToneNote nA4  120, ToneNote nA4  120
    , ToneNote nGs4 120, ToneNote nDs5 120, ToneNote nDs5 120, ToneNote nGs4 120
    , LoopBack
    ]

  -- Tone channel driver subroutines (one per PSG channel).
  melDriver <- emitToneDriver 0 melodyLbl  ramMelPtrLo ramMelPtrHi ramMelDur
  basDriver <- emitToneDriver 1 bassLbl    ramBasPtrLo ramBasPtrHi ramBasDur
  harDriver <- emitToneDriver 2 harmonyLbl ramHarPtrLo ramHarPtrHi ramHarDur

  rawLabel initLbl

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

  loadTiles 0 [solidTile, checkerTile]
  fillNameTable 0 0

  initSpriteEntry 0 124 72 1
  terminateSprites 1

  ldi A 124; stnn sprX
  ldi A 72;  stnn sprY

  enableDisplay

  -- Music init: silence all channels, set volumes, prime RAM pointers.
  -- dur=1 causes the first VBlank to immediately load note 0 from each table.
  silenceAll
  setVolume 0 0     -- Tone0 at full volume (melody)
  setVolume 1 3     -- Tone1 slightly quieter (bass)
  setVolume 2 5     -- Tone2 quieter still (harmony)

  ld16 HL (LabelRef melodyLbl)
  ld A L;  stnn ramMelPtrLo
  ld A H;  stnn ramMelPtrHi
  ldi A 1; stnn ramMelDur

  ld16 HL (LabelRef bassLbl)
  ld A L;  stnn ramBasPtrLo
  ld A H;  stnn ramBasPtrHi
  ldi A 1; stnn ramBasDur

  ld16 HL (LabelRef harmonyLbl)
  ld A L;  stnn ramHarPtrLo
  ld A H;  stnn ramHarPtrHi
  ldi A 1; stnn ramHarDur

  ldi A 1; stnn ramNoiseDur
  ldi A 0; stnn ramNoiseEnv

  -- -------------------------------------------------------------------------
  -- Main loop: wait for VBlank, advance music, sample D-pad, update SAT.
  -- D-pad bits on port 0xDC: 0=Up, 1=Down, 2=Left, 3=Right (active-low).
  -- -------------------------------------------------------------------------
  mainLoop <- defineLabel "mainloop"

  noiseEnvDoneLbl  <- freshLabel "_noiseEnvDone"
  noiseTrigDoneLbl <- freshLabel "_noiseTrigDone"

  waitVBlank

  -- Advance each tone channel via its driver subroutine.
  call (LabelRef melDriver)
  call (LabelRef basDriver)
  call (LabelRef harDriver)

  -- Noise channel: envelope countdown then periodic hit trigger.
  ldAnn ramNoiseEnv
  orA A
  jp_cc Z (LabelRef noiseEnvDoneLbl)
  dec A
  stnn ramNoiseEnv
  jp_cc NZ (LabelRef noiseEnvDoneLbl)
  setVolume 3 15                           -- envelope expired → silence
  rawLabel noiseEnvDoneLbl

  ldAnn ramNoiseDur
  dec A
  stnn ramNoiseDur
  jp_cc NZ (LabelRef noiseTrigDoneLbl)
  ldi A 120; stnn ramNoiseDur
  ldi A 8;   stnn ramNoiseEnv
  setNoise WhiteNoise 0
  setVolume 3 0
  rawLabel noiseTrigDoneLbl

  -- Sample D-pad and move sprite.
  inA 0xDC
  ld B A

  moveNeg 0 sprY minSprY    -- Up:    Y--
  movePos 1 sprY maxSprY    -- Down:  Y++
  moveNeg 2 sprX minSprX    -- Left:  X--
  movePos 3 sprX maxSprX    -- Right: X++

  ldAnn sprX
  updateSpriteX 0

  ldAnn sprY
  updateSpriteY 0

  jp (LabelRef mainLoop)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  let result = assembleWithSymbols defaultROMConfig demo
  case result of
    Left err -> do
      putStrLn $ "Error: " <> show err
      exitFailure
    Right (rom, syms) -> do
      BS.writeFile "demo.gg" rom
      putStrLn $ "Wrote demo.gg (" <> show (BS.length rom) <> " bytes)"
      writeSymFile "demo.sym" syms
      putStrLn $ "Wrote demo.sym (" <> show (length syms) <> " symbols)"
