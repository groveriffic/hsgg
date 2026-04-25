-- | Z80 assembly DSL for Sega Game Gear
--
-- Usage:
--
-- @
-- import Z80
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
module Z80
  ( -- * Assembler entry point
    module Z80.ROM.Builder
    -- * ROM configuration
  , module Z80.ROM.GameGear
    -- * Asm monad
  , module Z80.Asm
    -- * Types
  , module Z80.Types
    -- * Opcode DSL
  , module Z80.Opcodes
    -- * Platform: Game Gear VDP
  , module Z80.Platform.GameGear
  ) where

import Z80.ROM.Builder
import Z80.ROM.GameGear
import Z80.Asm
import Z80.Types
import Z80.Opcodes
import Z80.Platform.GameGear
