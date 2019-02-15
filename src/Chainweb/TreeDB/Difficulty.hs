{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.TreeDB.Difficulty
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Colin Woodbury <colin@kadena.io>
-- Stability: experimental
--
module Chainweb.TreeDB.Difficulty ( hashTarget ) where

import Control.Lens ((^.))

import Data.Function ((&))
import qualified Data.HashSet as HS
import Data.Int (Int64)
import Data.Maybe (fromJust)
import Data.Semigroup (Max(..), Min(..))

import qualified Streaming.Prelude as P

-- internal modules

import Chainweb.BlockHeader
import Chainweb.Difficulty
import Chainweb.Time (Time(..), TimeSpan(..))
import Chainweb.TreeDB
import Chainweb.Utils (int)
import Chainweb.Version (ChainwebVersion)

---

-- | See `adjust` for a detailed description of the full algorithm.
hashTarget
    :: forall db. TreeDb db
    => IsBlockHeader (DbEntry db)
    => db
    -> DbEntry db
    -> BlockRate
    -> WindowWidth
    -> IO HashTarget
hashTarget db bh blockRate ww@(WindowWidth w)
    -- Intent: Neither the genesis block, nor any block whose height is not a
    -- multiple of the `BlockRate` shall be considered for adjustment.
    | isGenesisBlockHeader bh' = pure $! _blockTarget bh'
    | int (_blockHeight bh') `mod` w /= 0 = pure $! _blockTarget bh'
    | otherwise = do
        start <- branchEntries db Nothing Nothing minr maxr lower upper
                 & P.map (^. isoBH)
                 & P.take (int w)
                 & P.last_
                 & fmap fromJust  -- Thanks to the two guard conditions above,
                                  -- this will (should) always succeed.

        let
            -- The time difference in microseconds between when the earliest and
            -- latest blocks in the window were mined.
            delta :: TimeSpan Int64
            !delta = TimeSpan $ time bh' - time start

        pure . adjust ver ww blockRate delta $ _blockTarget bh'
  where
    bh' :: BlockHeader
    bh' = bh ^. isoBH

    ver :: ChainwebVersion
    ver = _blockChainwebVersion bh'

    -- Query parameters for `branchEntries`.
    minr = Just . MinRank $ Min 0
    maxr = Just . MaxRank . Max . fromIntegral $! _blockHeight bh'
    lower = HS.empty
    upper = HS.singleton . UpperBound $! key bh

    time :: BlockHeader -> Int64
    time h = case _blockCreationTime h of BlockCreationTime (Time (TimeSpan n)) -> n
