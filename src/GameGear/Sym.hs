{-# LANGUAGE OverloadedStrings #-}
-- | Emulicious / WLA-DX symbol file generation.
--
-- Format:
--   [labels]
--   BB:AAAA label_name
--
-- BB = bank (hex), AAAA = address within bank (hex).
-- For ROMs up to 32 KB (no bank switching), all labels are in bank 00.
module GameGear.Sym
  ( formatSym
  , writeSymFile
  ) where

import           Data.Map.Strict  (Map)
import qualified Data.Map.Strict  as Map
import           Data.Text        (Text)
import qualified Data.Text        as T
import qualified Data.Text.IO     as TIO
import           Data.Word        (Word16)
import           Numeric          (showHex)

-- | Render a label map as a WLA-DX / Emulicious @.sym@ file.
formatSym :: Map Text Word16 -> Text
formatSym symMap =
  T.unlines $ "[labels]" : map formatEntry (Map.toAscList symMap)
  where
    formatEntry (name, addr) =
      T.pack (pad2 bank <> ":" <> pad4 offset <> " ") <> name
      where
        bank   = fromIntegral addr `div` (0x4000 :: Int)
        offset = fromIntegral addr `mod` (0x4000 :: Int)
        pad2 n = let s = showHex (n :: Int) "" in replicate (2 - length s) '0' <> s
        pad4 n = let s = showHex (n :: Int) "" in replicate (4 - length s) '0' <> s

-- | Write a @.sym@ file to disk.
writeSymFile :: FilePath -> Map Text Word16 -> IO ()
writeSymFile path = TIO.writeFile path . formatSym
