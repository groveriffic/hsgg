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

-- Note sequencer state (melody, Tone0)
ramDur, ramStep :: AddrExpr
ramDur  = Lit 0xC002   -- frames remaining in current note (counts down)
ramStep = Lit 0xC003   -- current note index (0–3, cycles through Spring motif)

-- Bass sequencer state (Tone1)
ramBaseDur, ramBaseStep :: AddrExpr
ramBaseDur  = Lit 0xC004
ramBaseStep = Lit 0xC005

-- Harmony sequencer state (Tone2)
ramHarmDur, ramHarmStep :: AddrExpr
ramHarmDur  = Lit 0xC006
ramHarmStep = Lit 0xC007

-- Noise channel state
ramNoiseDur, ramNoiseEnv :: AddrExpr
ramNoiseDur = Lit 0xC008   -- frames until next hit (counts down from 120)
ramNoiseEnv = Lit 0xC009   -- envelope frames remaining (counts down, 0 = silent)

-- ---------------------------------------------------------------------------
-- Note frequencies: N = round(3579545 / (32 * hz))
-- ---------------------------------------------------------------------------

nE5, nDs5, nB4 :: Note
nE5  = quantizeHz 659.26   -- E5  (melody)
nDs5 = quantizeHz 622.25   -- D#5 (melody)
nB4  = quantizeHz 493.88   -- B4  (melody)

nE3, nA3, nB3 :: Note
nE3 = quantizeHz 164.81    -- E3  (bass, root)
nA3 = quantizeHz 220.00    -- A3  (bass, IV)
nB3 = quantizeHz 246.94    -- B3  (bass, V)

