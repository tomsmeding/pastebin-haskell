{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}
module Play (playModule) where

import Control.Concurrent (getNumCapabilities)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BSB
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.UTF8 as UTF8
import Snap.Core hiding (path, method)
import System.Exit (ExitCode(..))
import qualified System.IO.Streams as Streams
import System.IO.Streams (InputStream)
import qualified Text.JSON as JSON
import Text.JSON (JSValue(..))
import Text.JSON.String (runGetJSON)

import GHCPool
import ServerModule
import SpamDetect hiding (Action(..))
import qualified SpamDetect as Spam (Action(..))


data Context = Context Pool

data WhatRequest
  = Index
  | Versions
  | Run
  deriving (Show)

parseRequest :: Method -> [ByteString] -> Maybe WhatRequest
parseRequest method comps = case (method, comps) of
  (GET, ["play"]) -> Just Index
  (GET, ["play", "versions"]) -> Just Versions
  (POST, ["play", "run"]) -> Just Run
  _ -> Nothing

streamReadMaxN :: Int -> InputStream ByteString -> IO (Maybe ByteString)
streamReadMaxN maxlen stream = fmap mconcat <$> go 0
  where go :: Int -> IO (Maybe [ByteString])
        go yet = Streams.read stream >>= \case
                   Nothing -> return (Just [])
                   Just chunk
                     | yet + BS.length chunk <= maxlen ->
                         fmap (chunk :) <$> go (yet + BS.length chunk)
                     | otherwise ->
                         return Nothing

handleRequest :: GlobalContext -> Context -> WhatRequest -> Snap ()
handleRequest gctx (Context pool) = \case
  Index -> staticFile "text/html" "play.html"

  Versions -> do
    modifyResponse (setContentType (Char8.pack "text/plain"))
    versions <- liftIO availableVersions
    writeJSON $ JSArray (map (JSString . JSON.toJSString) versions)

  Run -> do
    req <- getRequest
    isSpam <- liftIO $ recordCheckSpam Spam.PlayRun (gcSpam gctx) (rqClientAddr req)
    if isSpam
      then httpError 429 "Please slow down a bit, you're rate limited"
      else do mpostdata <- runRequestBody $ \stream ->
                streamReadMaxN 100000 stream >>= \case
                  Nothing -> return $ Left (413, "Program too large")
                  Just s -> return (Right s)
              case mpostdata of
                Left (code, err) -> httpError code err
                Right postdata -> do
                  case runGetJSON JSON.readJSValue (UTF8.toString postdata) of
                    Right (JSObject (JSON.fromJSObject -> obj))
                      | Just (JSString (JSON.fromJSString -> source)) <- lookup "source" obj
                      , Just (JSString (JSON.fromJSString -> version)) <- lookup "version" obj
                      -> do res <- liftIO $ runInPool pool CRun (Version version) source
                            case res of
                              Left err -> httpError 500 err
                              Right (ec, out, err) -> do
                                modifyResponse (setContentType (Char8.pack "text/json"))
                                writeJSON $ JSON.makeObj
                                              [("ec", JSRational False (fromIntegral (exitCode ec)))
                                              ,("out", JSString (JSON.toJSString out))
                                              ,("err", JSString (JSON.toJSString err))]
                    _ -> httpError 400 "Invalid JSON"

playModule :: ServerModule
playModule = ServerModule
  { smMakeContext = \_options k -> do
      nprocs <- getNumCapabilities
      -- TODO: the max queue length is a completely arbitrary value
      pool <- makePool nprocs nprocs
      k (Context pool)
  , smParseRequest = parseRequest
  , smHandleRequest = handleRequest
  , smStaticFiles = [("play-index.js", "text/javascript")]
  , smReloadPages = \_ -> return ()
  }

writeJSON :: JSValue -> Snap ()
writeJSON = writeLBS . BSB.toLazyByteString . BSB.stringUtf8 . flip JSON.showJSValue ""

exitCode :: ExitCode -> Int
exitCode ExitSuccess = 0
exitCode (ExitFailure n) = n