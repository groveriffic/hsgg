{-# LANGUAGE OverloadedStrings #-}
-- | Data-driven music driver for the SN76489 PSG.
--
-- Table format: 3 bytes per note — [duration, N & 0x0F, (N >> 4) & 0x3F].
-- Duration 0x00 is a loop-back sentinel (1 byte; freq bytes are not present).
--
-- RAM layout per channel: [ptrLo, ptrHi, dur] — 3 bytes.
module GameGear.Music
  ( MusicEntry (..)
  , emitToneTable
  , emitToneDriver
  ) where

import Data.Bits  (shiftL, shiftR, (.&.), (.|.))
import Data.Word  (Word8)
import qualified Data.Text as T

import Z80.Types   (Reg8 (A, H, L), Reg16 (HL), AddrExpr (LabelRef), Condition (NZ, Z), Label)
import Z80.Asm     (Asm, freshLabel, rawLabel, db)
import Z80.Opcodes (ldHL, ld, stnn, ldAnn, ret_cc, ret, jr, dec, inc16, orA, orAn, outA, ld16, jr_cc)

import GameGear.PSG (Note (..), portPSG)

-- | A single entry in a tone channel music table.
data MusicEntry
  = ToneNote Note Word8  -- ^ frequency and duration in frames (duration must be > 0)
  | LoopBack             -- ^ loop sentinel: driver resets pointer to table start

-- | Emit a tone music table as inline ROM bytes and return its start label.
-- The caller must ensure control flow cannot fall into this data
-- (e.g. by placing it inside a @jp@-over block).
emitToneTable :: [MusicEntry] -> Asm Label
emitToneTable entries = do
  lbl <- freshLabel "_toneTable"
  rawLabel lbl
  mapM_ encodeEntry entries
  return lbl
  where
    encodeEntry (ToneNote (Note n) dur) =
      db [ dur
         , fromIntegral (n .&. 0x0F)
         , fromIntegral ((n `shiftR` 4) .&. 0x3F)
         ]
    encodeEntry LoopBack = db [0x00]

-- | Emit a tone channel driver subroutine and return its label.
--
-- Each call decrements the duration counter. When it reaches zero the driver
-- reads the next table entry, sends the frequency to the PSG, and resets the
-- counter.  A 'LoopBack' entry resets the read pointer to the table start.
--
-- Destroys A, HL.
emitToneDriver
  :: Word8     -- ^ PSG channel (0, 1, or 2)
  -> Label     -- ^ table label returned by 'emitToneTable'
  -> AddrExpr  -- ^ RAM: table pointer lo byte
  -> AddrExpr  -- ^ RAM: table pointer hi byte
  -> AddrExpr  -- ^ RAM: duration counter
  -> Asm Label
emitToneDriver ch tableLabel ptrLo ptrHi durAddr = do
  let tag = T.pack (show ch)
  driverLbl <- freshLabel ("_driver"     <> tag)
  loadLbl   <- freshLabel ("_driverLoad" <> tag)
  loopLbl   <- freshLabel ("_driverLoop" <> tag)

  rawLabel driverLbl

  -- Decrement duration; return early if still nonzero.
  ldAnn durAddr
  dec A
  stnn durAddr
  ret_cc NZ

  -- Load ROM table pointer from RAM into HL.
  ldAnn ptrLo
  ld L A
  ldAnn ptrHi
  ld H A

  rawLabel loadLbl

  -- Read duration byte; 0x00 is the loop-back sentinel.
  ldHL A
  orA A
  jr_cc Z (LabelRef loopLbl)
  stnn durAddr
  inc16 HL

  -- Read lo nibble of N, form and send PSG latch byte.
  let latchMask = 0x80 .|. (ch `shiftL` 5)
  ldHL A
  orAn latchMask
  outA portPSG
  inc16 HL

  -- Read hi 6 bits of N and send PSG data byte.
  ldHL A
  outA portPSG
  inc16 HL

  -- Store updated pointer back to RAM.
  ld A L
  stnn ptrLo
  ld A H
  stnn ptrHi
  ret

  -- Loop sentinel: reset pointer to table start and reload.
  rawLabel loopLbl
  ld16 HL (LabelRef tableLabel)
  jr (LabelRef loadLbl)

  return driverLbl
