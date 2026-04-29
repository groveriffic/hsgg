-- | Game Gear PSG (SN76489) audio interface.
--
-- The Game Gear uses the SN76489 PSG integrated into the VDP chip.
-- All commands are single-byte writes to port 0x7F.
--
-- Latch/data byte (bit 7 = 1):
--   Bits: 1 [ch ch] [t] [d d d d]
--   ch = channel 0-3  (0-2 = tone, 3 = noise)
--   t  = type (0 = frequency, 1 = volume)
--   d  = 4-bit data
--
-- Tone frequency uses two bytes: latch (low 4 bits of N) + data (high 6 bits).
--   N = round(3579545 / (32 * hz))
module GameGear.PSG
  ( -- * PSG I/O port
    portPSG

    -- * Tone frequencies
  , Note (..)
  , quantizeHz
  , noteActualHz
  , setToneFreq

    -- * Volume
  , setVolume
  , silenceAll

    -- * Noise channel
  , NoiseType (..)
  , setNoise
  ) where

import Data.Bits  (shiftL, shiftR, (.&.), (.|.))
import Data.Word  (Word8, Word16)

import Z80.Asm     (Asm)
import Z80.Opcodes (ldi, outA)
import Z80.Types   (Reg8 (A))

-- ---------------------------------------------------------------------------
-- PSG port constant
-- ---------------------------------------------------------------------------

portPSG :: Word8
portPSG = 0x7F

-- ---------------------------------------------------------------------------
-- Note type
-- ---------------------------------------------------------------------------

-- | A PSG tone frequency quantized to the nearest SN76489-representable pitch.
-- The chip has 10-bit tone counters, so only ~1024 discrete frequencies exist.
-- Use 'quantizeHz' to construct and 'noteActualHz' to inspect the true frequency.
newtype Note = Note { noteCounter :: Word16 }

instance Show Note where
  show (Note n) = "Note " ++ show n ++ " (" ++ show (noteActualHz n) ++ " Hz)"

-- | Quantize a frequency in Hz to the nearest SN76489-representable 'Note'.
-- Precision is lost: the chip's 10-bit counter maps ~60 Hz–111 kHz to 1024 steps.
quantizeHz :: Double -> Note
quantizeHz hz = Note (round (3579545.0 / (32.0 * hz)))

-- | Return the actual frequency (in Hz) that the chip produces for a given counter value.
noteActualHz :: Word16 -> Double
noteActualHz n = 3579545.0 / (32.0 * fromIntegral n)

-- ---------------------------------------------------------------------------
-- Tone / volume / noise
-- ---------------------------------------------------------------------------

-- | Emit code to set a tone channel (0–2) to the frequency of a 'Note'.
-- Two OUT instructions are emitted (latch byte + data byte).
-- Destroys A.
setToneFreq :: Word8  -- ^ channel (0, 1, or 2)
            -> Note
            -> Asm ()
setToneFreq ch (Note n) = do
  let lo = 0x80 .|. (ch `shiftL` 5) .|. fromIntegral (n .&. 0x0F)
      hi = fromIntegral ((n `shiftR` 4) .&. 0x3F)
  ldi A lo
  outA portPSG
  ldi A hi
  outA portPSG

-- | Emit code to set channel volume (0 = max, 15 = silent).
-- Destroys A.
setVolume :: Word8  -- ^ channel (0–3)
          -> Word8  -- ^ attenuation (0 = loudest, 15 = silent)
          -> Asm ()
setVolume ch vol = do
  ldi A (0x90 .|. (ch `shiftL` 5) .|. (vol .&. 0x0F))
  outA portPSG

-- | Silence all four PSG channels.  Destroys A.
silenceAll :: Asm ()
silenceAll = mapM_ (\ch -> setVolume ch 15) [0, 1, 2, 3]

data NoiseType = WhiteNoise | PeriodicNoise

-- | Configure the noise channel.
-- @rate@: 0 = N\/512, 1 = N\/1024, 2 = N\/2048, 3 = use Tone2 frequency.
-- Destroys A.
setNoise :: NoiseType -> Word8 -> Asm ()
setNoise ntype rate = do
  let typeBit = case ntype of { WhiteNoise -> 0x04; PeriodicNoise -> 0x00 }
      cmd = 0xE0 .|. typeBit .|. (rate .&. 0x03)
  ldi A cmd
  outA portPSG
