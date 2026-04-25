{-# LANGUAGE OverloadedStrings #-}
-- | Game Gear VDP (Video Display Processor) interface.
--
-- The GG VDP is accessed through two I/O ports:
--   * 'portVDPData'  (0xBE) — read/write data (VRAM or CRAM)
--   * 'portVDPCtrl'  (0xBF) — write command/address, read status
--
-- To address VRAM or CRAM, write a 2-byte command to the control port:
--   1. Low byte of the target address
--   2. High byte ORed with a command flag:
--        0x40 = VRAM write
--        0x00 = VRAM read
--        0x80 = VDP register write  (high byte = 0x80 | reg#)
--        0xC0 = CRAM write
--
-- After setting the address, write or read data through 'portVDPData';
-- the address register auto-increments after each access.
--
-- === Game Gear color format
--
-- Each CRAM entry occupies 2 bytes (little-endian):
--
-- @
--   Low  byte:  GGGGRRRRR  (bits 7:4 = green, bits 3:0 = red)
--   High byte:  0000BBBB   (bits 3:0 = blue)
-- @
--
-- Each channel is 4 bits (0–15).
module Z80.Platform.GameGear
  ( -- * VDP I/O ports
    portVDPData
  , portVDPCtrl

    -- * GG color
  , GGColor (..)
  , ggColor
    -- ** Predefined colors
  , black, white
  , red, green, blue
  , cyan, magenta, yellow

    -- * VDP register access
  , vdpWriteReg

    -- * Palette (CRAM) access
  , setPaletteEntry
  , setPalette

    -- * Tiles
  , Tile
  , tile
  , tileBytes
  , loadTile
  , loadTiles

    -- * Name table
  , nameTableBase
  , fillNameTable

    -- * Sprite Attribute Table (SAT)
  , satYTable
  , satXNTable
  , vdpInit
  , enableDisplay
  , initSpriteEntry
  , terminateSprites
  , updateSpriteY
  , updateSpriteX

    -- * VBlank sync
  , waitVBlank
  ) where

import Data.Bits  (shiftL, shiftR, (.&.), (.|.))
import Data.Word  (Word8, Word16)

import Z80.Types   (Reg8 (A, B, C), Reg16 (AF, HL), AddrExpr (LabelRef), Condition (Z))
import Z80.Asm     (Asm, freshLabel, rawLabel, db)
import Z80.Opcodes (ldi, outA, inA, ld16, otir, jp, push, pop, bit, jr_cc)

-- ---------------------------------------------------------------------------
-- VDP port constants
-- ---------------------------------------------------------------------------

portVDPData :: Word8
portVDPData = 0xBE

portVDPCtrl :: Word8
portVDPCtrl = 0xBF

-- ---------------------------------------------------------------------------
-- Color type
-- ---------------------------------------------------------------------------

-- | A 12-bit Game Gear color.  Each channel is in the range 0–15.
data GGColor = GGColor
  { colorR :: Word8  -- ^ Red   (0–15)
  , colorG :: Word8  -- ^ Green (0–15)
  , colorB :: Word8  -- ^ Blue  (0–15)
  } deriving (Show, Eq)

-- | Smart constructor — clamps each channel to 0–15.
ggColor :: Word8 -> Word8 -> Word8 -> GGColor
ggColor r g b = GGColor (r .&. 0xF) (g .&. 0xF) (b .&. 0xF)

-- | Two-byte CRAM encoding: (low, high)
--
-- @low  = (green << 4) | red@
-- @high = blue@
colorBytes :: GGColor -> (Word8, Word8)
colorBytes (GGColor r g b) = ((g `shiftL` 4) .|. r, b .&. 0xF)

-- ---------------------------------------------------------------------------
-- Predefined colors
-- ---------------------------------------------------------------------------

black, white, red, green, blue, cyan, magenta, yellow :: GGColor
black   = GGColor  0  0  0
white   = GGColor 15 15 15
red     = GGColor 15  0  0
green   = GGColor  0 15  0
blue    = GGColor  0  0 15
cyan    = GGColor  0 15 15
magenta = GGColor 15  0 15
yellow  = GGColor 15 15  0

-- ---------------------------------------------------------------------------
-- VDP register write
-- ---------------------------------------------------------------------------

-- | Emit code to write @value@ to VDP register @regNum@ (0–10).
--
-- Destroys A.
vdpWriteReg :: Word8 -> Word8 -> Asm ()
vdpWriteReg regNum value = do
  ldi A value
  outA portVDPCtrl
  ldi A (0x80 .|. (regNum .&. 0x0F))
  outA portVDPCtrl

-- ---------------------------------------------------------------------------
-- Palette (CRAM) access
-- ---------------------------------------------------------------------------

-- | Emit code to set a single palette entry.
--
-- @setPaletteEntry index color@ writes @color@ to CRAM entry @index@
-- (0–31, where 0–15 are the background palette and 16–31 the sprite palette).
--
-- Destroys A.
setPaletteEntry :: Word8 -> GGColor -> Asm ()
setPaletteEntry idx color = setPalette idx [color]

-- | Emit code to write a list of colors into CRAM starting at @startIndex@.
--
-- The VDP address auto-increments after each byte, so all colors are
-- written in a single sequential burst.
--
-- Destroys A.
setPalette :: Word8 -> [GGColor] -> Asm ()
setPalette startIndex colors = do
  -- Set CRAM write address (each entry = 2 bytes, so addr = index * 2)
  let cramAddr = startIndex * 2
  ldi A cramAddr
  outA portVDPCtrl
  ldi A 0xC0          -- CRAM write command; high addr bits are always 0 (max addr = 63)
  outA portVDPCtrl
  -- Stream color bytes; address auto-increments
  mapM_ writeColor colors
  where
    writeColor color = do
      let (lo, hi) = colorBytes color
      ldi A lo
      outA portVDPData
      ldi A hi
      outA portVDPData

-- ---------------------------------------------------------------------------
-- Tiles
-- ---------------------------------------------------------------------------
--
-- Each tile is 8×8 pixels; each pixel is a 4-bit palette index (0–15).
-- The VDP stores tiles in a 4-plane (bitplane) format: for each row of 8
-- pixels, four bytes are written — one per bit of the palette index.
--
-- Plane byte layout for a row [p0..p7]:
--   byte 0 (plane 0) = bit0 of each pixel, p0 in MSB
--   byte 1 (plane 1) = bit1 of each pixel, p0 in MSB
--   byte 2 (plane 2) = bit2 of each pixel, p0 in MSB
--   byte 3 (plane 3) = bit3 of each pixel, p0 in MSB
--
-- Each tile = 8 rows × 4 bytes = 32 bytes.

-- | An 8×8 tile: a list of 8 rows, each a list of 8 palette indices (0–15).
newtype Tile = Tile [[Word8]]
  deriving (Show, Eq)

-- | Smart constructor.  Exactly 8 rows of 8 pixels are required;
-- values are clamped to 0–15.
tile :: [[Word8]] -> Tile
tile rows
  | length rows /= 8 || any ((/= 8) . length) rows
      = error "tile: requires exactly 8 rows of 8 pixels"
  | otherwise = Tile (map (map (.&. 0xF)) rows)

-- | Encode a tile to 32 bytes in VDP bitplane format.
tileBytes :: Tile -> [Word8]
tileBytes (Tile rows) = concatMap rowPlanes rows

rowPlanes :: [Word8] -> [Word8]
rowPlanes pixels = [planeByte b | b <- [0..3]]
  where
    planeByte bitN =
      foldl' (\acc (i, p) -> acc .|. (((p `shiftR` bitN) .&. 1) `shiftL` (7 - i)))
             0
             (zip [0..] pixels)

-- | Emit code to load a single tile into VRAM at tile index @idx@.
-- Destroys A, B, C, HL.
loadTile :: Word16 -> Tile -> Asm ()
loadTile idx t = loadTiles idx [t]

-- | Emit code to load a list of tiles into VRAM starting at tile index @startIdx@.
--
-- Tile bytes are stored inline in the ROM image; at runtime they are
-- bulk-copied to VRAM using the Z80 @OTIR@ instruction (256 bytes per pass).
--
-- Destroys A, B, C, HL.
loadTiles :: Word16 -> [Tile] -> Asm ()
loadTiles startIdx tiles = do
  let vramAddr = startIdx * 32
      bytes    = concatMap tileBytes tiles

  -- Labels for the inline data block
  dataLbl  <- freshLabel "_tileData"
  afterLbl <- freshLabel "_tileAfter"

  -- Jump over the inline data
  jp (LabelRef afterLbl)
  rawLabel dataLbl
  db bytes
  rawLabel afterLbl

  -- Set VRAM write address
  ldi A (fromIntegral (vramAddr .&. 0xFF))
  outA portVDPCtrl
  ldi A (0x40 .|. fromIntegral (vramAddr `shiftR` 8 .&. 0x3F))
  outA portVDPCtrl

  -- HL = start of tile data; C = VDP data port (preserved by OTIR)
  ld16 HL (LabelRef dataLbl)
  ldi C portVDPData

  -- Copy in chunks of up to 256 bytes using OTIR.
  -- B=0 means 256 iterations; OTIR auto-increments HL each pass.
  mapM_ emitChunk (chunkSizes (length bytes))
  where
    emitChunk n = do
      ldi B (fromIntegral n .&. 0xFF)  -- 256 encodes as 0
      otir

-- | Split a total byte count into a list of chunk sizes, each ≤ 256.
chunkSizes :: Int -> [Int]
chunkSizes 0 = []
chunkSizes n = let c = min n 256 in c : chunkSizes (n - c)

-- ---------------------------------------------------------------------------
-- Name table
-- ---------------------------------------------------------------------------
--
-- The name table (background map) lives in VRAM at 0x3800 (set by VDP reg 2).
-- It is 32 columns × 28 rows = 896 entries; each entry is 2 bytes (LE):
--   byte 0: low 8 bits of tile index
--   byte 1: bit 0 = tile index bit 8, bit 3 = palette (0=BG, 1=sprite),
--            bit 4 = H-flip, bit 5 = V-flip, bit 6 = priority
-- The GG visible area covers columns 0–19, rows 0–17 (160×144 px).

nameTableBase :: Word16
nameTableBase = 0x3800

-- | Fill the entire 32×28 name table with a single tile.
--
-- @fillNameTable tileIdx flags@ writes @flags@ as the high byte of every
-- entry (controls palette, flip, priority).  Pass 0 for a plain background
-- tile using palette 0.
--
-- Destroys A, B, C, HL.
fillNameTable :: Word16 -> Word8 -> Asm ()
fillNameTable tileIdx flags = do
  let loEntry = fromIntegral (tileIdx .&. 0xFF) :: Word8
      hiEntry = flags .|. fromIntegral ((tileIdx `shiftR` 8) .&. 0x01)
      bytes   = concatMap (\_ -> [loEntry, hiEntry]) [(1 :: Int)..32*28]

  dataLbl  <- freshLabel "_ntData"
  afterLbl <- freshLabel "_ntAfter"

  jp (LabelRef afterLbl)
  rawLabel dataLbl
  db bytes
  rawLabel afterLbl

  setVRAMAddr nameTableBase
  ld16 HL (LabelRef dataLbl)
  ldi C portVDPData
  mapM_ emitChunk (chunkSizes (length bytes))
  where
    emitChunk n = do
      ldi B (fromIntegral n .&. 0xFF)
      otir

-- ---------------------------------------------------------------------------
-- Sprite Attribute Table (SAT)
-- ---------------------------------------------------------------------------
--
-- The SAT has two sections in VRAM:
--
--   satYTable  (0x3F00–0x3F3F): one Y-coordinate byte per sprite (64 sprites).
--     Writing 0xD0 to an entry terminates sprite processing for that frame.
--
--   satXNTable (0x3F80–0x3FFF): two bytes per sprite — X position then tile number.
--     Entry for sprite N: X at (satXNTable + N*2), tile at (satXNTable + N*2 + 1).
--
-- The SAT base address is controlled by VDP register 5.
-- With reg5 = 0xFF the SAT Y-table is at 0x3F00.

satYTable :: Word16
satYTable = 0x3F00

satXNTable :: Word16
satXNTable = 0x3F80

-- ---------------------------------------------------------------------------
-- VDP initialisation
-- ---------------------------------------------------------------------------

-- | Minimal VDP initialisation for Game Gear mode 4 with display blanked.
-- Sets the name table at 0x3800, SAT at 0x3F00, sprite tiles at 0x0000.
-- Call 'enableDisplay' after all VRAM data has been loaded.
--
-- Destroys A.
vdpInit :: Asm ()
vdpInit = do
  vdpWriteReg 0 0x04   -- mode 4, no H-sync IRQ
  vdpWriteReg 1 0x00   -- display off (blanked)
  vdpWriteReg 2 0xFF   -- name table at 0x3800
  vdpWriteReg 3 0xFF   -- reserved
  vdpWriteReg 4 0xFF   -- reserved
  vdpWriteReg 5 0xFF   -- SAT at 0x3F00
  vdpWriteReg 6 0xFB   -- sprite tile base at 0x0000
  vdpWriteReg 7 0x00   -- backdrop = palette entry 0

-- | Enable the display (VDP register 1, display-active + VBlank-IRQ bits).
-- Destroys A.
enableDisplay :: Asm ()
enableDisplay = vdpWriteReg 1 0xE0

-- ---------------------------------------------------------------------------
-- SAT helpers (all destroy A; sprite index is a compile-time constant)
-- ---------------------------------------------------------------------------

-- | Emit code to set a VDP VRAM write address. Destroys A.
setVRAMAddr :: Word16 -> Asm ()
setVRAMAddr addr = do
  ldi A (fromIntegral (addr .&. 0xFF))
  outA portVDPCtrl
  ldi A (0x40 .|. fromIntegral (addr `shiftR` 8 .&. 0x3F))
  outA portVDPCtrl

-- | Write a sprite's initial entry into the SAT.
-- @initSpriteEntry idx x y tileNum@
-- Destroys A.
initSpriteEntry :: Word8 -> Word8 -> Word8 -> Word8 -> Asm ()
initSpriteEntry idx x y tileNum = do
  -- Write Y to the Y-table
  setVRAMAddr (satYTable + fromIntegral idx)
  ldi A y
  outA portVDPData
  -- Write X then tile to the X/tile-table (VDP address auto-increments)
  setVRAMAddr (satXNTable + fromIntegral idx * 2)
  ldi A x
  outA portVDPData
  ldi A tileNum
  outA portVDPData

-- | Write 0xD0 (end-of-sprites sentinel) to SAT Y-table entry @idx@.
-- All sprites from @idx@ onward will be ignored by the VDP.
-- Destroys A.
terminateSprites :: Word8 -> Asm ()
terminateSprites idx = do
  setVRAMAddr (satYTable + fromIntegral idx)
  ldi A 0xD0
  outA portVDPData

-- | Emit code to write the value currently in A to sprite @idx@'s Y position
-- in the SAT.  Saves and restores A around the address setup. Destroys flags.
updateSpriteY :: Word8 -> Asm ()
updateSpriteY idx = do
  push AF
  setVRAMAddr (satYTable + fromIntegral idx)
  pop AF
  outA portVDPData

-- | Emit code to write the value currently in A to sprite @idx@'s X position
-- in the SAT.  Saves and restores A around the address setup. Destroys flags.
updateSpriteX :: Word8 -> Asm ()
updateSpriteX idx = do
  push AF
  setVRAMAddr (satXNTable + fromIntegral idx * 2)
  pop AF
  outA portVDPData

-- ---------------------------------------------------------------------------
-- VBlank synchronisation
-- ---------------------------------------------------------------------------

-- | Emit an inline VBlank poll loop.
-- Spins reading the VDP status port (0xBF) until bit 7 (frame interrupt flag)
-- is set, indicating the start of vertical blank.  Reading the port clears
-- the flag automatically.  Destroys A.
waitVBlank :: Asm ()
waitVBlank = do
  lbl <- freshLabel "_vblank"
  rawLabel lbl
  inA portVDPCtrl
  bit 7 A
  jr_cc Z (LabelRef lbl)
