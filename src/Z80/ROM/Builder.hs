module Z80.ROM.Builder
  ( AssemblerError (..)
  , assemble
  , assembleWithSymbols
  ) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as BS
import           Data.Text       (Text)
import           Data.Word       (Word16)

import Z80.Asm          (Asm, runAsm)
import qualified Z80.Linker as Linker (assembleWithSymbols)
import Z80.Linker       (LinkerError)
import Z80.ROM.GameGear (ROMConfig, ROMError, buildROM, romOrigin)
import Z80.Types        (labelName)

data AssemblerError
  = LinkerErr LinkerError
  | ROMErr    ROMError
  deriving (Show, Eq)

-- | Full pipeline: Asm program → linked bytes → Game Gear ROM image
assemble :: ROMConfig -> Asm () -> Either AssemblerError BS.ByteString
assemble cfg program = fst <$> assembleWithSymbols cfg program

-- | Like 'assemble' but also returns a map of label name → resolved address.
assembleWithSymbols
  :: ROMConfig
  -> Asm ()
  -> Either AssemblerError (BS.ByteString, Map Text Word16)
assembleWithSymbols cfg program = do
  let stmts = runAsm program
  (bytes, lmap) <- either (Left . LinkerErr) Right
                     (Linker.assembleWithSymbols (romOrigin cfg) stmts)
  rom <- either (Left . ROMErr) Right (buildROM cfg bytes)
  pure (rom, Map.mapKeys labelName lmap)
