{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings  #-}
module Emulicious.Assert
  ( runROM
  , runROMInteractive
  , runROMSession
  , assertRAM
  , assertRAMRange
  , ContainerID
  , pressButton
  , captureScreen
  ) where

import           Control.Concurrent     (threadDelay)
import           Data.Bits              ((.&.), shiftR)
import qualified Data.ByteString        as BS
import           Data.Word              (Word16, Word8)
import           System.FilePath        ((</>))
import           System.Directory       (createDirectoryIfMissing)
import           Test.Hspec

import           Z80
import           Emulicious.DAP         (DAPClient)
import qualified Emulicious.DAP         as DAP
import           Emulicious.Runner      (ContainerID, withEmulicious,
                                         pressButton, captureScreen)

-- | Assemble @program@, run it in Emulicious until HALT, then assert.
runROM :: String -> Asm () -> (DAPClient -> IO ()) -> IO ()
runROM name program assertions = do
  rom <- either (fail . ("Assembler error: " <>) . show) pure
                (assemble defaultROMConfig program)
  createDirectoryIfMissing True "tmp"
  let romPath = "tmp" </> "test-" <> name <> ".gg"
  BS.writeFile romPath rom
  withEmulicious romPath $ \_cid client -> do
    threadDelay 300_000
    _ <- DAP.pauseExecution client
    assertions client

-- | Like 'runROM' but runs @setup@ while the ROM is executing before
-- waiting for HALT. The setup callback receives a 'ContainerID' for
-- calling 'pressButton' and 'captureScreen'.
runROMInteractive :: String -> Asm ()
                  -> (ContainerID -> DAPClient -> IO ())
                  -> (DAPClient -> IO ())
                  -> IO ()
runROMInteractive name program setup assertions = do
  rom <- either (fail . ("Assembler error: " <>) . show) pure
                (assemble defaultROMConfig program)
  createDirectoryIfMissing True "tmp"
  let romPath = "tmp" </> "test-" <> name <> ".gg"
  BS.writeFile romPath rom
  withEmulicious romPath $ \cid client -> do
    setup cid client
    threadDelay 300_000
    _ <- DAP.pauseExecution client
    assertions client

-- | Assemble @program@ and start Emulicious, then hand the running
-- session to @action@. The ROM is executing on entry; @action@ is
-- responsible for any pause/inspect/resume orchestration via the
-- 'DAPClient'. Use this for tests that need finer control than 'runROM'
-- (e.g. multi-step input scenarios).
runROMSession :: String -> Asm ()
              -> (ContainerID -> DAPClient -> IO ())
              -> IO ()
runROMSession name program action = do
  rom <- either (fail . ("Assembler error: " <>) . show) pure
                (assemble defaultROMConfig program)
  createDirectoryIfMissing True "tmp"
  let romPath = "tmp" </> "test-" <> name <> ".gg"
  BS.writeFile romPath rom
  withEmulicious romPath action

-- | Assert that the byte at @addr@ equals @expected@.
assertRAM :: DAPClient -> Word16 -> Word8 -> Expectation
assertRAM client addr expected = do
  bs <- DAP.readMemory client addr 1
  case BS.uncons bs of
    Just (actual, _) -> actual `shouldBe` expected
    Nothing          -> expectationFailure $
      "readMemory returned empty for address 0x" <> showHex16 addr

-- | Assert a contiguous run of bytes starting at @addr@.
assertRAMRange :: DAPClient -> Word16 -> [Word8] -> Expectation
assertRAMRange client addr expected = do
  bs <- DAP.readMemory client addr (length expected)
  BS.unpack bs `shouldBe` expected

showHex16 :: Word16 -> String
showHex16 w =
  [ hexNibble (w `shiftR` 12)
  , hexNibble ((w `shiftR` 8)  .&. 0xF)
  , hexNibble ((w `shiftR` 4)  .&. 0xF)
  , hexNibble (w               .&. 0xF)
  ]
  where
    hexNibble n
      | n < 10    = toEnum (fromEnum '0' + fromIntegral n)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral n - 10)
