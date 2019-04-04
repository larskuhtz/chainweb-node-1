{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- |
-- Module: Chainweb.CutDB
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.CutDB
(
-- * CutConfig
  CutDbConfig(..)
, cutDbConfigInitialCut
, cutDbConfigInitialCutFile
, cutDbConfigBufferSize
, cutDbConfigLogLevel
, cutDbConfigTelemetryLevel
, cutDbConfigUseOrigin
, defaultCutDbConfig

-- * CutDb
, CutDb
, cutDbWebBlockHeaderDb
, cutDbWebBlockHeaderStore
, cutDbPayloadCas
, cutDbPayloadStore
, member
, cut
, _cut
, _cutStm
, cutStm
, consensusCut
, cutStream
, addCutHashes
, withCutDb
, startCutDb
, stopCutDb
, cutDbQueueSize

-- * Some CutDb
, CutDbT(..)
, SomeCutDb(..)
, someCutDbVal
) where

import Control.Applicative
import Control.Concurrent.Async
import Control.Concurrent.STM.TMVar
import Control.Concurrent.STM.TVar
import Control.Exception
import Control.Lens hiding ((:>))
import Control.Monad hiding (join)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class
import Control.Monad.STM

import Data.Bool (bool)
import Data.Foldable
import Data.Function
import Data.Functor.Of
import qualified Data.HashMap.Strict as HM
import Data.LogMessage
import Data.Maybe
import Data.Monoid
import Data.Ord
import qualified Data.Text as T

import GHC.Generics hiding (to)

import Numeric.Natural

import Prelude hiding (lookup)

import qualified Streaming.Prelude as S

import System.LogLevel

-- internal modules

import Chainweb.BlockHash
import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB
import Chainweb.ChainId
import Chainweb.Cut
import Chainweb.Cut.CutHashes
import Chainweb.Graph
import Chainweb.Payload.PayloadStore
import Chainweb.Sync.WebBlockHeaderStore
import Chainweb.TreeDB
import Chainweb.Utils hiding (check)
import Chainweb.Version
import Chainweb.WebBlockHeaderDB

import Data.PQueue
import Data.Singletons

import P2P.TaskQueue

-- -------------------------------------------------------------------------- --
-- Cut DB Configuration

data CutDbConfig = CutDbConfig
    { _cutDbConfigInitialCut :: !Cut
    , _cutDbConfigInitialCutFile :: !(Maybe FilePath)
    , _cutDbConfigBufferSize :: !Natural
    , _cutDbConfigLogLevel :: !LogLevel
    , _cutDbConfigTelemetryLevel :: !LogLevel
    , _cutDbConfigUseOrigin :: !Bool
    }
    deriving (Show, Eq, Ord, Generic)

makeLenses ''CutDbConfig

defaultCutDbConfig :: ChainwebVersion -> CutDbConfig
defaultCutDbConfig v = CutDbConfig
    { _cutDbConfigInitialCut = genesisCut v
    , _cutDbConfigInitialCutFile = Nothing
    , _cutDbConfigBufferSize = 300
        -- TODO this should probably depend on the diameter of the graph
        -- It shouldn't be too big. Maybe something like @diameter * order^2@?
    , _cutDbConfigLogLevel = Warn
    , _cutDbConfigTelemetryLevel = Warn
    , _cutDbConfigUseOrigin = True
    }

-- -------------------------------------------------------------------------- --
-- Cut DB

-- | This is a singleton DB that contains the latest chainweb cut as only entry.
--
data CutDb cas = CutDb
    { _cutDbCut :: !(TVar Cut)
    , _cutDbQueue :: !(PQueue (Down CutHashes))
    , _cutApproxNetworkHeight :: !(TMVar BlockHeight)
    , _cutDbAsync :: !(Async ())
    , _cutDbLogFunction :: !LogFunction
    , _cutDbHeaderStore :: !WebBlockHeaderStore
    , _cutDbPayloadStore :: !(WebBlockPayloadStore cas)
    , _cutDbQueueSize :: !Natural
    }

instance HasChainGraph (CutDb cas) where
    _chainGraph = _chainGraph . _cutDbHeaderStore
    {-# INLINE _chainGraph #-}

instance HasChainwebVersion (CutDb cas) where
    _chainwebVersion = _chainwebVersion . _cutDbHeaderStore
    {-# INLINE _chainwebVersion #-}

cutDbPayloadCas :: Getter (CutDb cas) (PayloadDb cas)
cutDbPayloadCas = to $ _webBlockPayloadStoreCas . _cutDbPayloadStore

cutDbPayloadStore :: Getter (CutDb cas) (WebBlockPayloadStore cas)
cutDbPayloadStore = to _cutDbPayloadStore

-- We export the 'WebBlockHeaderDb' read-only
--
cutDbWebBlockHeaderDb :: Getter (CutDb cas) WebBlockHeaderDb
cutDbWebBlockHeaderDb = to $ _webBlockHeaderStoreCas . _cutDbHeaderStore

cutDbWebBlockHeaderStore :: Getter (CutDb cas) WebBlockHeaderStore
cutDbWebBlockHeaderStore = to _cutDbHeaderStore

-- | Get the current 'Cut', which represent the latest chainweb state.
--
-- This the main API method of chainweb-consensus.
--
_cut :: CutDb cas -> IO Cut
_cut = readTVarIO . _cutDbCut

-- | Get the current 'Cut', which represent the latest chainweb state.
--
-- This the main API method of chainweb-consensus.
--
cut :: Getter (CutDb cas) (IO Cut)
cut = to _cut

addCutHashes :: CutDb cas -> CutHashes -> IO ()
addCutHashes db = pQueueInsertLimit (_cutDbQueue db) (_cutDbQueueSize db) . Down

-- | An 'STM' version of '_cut'.
--
-- @_cut db@ is generally more efficient than as @atomically (_cut db)@.
--
_cutStm :: CutDb cas -> STM Cut
_cutStm = readTVar . _cutDbCut

-- | An 'STM' version of 'cut'.
--
-- @_cut db@ is generally more efficient than as @atomically (_cut db)@.
--
cutStm :: Getter (CutDb cas) (STM Cut)
cutStm = to _cutStm

member :: CutDb cas -> ChainId -> BlockHash -> IO Bool
member db cid h = do
    th <- maxHeader chainDb
    lookup chainDb h >>= \case
        Nothing -> return False
        Just lh -> do
            fh <- forkEntry chainDb th lh
            return $ fh == lh
  where
    chainDb = db ^?! cutDbWebBlockHeaderDb . ixg cid

cutDbQueueSize :: CutDb cas -> IO Natural
cutDbQueueSize = pQueueSize . _cutDbQueue

withCutDb
    :: PayloadCas cas
    => CutDbConfig
    -> LogFunction
    -> WebBlockHeaderStore
    -> WebBlockPayloadStore cas
    -> (CutDb cas -> IO a)
    -> IO a
withCutDb config logfun headerStore payloadStore
    = bracket (startCutDb config logfun headerStore payloadStore) stopCutDb

startCutDb
    :: PayloadCas cas
    => CutDbConfig
    -> LogFunction
    -> WebBlockHeaderStore
    -> WebBlockPayloadStore cas
    -> IO (CutDb cas)
startCutDb config logfun headerStore payloadStore = mask_ $ do
    cutVar <- newTVarIO (_cutDbConfigInitialCut config)
    -- queue <- newEmptyPQueue (int $ _cutDbConfigBufferSize config)
    queue <- newEmptyPQueue
    networkHeight <- newEmptyTMVarIO
    cutAsync <- asyncWithUnmask $ \u -> u $ processor queue cutVar networkHeight
    logfun @T.Text Info "CutDB started"
    return $ CutDb
        { _cutDbCut = cutVar
        , _cutDbQueue = queue
        , _cutApproxNetworkHeight = networkHeight
        , _cutDbAsync = cutAsync
        , _cutDbLogFunction = logfun
        , _cutDbHeaderStore = headerStore
        , _cutDbPayloadStore = payloadStore
        , _cutDbQueueSize = _cutDbConfigBufferSize config
        }
  where
    processor :: PQueue (Down CutHashes) -> TVar Cut -> TMVar BlockHeight -> IO ()
    processor queue cutVar networkHeight = do
        processCuts logfun headerStore payloadStore queue cutVar networkHeight `catches`
            [ Handler $ \(e :: SomeAsyncException) -> throwM e
            , Handler $ \(e :: SomeException) ->
                logfun @T.Text Error $ "CutDB failed: " <> sshow e
            ]
        processor queue cutVar networkHeight

stopCutDb :: CutDb cas -> IO ()
stopCutDb db = cancel (_cutDbAsync db)

-- | This is at the heart of 'Chainweb' POW: Deciding the current "longest" cut
-- among the incoming candiates.
--
-- Going forward this should probably be the main scheduler for most operations,
-- in particular it should drive (or least preempt) synchronzations of block
-- headers on indiviual chains.
--
processCuts
    :: PayloadCas cas
    => LogFunction
    -> WebBlockHeaderStore
    -> WebBlockPayloadStore cas
    -> PQueue (Down CutHashes)
    -> TVar Cut
    -> TMVar BlockHeight
    -> IO ()
processCuts logFun headerStore payloadStore queue cutVar networkHeight = queueToStream
    & S.chain (\_ -> logFun @T.Text Info "start processing new cut")
    & S.filterM (fmap not . isVeryOld)
    & S.filterM (fmap not . isOld)
    & S.filterM (fmap not . isCurrent)
    & S.chain updateNetworkHeight
    & S.chain (\_ -> logFun @T.Text Info "fetch all prerequesites for cut")
    & S.mapM (cutHashesToBlockHeaderMap headerStore payloadStore)
    & S.chain (either
        (\_ -> logFun @T.Text Warn "failed to get prerequesites for some blocks at")
        (\_ -> logFun @T.Text Info "got all prerequesites of cut")
        )
    & S.concat
        -- ignore left values for now
    & S.scanM
        (\a b -> joinIntoHeavier_ (_webBlockHeaderStoreCas headerStore) (_cutMap a) b
        )
        (readTVarIO cutVar)
        (\c -> do
            atomically (writeTVar cutVar c)
            logFun @T.Text Info "write new cut"
        )
    & S.effects
  where
    -- | Broadcast the newest estimated `BlockHeight` of the network to other
    -- components of this node.
    --
    updateNetworkHeight :: CutHashes -> IO ()
    updateNetworkHeight = void . atomically . swapTMVar networkHeight . _cutHashesHeight

    graph = _chainGraph headerStore

    threshold :: Int
    threshold = int $ 2 * diameter graph * order graph

    queueToStream :: S.Stream (Of CutHashes) IO ()
    queueToStream = do
        Down a <- liftIO (pQueueRemove queue)
        S.yield a
        queueToStream

    isVeryOld :: CutHashes -> IO Bool
    isVeryOld x = do
        h <- _cutHeight <$> readTVarIO cutVar
        let !r = int (_cutHashesHeight x) <= (int h - threshold)
        when r $ logFun @T.Text Debug "skip very old cut"
        return r

    isOld :: CutHashes -> IO Bool
    isOld x = do
        curHashes <- cutToCutHashes Nothing <$> readTVarIO cutVar
        let !r = all (>= (0 :: Int)) $ (HM.unionWith (-) `on` (fmap (int . fst) . _cutHashes)) curHashes x
        when r $ logFun @T.Text Debug "skip old cut"
        return r

    isCurrent :: CutHashes -> IO Bool
    isCurrent x = do
        curHashes <- cutToCutHashes Nothing <$> readTVarIO cutVar
        let !r = _cutHashes curHashes == _cutHashes x
        when r $ logFun @T.Text Debug "skip current cut"
        return r

-- | Stream of most recent cuts. This stream does not generally include the full
-- history of cuts. When no cuts are demanded from the stream or new cuts are
-- produced faster than they are consumed from the stream, the stream skips over
-- cuts and always returns the latest cut in the db.
--
cutStream :: MonadIO m => CutDb cas -> S.Stream (Of Cut) m r
cutStream db = liftIO (_cut db) >>= \c -> S.yield c >> go c
  where
    go cur = do
        new <- liftIO $ atomically $ do
            c' <- _cutStm db
            check (c' /= cur)
            return c'
        S.yield new
        go new

cutHashesToBlockHeaderMap
    :: PayloadCas cas
    => WebBlockHeaderStore
    -> WebBlockPayloadStore cas
    -> CutHashes
    -> IO (Either (HM.HashMap ChainId BlockHash) (HM.HashMap ChainId BlockHeader))
        -- ^ The 'Left' value holds missing hashes, the 'Right' value holds
        -- a 'Cut'.
cutHashesToBlockHeaderMap headerStore payloadStore hs = do
    (headers :> missing) <- S.each (HM.toList $ _cutHashes hs)
        & S.map (fmap snd)
        & S.mapM tryGetBlockHeader
        & S.partitionEithers
        & S.fold_ (\x (cid, h) -> HM.insert cid h x) mempty id
        & S.fold (\x (cid, h) -> HM.insert cid h x) mempty id
    if null missing
        then return $ Right headers
        else return $ Left missing
  where
    origin = _cutOrigin hs
    priority = Priority (- int (_cutHashesHeight hs))

    tryGetBlockHeader cv@(cid, _) =
        (Right <$> mapM (getBlockHeader headerStore payloadStore cid priority origin) cv)
            `catch` \case
                (TreeDbKeyNotFound{} :: TreeDbException BlockHeaderDb) ->
                    return $ Left cv
                e -> throwM e

-- | Yield a `Cut` only when it is determined that `CutDb` has sync'd with
-- remote peers enough. "Enough" is a measure of "closeness" determined from the
-- `ChainGraph` implied by the given `ChainwebVersion`. In essence, if our
-- current Cut is...:
--
--   * below the threshold: Spin via STM (this has the affect of pausing POW mining).
--   * above the threshold: Yield the `Cut`.
--   * even higher than the network: We are either a "superior" fork, or we are in
--     initial network conditions where there is no real consensus yet. In this
--     case, we yield a `Cut`.
--
consensusCut :: CutDb cas -> IO Cut
consensusCut cutdb = atomically $ do
    cur <- _cutStm cutdb
    tryReadTMVar (_cutApproxNetworkHeight cutdb) >>= \case
        Nothing -> pure cur
        Just nh -> do
            let !currentHeight = _cutHeight cur
                !thresh = int . catchupThreshold $ _chainwebVersion cutdb
                !mini = bool (nh - thresh) 0 $ thresh > nh
            when (currentHeight < mini) retry
            pure cur

-- consensusCut cutdb = readTVarIO (_cutNetworkCutHeight cutdb) >>= \case
--     Nothing -> pure False
--     Just nh -> do
--         currentHeight <- _cutHeight <$> _cut cutdb
--         let !thresh = int . catchupThreshold $ _chainwebVersion cutdb
--             !mini = bool (nh - thresh) 0 $ thresh > nh
--         pure $ currentHeight > mini

-- | The distance from the true Cut within which the current node could be
-- considered "caught up".
--
catchupThreshold :: ChainwebVersion -> Natural
catchupThreshold = (2 *) . diameter . _chainGraph

-- -------------------------------------------------------------------------- --
-- Some CutDB

-- | 'CutDb' with type level 'ChainwebVersion'
--
newtype CutDbT cas (v :: ChainwebVersionT) = CutDbT (CutDb cas)
    deriving (Generic)

data SomeCutDb cas = forall v . KnownChainwebVersionSymbol v => SomeCutDb (CutDbT cas v)

someCutDbVal :: ChainwebVersion -> CutDb cas -> SomeCutDb cas
someCutDbVal (FromSing (SChainwebVersion :: Sing v)) db = SomeCutDb $ CutDbT @_ @v db
