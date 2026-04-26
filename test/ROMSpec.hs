{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
module ROMSpec (spec) where

import           Control.Concurrent (threadDelay)
import           Control.Monad      (forM_)
import           Data.Word          (Word16)
import           Test.Hspec
import           Z80
import           Emulicious.Assert
import qualified Emulicious.DAP     as DAP

spec :: Spec
spec = do
  describe "RAM writes" $ do
    it "LD (nn), A stores a byte in RAM" $
      runROM "ld-nn-a" (do
        org 0x0000
        di
        ld16n SP 0xDFF0
        ldi A 0x42
        stnn (Lit 0xC000)
        halt) $ \client ->
          assertRAM client 0xC000 0x42

    it "LD (nn), A stores 0xFF in RAM" $
      runROM "ld-nn-a-ff" (do
        org 0x0000
        di
        ld16n SP 0xDFF0
        ldi A 0xFF
        stnn (Lit 0xC001)
        halt) $ \client ->
          assertRAM client 0xC001 0xFF

  describe "Arithmetic" $ do
    it "INC A increments register A" $
      runROM "inc-a" (do
        org 0x0000
        di
        ld16n SP 0xDFF0
        ldi A 0x10
        inc A
        stnn (Lit 0xC000)
        halt) $ \client ->
          assertRAM client 0xC000 0x11

    it "ADD A, n produces correct result" $
      runROM "add-a-n" (do
        org 0x0000
        di
        ld16n SP 0xDFF0
        ldi A 0x03
        addAn 0x05
        stnn (Lit 0xC000)
        halt) $ \client ->
          assertRAM client 0xC000 0x08

  describe "Input handling" $
    it "writes a per-button marker when each input is pressed" $
      runROMSession "input-composite" inputPollROM $ \cid client -> do
        threadDelay 500_000  -- let the ROM zero markers and start polling
        forM_ (zip [(1 :: Int) ..] inputs) $ \(i, (_, key, _)) -> do
          pressButton cid key
          threadDelay 250_000
          _ <- DAP.pauseExecution client
          forM_ (zip [(1 :: Int) ..] inputs) $ \(j, (_, _, addr)) ->
            assertRAM client addr (if j <= i then 1 else 0)
          DAP.continueExecution client

-- | (label, xdotool key name, RAM marker address) — order matters: the
-- test asserts that after the @i@-th press the first @i@ markers are
-- set and the rest are still zero.
inputs :: [(String, String, Word16)]
inputs =
  [ ("Up",    "Up",     0xC000)
  , ("Down",  "Down",   0xC001)
  , ("Left",  "Left",   0xC002)
  , ("Right", "Right",  0xC003)
  , ("B1",    "a",      0xC004)
  , ("B2",    "s",      0xC005)
  , ("Start", "Return", 0xC006)
  ]

-- | Polls the Game Gear input ports forever; whenever a button is held
-- (active-low bit), writes @0x01@ to that button's marker address.
-- Markers are zeroed once at startup and never cleared, so the host
-- side observes a monotonic record of which buttons have been seen.
inputPollROM :: Asm ()
inputPollROM = do
  org 0x0000
  di
  ld16n SP 0xDFF0
  ldi A 0
  mapM_ (\(_, _, addr) -> stnn (Lit addr)) inputs

  loopL <- freshLabel "poll"
  rawLabel loopL

  let addrs = [a | (_, _, a) <- inputs]

  -- Port 0xDC: D-pad (bits 0-3) + buttons 1/2 (bits 4-5)
  inA 0xDC
  ld B A
  mapM_ (uncurry markIfPressed) (zip [0 .. 5] (take 6 addrs))

  -- Port 0x00 bit 7: Game Gear START button
  inA 0x00
  ld B A
  mapM_ (markIfPressed 7) (drop 6 addrs)

  jr (LabelRef loopL)
  where
    markIfPressed bitN addr = do
      skipL <- freshLabel "skip"
      bit bitN B
      jr_cc NZ (LabelRef skipL)
      ldi A 1
      stnn (Lit addr)
      rawLabel skipL
