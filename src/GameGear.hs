-- | Sega Game Gear platform library.
--
-- Re-exports all hardware interfaces and the ROM assembly pipeline.
--
-- Usage:
--
-- @
-- import Z80
-- import GameGear
-- import qualified Data.ByteString as BS
--
-- myROM :: Either AssemblerError BS.ByteString
-- myROM = assemble defaultROMConfig $ do
--   org 0x0000
--   di
--   ld16n SP 0xDFF0
--   loop <- defineLabel "loop"
--   jp (LabelRef loop)
-- @
module GameGear
  ( -- * ROM assembly pipeline
    module GameGear.ROM
    -- * VDP (display)
  , module GameGear.VDP
    -- * PSG (audio)
  , module GameGear.PSG
    -- * Music driver
  , module GameGear.Music
  ) where

import GameGear.ROM
import GameGear.VDP
import GameGear.PSG
import GameGear.Music
