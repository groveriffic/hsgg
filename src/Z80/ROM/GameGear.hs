module Z80.ROM.GameGear
  ( ROMConfig (..)
  , ROMSize (..)
  , GGRegion (..)
  , ROMError (..)
  , defaultROMConfig
  , romSizeBytes
  , buildROM
  ) where

import Data.Bits        (shiftL, shiftR, (.&.), (.|.))
import Data.Word        (Word8, Word16, Word32)
import qualified Data.ByteString as BS

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

data ROMSize
  = ROM8K | ROM16K | ROM32K | ROM64K | ROM128K | ROM256K | ROM512K
  deriving (Show, Eq, Ord, Enum, Bounded)

data GGRegion
  = GGJapan         -- 0x50
  | GGExport        -- 0x60
  | GGInternational -- 0x70
  deriving (Show, Eq)

data ROMConfig = ROMConfig
  { romSize      :: ROMSize
  , romRegion    :: GGRegion
  , romProductId :: Word32   -- BCD product code (up to 5 digits)
  , romVersion   :: Word8    -- 0..15
  , romOrigin    :: Word16   -- assembly origin (usually 0x0000)
  }

defaultROMConfig :: ROMConfig
defaultROMConfig = ROMConfig
  { romSize      = ROM32K
  , romRegion    = GGExport
  , romProductId = 0
  , romVersion   = 0
  , romOrigin    = 0x0000
  }

romSizeBytes :: ROMSize -> Int
romSizeBytes ROM8K   =    8 * 1024
romSizeBytes ROM16K  =   16 * 1024
romSizeBytes ROM32K  =   32 * 1024
romSizeBytes ROM64K  =   64 * 1024
romSizeBytes ROM128K =  128 * 1024
romSizeBytes ROM256K =  256 * 1024
romSizeBytes ROM512K =  512 * 1024

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

data ROMError
  = CodeTooLarge Int Int   -- code size, max size
  | CodeOverlapsHeader     -- code bytes reach into the Sega header area
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- ROM layout constants
-- ---------------------------------------------------------------------------

-- Sega header lives at 0x7FF0..0x7FFF (last 16 bytes of the first 32 KB)
headerOffset :: Int
headerOffset = 0x7FF0

checksumOffset :: Int
checksumOffset = 0x7FFA  -- 2 bytes (little-endian Word16)

-- ---------------------------------------------------------------------------
-- Build ROM image
-- ---------------------------------------------------------------------------

buildROM :: ROMConfig -> BS.ByteString -> Either ROMError BS.ByteString
buildROM cfg code = do
  let totalSize  = romSizeBytes (romSize cfg)
      codeLen    = BS.length code

  -- Guard: code must not overflow ROM
  if codeLen > totalSize
    then Left (CodeTooLarge codeLen totalSize)
    else Right ()

  -- Guard: code must not clobber the Sega header area (for ROMs >= 32 KB)
  if totalSize >= 0x8000 && codeLen > headerOffset
    then Left CodeOverlapsHeader
    else Right ()

  -- Pad code to full ROM size with 0xFF
  let padded = code <> BS.replicate (totalSize - codeLen) 0xFF

  -- Write Sega header at 0x7FF0
  let withHeader = writeHeader cfg padded

  -- Compute and write checksum
  let withChecksum = writeChecksum (romSize cfg) withHeader

  pure withChecksum

-- ---------------------------------------------------------------------------
-- Sega header
-- ---------------------------------------------------------------------------
--
-- Offset  Bytes  Content
--   0x00    8    "TMR SEGA"
--   0x08    2    0x20 0x20  (spaces / reserved)
--   0x0A    2    checksum (little-endian) -- written later
--   0x0C    4    product code (BCD) + version + region/size nibble

writeHeader :: ROMConfig -> BS.ByteString -> BS.ByteString
writeHeader cfg rom =
  let hdr = headerBytes cfg
      (before, rest) = BS.splitAt headerOffset rom
      after = BS.drop (BS.length hdr) rest
  in before <> hdr <> after

headerBytes :: ROMConfig -> BS.ByteString
headerBytes cfg = BS.pack
  [ 0x54, 0x4D, 0x52, 0x20, 0x53, 0x45, 0x47, 0x41  -- "TMR SEGA"
  , 0x20, 0x20                                          -- reserved (spaces)
  , 0x00, 0x00                                          -- checksum placeholder
  , prodLo, prodMid                                     -- product code BCD
  , versionNibble .|. (prodHi .&. 0x0F)                -- version | prod high nibble
  , regionByte cfg .|. romSizeNibble (romSize cfg)      -- region | size
  ]
  where
    p           = romProductId cfg
    prodLo      = fromIntegral (p .&. 0xFF)
    prodMid     = fromIntegral ((p `shiftR` 8) .&. 0xFF)
    prodHi      = fromIntegral ((p `shiftR` 16) .&. 0x0F)
    versionNibble = (romVersion cfg .&. 0x0F) `shiftL` 4

regionByte :: ROMConfig -> Word8
regionByte cfg = case romRegion cfg of
  GGJapan         -> 0x50
  GGExport        -> 0x60
  GGInternational -> 0x70

romSizeNibble :: ROMSize -> Word8
romSizeNibble ROM8K   = 0x0A
romSizeNibble ROM16K  = 0x0B
romSizeNibble ROM32K  = 0x0C
romSizeNibble ROM64K  = 0x0E
romSizeNibble ROM128K = 0x0F
romSizeNibble ROM256K = 0x00
romSizeNibble ROM512K = 0x01

-- ---------------------------------------------------------------------------
-- Checksum
-- ---------------------------------------------------------------------------
-- Sum of all bytes from 0x0000 to 0x7FF9 (i.e. excluding the 2 checksum bytes).
-- For ROMs larger than 32 KB, bytes from 0x8000 onward also contribute.

writeChecksum :: ROMSize -> BS.ByteString -> BS.ByteString
writeChecksum size rom =
  let csum   = computeChecksum size rom
      csumLo = fromIntegral (csum .&. 0xFF)  :: Word8
      csumHi = fromIntegral (csum `shiftR` 8) :: Word8
      (before, rest) = BS.splitAt checksumOffset rom
      after          = BS.drop 2 rest
  in before <> BS.pack [csumLo, csumHi] <> after

computeChecksum :: ROMSize -> BS.ByteString -> Word16
computeChecksum size rom =
  let region1 = BS.take checksumOffset rom          -- 0x0000..0x7FF9
      region2 = if romSizeBytes size > 0x8000
                  then BS.drop 0x8000 rom            -- 0x8000..end
                  else BS.empty
      sumBS bs = BS.foldl' (\acc b -> acc + fromIntegral b) (0 :: Word16) bs
  in sumBS region1 + sumBS region2