nGs4, nCs5 :: Note
nGs4 = quantizeHz 415.30   -- G#4 (harmony, third of E)
nCs5 = quantizeHz 554.37   -- C#5 (harmony, third of A)
-- third of B is D#5 = nDs5, already defined

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
  -- Music init: silence all channels, prime Tone0, set up sequencer state.
  -- ramDur=1 so the first VBlank immediately loads note 0 (E5).
  -- ramStep=3 so after the first increment-and-wrap we land on step 0.
  -- -------------------------------------------------------------------------
  silenceAll
  setVolume 0 0     -- Tone0 at full volume (melody)
  setVolume 1 3     -- Tone1 slightly quieter (bass)
  setVolume 2 5     -- Tone2 quieter still (harmony)
  ldi A 1
  stnn ramDur
  ldi A 3
  stnn ramStep
  ldi A 1
  stnn ramBaseDur
  ldi A 3
  stnn ramBaseStep
  ldi A 1
  stnn ramHarmDur
  ldi A 3
  stnn ramHarmStep
  ldi A 1
  stnn ramNoiseDur
  ldi A 0
  stnn ramNoiseEnv

  -- -------------------------------------------------------------------------
  -- Main loop: wait for VBlank, advance music, sample D-pad, update SAT.
  -- D-pad bits on port 0xDC: 0=Up, 1=Down, 2=Left, 3=Right (active-low).
  -- -------------------------------------------------------------------------
  mainLoop <- defineLabel "mainloop"

  -- Labels for the note-sequencer dispatch (created before use so they can be
  -- referenced as forward targets by the conditional jumps above them).
  noteNoChangeLbl <- freshLabel "_noteNoChange"
  stepOkLbl       <- freshLabel "_stepOk"
  note0Lbl        <- freshLabel "_note0"
  note1Lbl        <- freshLabel "_note1"
  note2Lbl        <- freshLabel "_note2"
  note3Lbl        <- freshLabel "_note3"
  noteAfterLbl    <- freshLabel "_noteAfter"

  waitVBlank

  -- Decrement duration counter; skip note change when still nonzero.
  ldAnn ramDur
  dec A
  stnn ramDur
  jp_cc NZ (LabelRef noteNoChangeLbl)

  -- Duration expired: reset to 30 frames (≈ quarter note at 120 BPM / 60 fps).
  ldi A 30
  stnn ramDur

  -- Advance note step (0→1→2→3→0→…).
  ldAnn ramStep
  inc A
  cpAn 4
  jp_cc NZ (LabelRef stepOkLbl)
  ldi A 0
  rawLabel stepOkLbl
  stnn ramStep          -- A = new step (0–3) after this store

  -- Dispatch: play the note for this step.
  --   Step 0: E5   Step 1: D#5   Step 2: E5   Step 3: B4
  orA A                            -- sets Z if step == 0
  jp_cc Z (LabelRef note0Lbl)
  cpAn 1
  jp_cc Z (LabelRef note1Lbl)
  cpAn 2
  jp_cc Z (LabelRef note2Lbl)
  jp (LabelRef note3Lbl)

  rawLabel note0Lbl
  setToneFreq 0 nE5
  jp (LabelRef noteAfterLbl)

  rawLabel note1Lbl
  setToneFreq 0 nDs5
  jp (LabelRef noteAfterLbl)

  rawLabel note2Lbl
  setToneFreq 0 nE5
  jp (LabelRef noteAfterLbl)

  rawLabel note3Lbl
  setToneFreq 0 nB4

  rawLabel noteAfterLbl
  rawLabel noteNoChangeLbl

  -- -----------------------------------------------------------------------
  -- Bass sequencer (Tone1): E3 → A3 → B3 → E3, 120 frames each (≈ 1 bar)
  -- -----------------------------------------------------------------------
  bassNoChangeLbl <- freshLabel "_bassNoChange"
  bassStepOkLbl   <- freshLabel "_bassStepOk"
  bass0Lbl        <- freshLabel "_bass0"
  bass1Lbl        <- freshLabel "_bass1"
  bass2Lbl        <- freshLabel "_bass2"
  bass3Lbl        <- freshLabel "_bass3"
  bassAfterLbl    <- freshLabel "_bassAfter"

  ldAnn ramBaseDur
  dec A
  stnn ramBaseDur
  jp_cc NZ (LabelRef bassNoChangeLbl)

  ldi A 120
  stnn ramBaseDur

  ldAnn ramBaseStep
  inc A
  cpAn 4
  jp_cc NZ (LabelRef bassStepOkLbl)
  ldi A 0
  rawLabel bassStepOkLbl
  stnn ramBaseStep

  orA A
  jp_cc Z (LabelRef bass0Lbl)
  cpAn 1
  jp_cc Z (LabelRef bass1Lbl)
  cpAn 2
  jp_cc Z (LabelRef bass2Lbl)
  jp (LabelRef bass3Lbl)

  rawLabel bass0Lbl
  setToneFreq 1 nE3
  jp (LabelRef bassAfterLbl)

  rawLabel bass1Lbl
  setToneFreq 1 nA3
  jp (LabelRef bassAfterLbl)

  rawLabel bass2Lbl
  setToneFreq 1 nB3
  jp (LabelRef bassAfterLbl)

  rawLabel bass3Lbl
  setToneFreq 1 nE3

  rawLabel bassAfterLbl
  rawLabel bassNoChangeLbl

  -- -----------------------------------------------------------------------
  -- Harmony sequencer (Tone2): G#4 → C#5 → D#5 → G#4, 120 frames each
  -- (thirds of the E–A–B–E progression)
  -- -----------------------------------------------------------------------
  harmNoChangeLbl <- freshLabel "_harmNoChange"
  harmStepOkLbl   <- freshLabel "_harmStepOk"
  harm0Lbl        <- freshLabel "_harm0"
  harm1Lbl        <- freshLabel "_harm1"
  harm2Lbl        <- freshLabel "_harm2"
  harm3Lbl        <- freshLabel "_harm3"
  harmAfterLbl    <- freshLabel "_harmAfter"

  ldAnn ramHarmDur
  dec A
  stnn ramHarmDur
  jp_cc NZ (LabelRef harmNoChangeLbl)

  ldi A 120
  stnn ramHarmDur

  ldAnn ramHarmStep
  inc A
  cpAn 4
  jp_cc NZ (LabelRef harmStepOkLbl)
  ldi A 0
  rawLabel harmStepOkLbl
  stnn ramHarmStep

  orA A
  jp_cc Z (LabelRef harm0Lbl)
  cpAn 1
  jp_cc Z (LabelRef harm1Lbl)
  cpAn 2
  jp_cc Z (LabelRef harm2Lbl)
  jp (LabelRef harm3Lbl)

  rawLabel harm0Lbl
  setToneFreq 2 nGs4
  jp (LabelRef harmAfterLbl)

  rawLabel harm1Lbl
  setToneFreq 2 nCs5
  jp (LabelRef harmAfterLbl)

  rawLabel harm2Lbl
  setToneFreq 2 nDs5
  jp (LabelRef harmAfterLbl)

  rawLabel harm3Lbl
  setToneFreq 2 nGs4

  rawLabel harmAfterLbl
  rawLabel harmNoChangeLbl

  -- -----------------------------------------------------------------------
  -- Noise channel: white noise hit on every bar downbeat (120 frames),
  -- with an 8-frame volume envelope that fades to silence.
  -- -----------------------------------------------------------------------
  noiseEnvDoneLbl  <- freshLabel "_noiseEnvDone"
  noiseTrigDoneLbl <- freshLabel "_noiseTrigDone"

  -- Envelope: count down; when it reaches 0 silence the noise channel.
  ldAnn ramNoiseEnv
  orA A
  jp_cc Z (LabelRef noiseEnvDoneLbl)
  dec A
  stnn ramNoiseEnv
  jp_cc NZ (LabelRef noiseEnvDoneLbl)
  setVolume 3 15                           -- envelope expired → silence
  rawLabel noiseEnvDoneLbl

  -- Trigger: fire a new hit when the countdown reaches 0.
  ldAnn ramNoiseDur
  dec A
  stnn ramNoiseDur
  jp_cc NZ (LabelRef noiseTrigDoneLbl)
  ldi A 120
  stnn ramNoiseDur
  ldi A 8
  stnn ramNoiseEnv
  setNoise WhiteNoise 0                    -- white noise, rate N/512
  setVolume 3 0                            -- full volume
  rawLabel noiseTrigDoneLbl

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
