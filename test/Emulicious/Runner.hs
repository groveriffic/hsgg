{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings  #-}
module Emulicious.Runner
  ( ContainerID
  , withEmulicious
  , testTimeoutSeconds
  , pressButton
  , captureScreen
  ) where

import           Control.Concurrent          (threadDelay)
import           Control.Exception           (finally, IOException, try, bracket)
import           Data.Char                   (isSpace)
import           Data.List                   (dropWhileEnd)
import           System.Directory            (getHomeDirectory, makeAbsolute)
import           System.Exit                 (ExitCode (..))
import           System.FilePath             ((</>), takeDirectory, takeFileName)
import           System.Process              (callProcess, readProcess,
                                              readProcessWithExitCode)
import           System.Timeout              (timeout)
import qualified Emulicious.DAP              as DAP

type ContainerID = String

dapPort :: Int
dapPort = 58870

testTimeoutSeconds :: Int
testTimeoutSeconds = 15

withEmulicious :: FilePath -> (ContainerID -> DAP.DAPClient -> IO a) -> IO a
withEmulicious romPath action =
  bracket (spawnEmu romPath) killEmu $ \(cid, containerRomPath) -> do
    result <- timeout (testTimeoutSeconds * 1_000_000) (run cid containerRomPath)
    case result of
      Just v  -> pure v
      Nothing -> fail $ "withEmulicious: test timed out after "
                          <> show testTimeoutSeconds <> "s"
  where
    run cid containerRomPath = do
      client <- retryHandshake dapPort 100
      DAP.launch client containerRomPath
      _ <- DAP.waitForEvent client "initialized"
      action cid client `finally`
        (try (DAP.disconnect client) :: IO (Either IOException ()))

-- | Inject a keypress into the running Emulicious window.
-- Key names follow xdotool conventions: "a", "s", "Return", etc.
pressButton :: ContainerID -> String -> IO ()
pressButton cid key = do
  winId <- retryFindWindow cid 50
  dockerExec cid ["xdotool", "key", "--window", winId, key]

-- | Capture a screenshot of the Emulicious window and write it to @destPath@.
captureScreen :: ContainerID -> FilePath -> IO ()
captureScreen cid destPath = do
  dockerExec cid ["scrot", "/tmp/screen.png"]
  callProcess "docker" ["cp", cid <> ":/tmp/screen.png", destPath]

-- ---------------------------------------------------------------------------
-- Internal
-- ---------------------------------------------------------------------------

spawnEmu :: FilePath -> IO (ContainerID, FilePath)
spawnEmu romPath = do
  absRomPath <- makeAbsolute romPath
  home       <- getHomeDirectory
  let jar              = home </> "Emulicious" </> "Emulicious.jar"
      romDir           = takeDirectory absRomPath
      romFile          = takeFileName absRomPath
      containerRomPath = "/roms/" <> romFile
  cid <- trim <$> readProcess "docker"
    [ "run", "--rm", "-d"
    , "-p", show dapPort <> ":" <> show dapPort
    , "-v", romDir <> ":/roms:ro"
    , "-v", jar   <> ":/emulicious/Emulicious.jar:ro"
    , "hsgg-emulicious"
    , containerRomPath
    ] ""
  pure (cid, containerRomPath)

killEmu :: (ContainerID, FilePath) -> IO ()
killEmu (cid, _) = do
  _ <- (try (readProcess "docker" ["stop", "--timeout", "2", cid] "")
          :: IO (Either IOException String))
  pure ()

dockerExec :: ContainerID -> [String] -> IO ()
dockerExec cid args =
  callProcess "docker" (["exec", "-e", "DISPLAY=:99", cid] <> args)

-- | Retry until xdotool finds a window owned by PID 1 (Emulicious in the
-- container, which becomes PID 1 via exec in the entrypoint).
retryFindWindow :: ContainerID -> Int -> IO String
retryFindWindow _ 0 =
  fail "pressButton: timed out waiting for Emulicious window"
retryFindWindow cid attempts = do
  (rc, out, _) <- readProcessWithExitCode "docker"
    ["exec", "-e", "DISPLAY=:99", cid, "xdotool", "search", "--pid", "1"] ""
  case (rc, lines out) of
    (ExitSuccess, (w:_)) -> pure (trim w)
    _ -> do
      threadDelay 100_000
      retryFindWindow cid (attempts - 1)

-- | Connect to the DAP port and run an `initialize` request. On Docker
-- Desktop the host-side forwarder accepts TCP before the container's DAP
-- server is bound, so a successful TCP connect doesn't mean the adapter
-- is ready. Retry the full handshake (connect + initialize) until it
-- succeeds.
retryHandshake :: Int -> Int -> IO DAP.DAPClient
retryHandshake port attempts
  | attempts <= 0 =
      fail "withEmulicious: timed out waiting for Emulicious DAP handshake"
  | otherwise = do
      result <- try attempt :: IO (Either IOException DAP.DAPClient)
      case result of
        Right client -> pure client
        Left _       -> do
          threadDelay 200_000
          retryHandshake port (attempts - 1)
  where
    attempt = do
      client <- DAP.connect port
      DAP.initialize client
      pure client

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace
