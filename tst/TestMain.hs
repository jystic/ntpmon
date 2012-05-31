{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}

module Main where

import Test.Framework (defaultMain)
import Test.Framework.Providers.QuickCheck2
import Test.QuickCheck

import Data.NTP

------------------------------------------------------------------------
-- Tests

main = defaultMain tests

tests = [ testProperty "add_sub_roundtrip" prop_add_sub_roundtrip
        , testProperty "midpoint_is_halfway" prop_midpoint_is_halfway
        ]

prop_add_sub_roundtrip t d = dur >= minDur ==>
                             dur <= maxDur ==>
    t `add` d `sub` t == d
  where
    dur    = unDuration d
    minDur = minTime - time
    maxDur = maxTime - time

    time = fromIntegral (unTime t)
    minTime = fromIntegral (unTime minBound)
    maxTime = fromIntegral (unTime maxBound)

prop_midpoint_is_halfway t1 t2 =
    mid t1 t2 `sub` t1 == half (t2 `sub` t1)

------------------------------------------------------------------------
-- Utils

instance Arbitrary Time where
    shrink = map Time . shrinkIntegral . unTime
    arbitrary = fmap Time arbitraryBoundedIntegral

instance Arbitrary Duration where
    shrink = map Duration . shrinkIntegral . unDuration
    arbitrary = fmap Duration (choose (-maxDur, maxDur))
      where
        maxDur = fromIntegral (unTime maxBound)

half :: Duration -> Duration
half d = Duration (unDuration d `div` 2)
