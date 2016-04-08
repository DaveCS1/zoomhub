{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module ZoomHub.Main (main) where

import           Control.Concurrent                   (forkIO)
import           Control.Exception                    (tryJust)
import           Control.Monad                        (forM_, guard, unless)
import           Data.Aeson                           ((.=))
import qualified Data.ByteString.Char8                as BC
import qualified Data.ByteString.Lazy                 as BL
import           Data.Default                         (def)
import           Data.Maybe                           (fromJust, fromMaybe)
import           Data.Text                            (Text)
import           Database.SQLite.Simple               (open)
import           Network.BSD                          (getHostName)
import           Network.URI                          (parseAbsoluteURI)
import           Network.Wai.Handler.Warp             (run)
import           Network.Wai.Middleware.RequestLogger (OutputFormat (CustomOutputFormatWithDetails),
                                                       mkRequestLogger,
                                                       outputFormat)
import           System.Directory                     (doesFileExist,
                                                       getCurrentDirectory)
import           System.Environment                   (lookupEnv)
import           System.Envy                          (decodeEnv)
import           System.FilePath                      ((</>))
import           System.IO.Error                      (isDoesNotExistError)
import           Web.Hashids                          (encode, hashidsSimple)

import           ZoomHub.API                          (app)
import           ZoomHub.Config                       (Config (..), ExistingContentStatus (ProcessExistingContent, IgnoreExistingContent), NewContentStatus (NewContentDisallowed),
                                                       defaultPort,
                                                       raxContainer,
                                                       toExistingContentStatus,
                                                       toNewContentStatus)
import           ZoomHub.Log.Logger                   (logInfo, logInfo_)
import           ZoomHub.Log.RequestLogger            (formatAsJSON)
import           ZoomHub.Rackspace.CloudFiles         (unContainer)
import           ZoomHub.Types.BaseURI                (BaseURI (BaseURI))
import           ZoomHub.Types.ContentBaseURI         (ContentBaseURI (ContentBaseURI))
import           ZoomHub.Types.DatabasePath           (DatabasePath (DatabasePath),
                                                       unDatabasePath)
import           ZoomHub.Types.StaticBaseURI          (StaticBaseURI (StaticBaseURI))
import           ZoomHub.Worker                       (processExistingContent, processExpiredActiveContent)

-- Environment
baseURIEnvName :: String
baseURIEnvName = "BASE_URI"

existingContentStatusEnvName :: String
existingContentStatusEnvName = "PROCESS_EXISTING_CONTENT"

newContentStatusEnvName :: String
newContentStatusEnvName = "PROCESS_NEW_CONTENT"

dbPathEnvName :: String
dbPathEnvName = "DB_PATH"

hashidsSaltEnvName :: String
hashidsSaltEnvName = "HASHIDS_SALT"

-- Main
main :: IO ()
main = do
  -- TODO: Migrate configuration to `configurator`:
  -- https://hackage.haskell.org/package/configurator
  currentDirectory <- getCurrentDirectory
  openseadragonScript <- readFile $ currentDirectory </>
    "public" </> "lib" </> "openseadragon" </> "openseadragon.min.js"
  error404 <- BL.readFile $ currentDirectory </> "public" </> "404.html"
  version <- readVersion currentDirectory
  maybePort <- lookupEnv "PORT"
  maybeDataPath <- lookupEnv "DATA_PATH"
  maybeDBPath <- (fmap . fmap) DatabasePath (lookupEnv dbPathEnvName)
  maybePublicPath <- lookupEnv "PUBLIC_PATH"
  maybeHashidsSalt <- (fmap . fmap) BC.pack (lookupEnv hashidsSaltEnvName)
  maybeRaxConfig <- decodeEnv
  hostname <- getHostName
  maybeBaseURI <- lookupEnv baseURIEnvName
  maybeExistingContentStatus <- (fmap . fmap) toExistingContentStatus
    (lookupEnv existingContentStatusEnvName)
  maybeNewContentStatus <- (fmap . fmap) toNewContentStatus
    (lookupEnv newContentStatusEnvName)
  logger <- mkRequestLogger def {
    outputFormat = CustomOutputFormatWithDetails formatAsJSON
  }
  let existingContentStatus =
        fromMaybe IgnoreExistingContent maybeExistingContentStatus
      newContentStatus = fromMaybe NewContentDisallowed maybeNewContentStatus
      defaultDataPath = currentDirectory </> "data"
      defaultDBPath = DatabasePath $
        currentDirectory </> "data" </> "zoomhub-development.sqlite3"
      dataPath = fromMaybe defaultDataPath maybeDataPath
      dbPath = fromMaybe defaultDBPath maybeDBPath
      port = maybe defaultPort read maybePort
      baseURI = case maybeBaseURI of
        Just uriString -> toBaseURI uriString
        Nothing        -> toBaseURI ("http://" ++ hostname)
      staticBaseURI = StaticBaseURI . fromJust .
        parseAbsoluteURI $ "http://static.zoomhub.net"
      defaultPublicPath = currentDirectory </> "public"
      publicPath = fromMaybe defaultPublicPath maybePublicPath
  ensureDBExists dbPath
  dbConnection <- open (unDatabasePath dbPath)
  case (maybeHashidsSalt, maybeRaxConfig) of
    (Just hashidsSalt, Right rackspace) -> do

      let encodeContext = hashidsSimple hashidsSalt
          encodeId integerId =
            BC.unpack $ encode encodeContext (fromIntegral integerId)
          contentBaseURI = ContentBaseURI . fromJust . parseAbsoluteURI $
            "http://" ++ unContainer (raxContainer rackspace) ++ ".zoomhub.net"
          config = Config{..}
      logInfo_ $ "Welcome to ZoomHub.\
        \ Go to <" ++ show baseURI ++ "> and have fun!"
      logInfo "Config"
        [ "name" .= ("baseURI" :: Text)
        , "value" .= baseURI
        ]
      logInfo "Config"
        [ "name" .= ("staticBaseURI" :: Text)
        , "value" .= staticBaseURI
        ]
      logInfo "Config"
        [ "name" .= ("contentBaseURI" :: Text)
        , "value" .= contentBaseURI
        ]
      logInfo "Environment"
        [ "name" .= existingContentStatusEnvName
        , "value" .= show existingContentStatus
        ]
      logInfo "Environment"
        [ "name" .= newContentStatusEnvName
        , "value" .= show newContentStatus
        ]

      logInfo_ "Worker: Reset expired active content"
      _ <- forkIO (processExpiredActiveContent config)

      case existingContentStatus of
        ProcessExistingContent -> do
          forM_ [1..3] $ \_ -> do
            logInfo_ "Worker: Start processing existing content"
            forkIO (processExistingContent config)

          return ()
        _ -> return ()
      logInfo "Start web server" ["port" .= port]
      run (fromIntegral port) (app config)
    (Nothing, _) -> error $ "Please set `" ++ hashidsSaltEnvName ++
      "` environment variable.\nThis secret salt enables ZoomHub to encode" ++
      " integer IDs as short, non-sequential string IDs which make it harder" ++
      " to guess valid content IDs."
    (_, Left message) -> error $ "Failed to read Rackspace config: " ++ message
  where
    toBaseURI :: String -> BaseURI
    toBaseURI uriString =
      case parseAbsoluteURI uriString of
        Just uri -> BaseURI uri
        Nothing  -> error $ "'" ++ uriString ++ "' is not a valid URL. Please\
        \ set `" ++ baseURIEnvName ++ "` to override usage of hostname."

    ensureDBExists :: DatabasePath -> IO ()
    ensureDBExists dbPath = do
      exists <- doesFileExist (unDatabasePath dbPath)
      unless exists $
        error $ "Couldn’t find a database at " ++ unDatabasePath dbPath ++
          ". Please check `" ++ dbPathEnvName ++ "`."

    readVersion :: FilePath -> IO String
    readVersion currentDirectory = do
      r <- tryJust (guard . isDoesNotExistError) $ readFile versionPath
      return $ case r of
        Left _        -> "unknown"
        Right version -> version
      where
        versionPath = currentDirectory </> "version.txt"
