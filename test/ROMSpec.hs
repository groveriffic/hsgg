{-# LANGUAGE OverloadedStrings #-}
module ROMSpec (spec) where

import Test.Hspec
import Z80
import Emulicious.Assert

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
