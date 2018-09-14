module Pier.Core.Download
    ( askDownload
    , Download(..)
    , downloadRules
    , DownloadLocation(..)
    ) where

import Control.Exception (bracketOnError)
import Control.Monad (unless)
import Development.Shake
import Development.Shake.Classes
import Development.Shake.FilePath
import GHC.Generics
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.HTTP.Types.Status

import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as L
import qualified System.Directory as Directory

import Pier.Core.Artifact
import Pier.Core.Internal.Directory
import Pier.Core.Internal.Store
import Pier.Core.Persistent

-- | Downloads @downloadUrlPrefix / downloadName@ to
-- @downloadFilePrefix / downloadName@.
-- Everything is stored in `~/.pier/downloads`.
data Download = Download
    { downloadUrlPrefix :: String
    , downloadName :: FilePath
    , downloadFilePrefix :: FilePath
        }
    deriving (Typeable, Eq, Generic)

instance Show Download where
    show d = "Download " ++ show (downloadName d)
            ++ " from " ++ show (downloadUrlPrefix d)
            ++ " into " ++ show (downloadFilePrefix d)

instance Hashable Download
instance Binary Download
instance NFData Download

type instance RuleResult Download = Artifact

askDownload :: Download -> Action Artifact
askDownload = askPersistent

-- TODO: make this its own rule type?
downloadRules :: DownloadLocation -> Rules ()
downloadRules loc = do
    manager <- liftIO $ newManager tlsManagerSettings
    addPersistent $ \d -> do
    -- Download to a shared location under $HOME/.pier, if it doesn't
    -- already exist (atomically); then make an artifact that symlinks to it.
    downloadsDir <- liftIO $ pierDownloadsDir loc
    let result = downloadsDir </> downloadFilePrefix d
                                        </> downloadName d
    exists <- liftIO $ Directory.doesFileExist result
    unless exists $ do
        putNormal $ "Downloading " ++ downloadName d
        -- TODO: fix the race
        liftIO $ bracketOnError
            (createPierTempFile $ takeFileName $ downloadName d)
            Directory.removeFile
            $ \tmp -> do
                        let url = downloadUrlPrefix d ++ "/" ++ downloadName d
                        req <- parseRequest url
                        resp <- httpLbs req manager
                        unless (statusIsSuccessful . responseStatus $ resp)
                            $ error $ "Unable to download " ++ show url
                                    ++ "\nStatus: " ++ showStatus (responseStatus resp)
                        liftIO . L.writeFile tmp . responseBody $ resp
                        createParentIfMissing result
                        Directory.renameFile tmp result
    return $ externalFile result
  where
    showStatus s = show (statusCode s) ++ " " ++ BC.unpack (statusMessage s)

pierDownloadsDir :: DownloadLocation -> IO FilePath
pierDownloadsDir DownloadToHome = do
    home <- Directory.getHomeDirectory
    return $ home </> ".pier/downloads"
pierDownloadsDir DownloadLocal = return $ pierDir </> "downloads"

data DownloadLocation
    = DownloadToHome
    | DownloadLocal
