{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module: Chainweb.Utils.RequestLog
-- Copyright: Copyright © 2019 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Utils.RequestLog
(
-- * Request Logging Middleware
  RequestLog(..)
, requestLogVersion
, requestLogMethod
, requestLogPath
, requestLogIsSecure
, requestLogRemoteHost
, requestLogQueryString
, requestLogBodyLength
, requestLogUserAgent
, requestLogger

-- * Request-Response Logging Middleware
, RequestResponseLog(..)
, requestResponseLogRequest
, requestResponseLogStatus
, requestResponseLogDurationMicro
, requestResponseLogger
) where

import Control.DeepSeq
import Control.Lens

import Data.Aeson
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import GHC.Generics

import Network.HTTP.Types
import Network.Wai

import Numeric.Natural

import System.Clock
import System.LogLevel

-- internal modules

import Chainweb.Logger
import Chainweb.Utils

-- -------------------------------------------------------------------------- --
-- Request Logger

data RequestLog = RequestLog
    { _requestLogVersion :: !T.Text
    , _requestLogMethod :: !T.Text
    , _requestLogPath :: ![T.Text]
    , _requestLogIsSecure :: !Bool
    , _requestLogRemoteHost :: !T.Text
    , _requestLogQueryString :: !QueryText
    , _requestLogBodyLength :: !(Maybe Natural)
    , _requestLogUserAgent :: !(Maybe T.Text)
    }
    deriving (Show, Eq, Ord, Generic)
    deriving anyclass (NFData, ToJSON)

makeLenses ''RequestLog

-- | INVARIANT: this result of this function must not retain pointers to
-- the original request data that came over the wire.
--
logRequest :: Request -> RequestLog
logRequest req = RequestLog
    { _requestLogVersion = sshow $ httpVersion req
    , _requestLogMethod = T.decodeUtf8 $ requestMethod req
    , _requestLogPath = pathInfo req
    , _requestLogIsSecure = isSecure req
    , _requestLogRemoteHost = sshow $ remoteHost req
    , _requestLogQueryString = queryToQueryText $ queryString req
    , _requestLogBodyLength = case requestBodyLength req of
        ChunkedBody -> Nothing
        KnownLength x -> Just $ int x
    , _requestLogUserAgent = T.decodeUtf8 <$> requestHeaderUserAgent req
    }

requestLogger :: Logger l => l -> Middleware
requestLogger logger app req respond = do
    logFunctionJson logger Info $ logRequest req
    app req respond

-- -------------------------------------------------------------------------- --
-- Request-Response Logger

data RequestResponseLog = RequestResponseLog
    { _requestResponseLogRequest :: !RequestLog
    , _requestResponseLogStatus :: !T.Text
    , _requestResponseLogDurationMicro :: !Int
    }
    deriving (Show, Eq, Ord, Generic)
    deriving anyclass (NFData, ToJSON)

makeLenses ''RequestResponseLog

logRequestResponse :: RequestLog -> Response -> Int -> RequestResponseLog
logRequestResponse reqLog res d = RequestResponseLog
    { _requestResponseLogRequest = reqLog
    , _requestResponseLogStatus = sshow $ responseStatus res
    , _requestResponseLogDurationMicro = d
    }

-- | NOTE: this middleware should only be used for APIs that don't stream. Otherwise
-- the logg may be delayed for indefinite time.
--
requestResponseLogger :: Logger l => l -> Middleware
requestResponseLogger logger app req respond = do
    let !reqLog = logRequest req
    reqTime <- getTime Monotonic
    app req $ \res -> do
        r <- respond res
        resTime <- getTime Monotonic
        logFunctionJson logger Info
            $ logRequestResponse reqLog res
            $ (int $ toNanoSecs $ diffTimeSpec resTime reqTime) `div` 1000
        return r
