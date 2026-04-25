module Z80.ROM.Builder
  ( AssemblerError (..)
  , assemble
  ) where

import qualified Data.ByteString as BS

import Z80.Asm          (Asm, runAsm)
import qualified Z80.Linker as Linker (assemble)
import Z80.Linker       (LinkerError)
import Z80.ROM.GameGear (ROMConfig, ROMError, buildROM, romOrigin)

data AssemblerError
  = LinkerErr LinkerError
  | ROMErr    ROMError
  deriving (Show, Eq)

-- | Full pipeline: Asm program → linked bytes → Game Gear ROM image
assemble :: ROMConfig -> Asm () -> Either AssemblerError BS.ByteString
assemble cfg program = do
  let stmts = runAsm program
  bytes <- either (Left . LinkerErr) Right
             (Linker.assemble (romOrigin cfg) stmts)
  either (Left . ROMErr) Right
    (buildROM cfg bytes)
