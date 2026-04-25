{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings  #-}
module Emulicious.Runner
  ( withEmulicious
  , emuliciousJar
  , testTimeoutSeconds
  ) where

import           Control.Concurrent     (threadDelay)
import           Control.Exception      (bracket, finally, IOException, try)
import           System.Directory       (getHomeDirectory)
import           System.Exit            (ExitCode (..))
import           System.FilePath        ((</>))
import           System.Process         (createProcess, proc, terminateProcess,
                                         getPid, waitForProcess,
                                         CreateProcess (..), create_group)
import           System.Posix.Process   (getProcessGroupIDOf)
import           System.Posix.Signals   (signalProcessGroup, killProcess)
import           System.Posix.Types     (ProcessGroupID)
import           System.Timeout         (timeout)
import qualified Emulicious.DAP         as DAP

emuliciousJar :: IO FilePath
emuliciousJar = do
  home <- getHomeDirectory
  pure $ home </> "Emulicious" </> "Emulicious.jar"

dapPort :: Int
dapPort = 58870

testTimeoutSeconds :: Int
testTimeoutSeconds = 15

withEmulicious :: FilePath -> (DAP.DAPClient -> IO a) -> IO a
withEmulicious romPath action =
  bracket spawnEmu killEmu $ \_ph -> do
    result <- timeout (testTimeoutSeconds * 1_000_000) run
    case result of
      Just v  -> pure v
      Nothing -> fail $ "withEmulicious: test timed out after "
                          <> show testTimeoutSeconds <> "s"
  where
    run = do
      client <- retryConnect dapPort 100
      DAP.initialize client
      DAP.launch client romPath
      _ <- DAP.waitForEvent client "initialized"
      action client `finally`
        (try (DAP.disconnect client) :: IO (Either IOException ()))

    -- create_group=True puts Emulicious in its own process group so we can
    -- kill it without sending SIGKILL to our own test process.
    spawnEmu = do
      jar <- emuliciousJar
      (_, _, _, ph) <- createProcess
        (proc "java" ["-jar", jar, "-remotedebug", show dapPort, romPath])
        { create_group = True }
      pure ph

    killEmu ph = do
      mpid <- getPid ph
      case mpid of
        Nothing  -> terminateProcess ph
        Just pid -> do
          pgid <- try (getProcessGroupIDOf pid)
                    :: IO (Either IOException ProcessGroupID)
          case pgid of
            Right gid -> do
              signalProcessGroup killProcess gid
              _ <- try (waitForProcess ph) :: IO (Either IOException ExitCode)
              pure ()
            Left _    -> terminateProcess ph

retryConnect :: Int -> Int -> IO DAP.DAPClient
retryConnect port attempts
  | attempts <= 0 = fail "withEmulicious: timed out waiting for Emulicious to start"
  | otherwise = do
      result <- try (DAP.connect port) :: IO (Either IOException DAP.DAPClient)
      case result of
        Right client -> pure client
        Left _       -> do
          threadDelay 100_000
          retryConnect port (attempts - 1)
