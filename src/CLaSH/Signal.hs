{-|
Copyright  :  (C) 2013-2016, University of Twente,
                  2017     , Google Inc.
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE GADTs           #-}
{-# LANGUAGE ImplicitParams  #-}
{-# LANGUAGE MagicHash       #-}
{-# LANGUAGE RankNTypes      #-}
{-# LANGUAGE TypeApplications #-}

{-# LANGUAGE Trustworthy #-}

{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{-# OPTIONS_HADDOCK show-extensions #-}

module CLaSH.Signal
  ( -- * Synchronous signals
    Signal
  , Domain (..)
  , System
    -- * Clock
  , Clock
  , ClockKind (..)
    -- * Reset
  , Reset
  , ResetKind (..)
  , unsafeFromAsyncReset
  , unsafeToAsyncReset
  , fromSyncReset
  , toSyncReset
  , resetSynchroniser
    -- * Implicit routing of clocks and resets
    -- $implicitclockandreset

    -- ** Implicit clock
  , HasClock
  , hasClock
  , withClock
    -- ** Implicit reset
  , HasReset
  , hasReset
  , withReset
    -- ** Implicit clock and reset
  , HasClockReset
  , withClockReset
  , SystemClockReset
    -- * Basic circuit functions
  , delay
  , register
  , regMaybe
  , regEn
  , mux
    -- * Testbench functions
  , clockGen
  , asyncResetGen
  , syncResetGen
    -- * Boolean connectives
  , (.&&.), (.||.)
    -- * Product/Signal isomorphism
  , Bundle(..)
    -- * Simulation functions (not synthesisable)
  , simulate
  , simulateB
    -- ** lazy versions
  , simulate_lazy
  , simulateB_lazy
    -- ** Simulation clocks and resets
  , systemClock
  , systemReset
    -- * List \<-\> Signal conversion (not synthesisable)
  , sample
  , sampleN
  , fromList
    -- ** lazy versions
  , sample_lazy
  , sampleN_lazy
  , fromList_lazy
    -- * QuickCheck combinators
  , testFor
    -- * Type classes
    -- ** 'Eq'-like
  , (.==.), (./=.)
    -- ** 'Ord'-like
  , (.<.), (.<=.), (.>=.), (.>.)
  )
where

import           Control.DeepSeq       (NFData)
import           GHC.Stack             (HasCallStack, withFrozenCallStack)
import           GHC.TypeLits          (KnownNat, KnownSymbol)
import           Data.Bits             (Bits) -- Haddock only
import           Data.Maybe            (isJust, fromJust)
import           Test.QuickCheck       (Property, property)
import           Unsafe.Coerce         (unsafeCoerce)

import           CLaSH.Explicit.Signal
  (System, resetSynchroniser, systemClock, systemReset)
import qualified CLaSH.Explicit.Signal as S
import           CLaSH.Promoted.Nat    (SNat (..))
import           CLaSH.Promoted.Symbol (SSymbol (..))
import           CLaSH.Signal.Bundle   (Bundle (..))
import           CLaSH.Signal.Internal hiding
  (sample, sample_lazy, sampleN, sampleN_lazy, simulate, simulate_lazy, testFor)
import qualified CLaSH.Signal.Internal as S

{- $setup
>>> :set -XTypeApplications
>>> import CLaSH.XException (printX)
>>> import Control.Applicative (liftA2)
>>> let oscillate = register False (not <$> oscillate)
>>> let count = regEn 0 oscillate (count + 1)
>>> :{
sometimes1 = s where
  s = register Nothing (switch <$> s)
  switch Nothing = Just 1
  switch _       = Nothing
:}

>>> :{
countSometimes = s where
  s     = regMaybe 0 (plusM (pure <$> s) sometimes1)
  plusM = liftA2 (liftA2 (+))
:}

-}

-- * Implicit routing of clock and reset signals

{- $implicitclockandreset #implicitclockandreset#
Clocks and resets are by default implicitly routed.
-}

-- | A /constraint/ that indicates the component needs a 'Clock'
type HasClock domain gated       = (?clk :: Clock domain gated)

-- | A /constraint/ that indicates the component needs a 'Reset'
type HasReset domain synchronous = (?rst :: Reset domain synchronous)

-- | A /constraint/ that indicates the component needs a 'Clock' and 'Reset'
type HasClockReset domain gated synchronous =
  (HasClock domain gated, HasReset domain synchronous)

-- | For a component with an explicit clock port, implicitly route a clock
-- to that port.
--
-- So given:
--
-- > f :: Clock domain gated -> Signal domain a -> ...
--
-- You can implicitly route a clock by:
--
-- > g = f hasClock
--
-- __NB__ all components with a `HasClock` /constraint/ are connected to
-- the same clock.
hasClock :: HasClock domain gated => Clock domain gated
hasClock = ?clk
{-# INLINE hasClock #-}

-- | For a component with an explicit clock port, implicitly route a clock
-- to that port.
--
-- So given:
--
-- > f :: Reset domain synchronous -> Signal domain a -> ...
--
-- You can implicitly route a clock by:
--
-- > g = f hasReset
--
-- __NB__ all components with a `HasReset` /constraint/ are connected to
-- the same reset.
hasReset :: HasReset domain synchronous => Reset domain synchronous
hasReset = ?rst
{-# INLINE hasReset #-}

-- | A /constraint/ that indicates the component needs a normal 'Clock' and
-- an asynchronous 'Reset' belonging to the 'System' domain.
type SystemClockReset = HasClockReset System 'Source 'Asynchronous

-- | Explicitly connect a 'Clock' to a component whose clock is implicitly
-- routed
withClock
  :: Clock domain gated
  -- ^ The 'Clock' we want to connect
  -> (HasClock domain gated => r)
  -- ^ The component with an implicitly routed clock
  -> r
withClock clk r
  = let ?clk = clk
    in  r

-- | Explicit connect a 'Reset' to a component whose reset is implicitly
-- routed
withReset
  :: Reset domain synchronous
  -- ^ The 'Reset' we want to connect
  -> (HasReset domain synchronous => r)
  -- ^ The component with an implicitly routed reset
  -> r
withReset rst r
  = let ?rst = rst
    in  r

-- | Explicitly connect a 'Clock' and 'Reset' to a component whose clock and
-- reset are implicitly routed
withClockReset
  :: Clock domain gated
  -- ^ The 'Clock' we want to connect
  -> Reset domain synchronous
  -- ^ The 'Reset' we want to connect
  -> (HasClockReset domain gated synchronous => r)
  -- ^ The component with an implicitly routed clock and reset
  -> r
withClockReset clk rst r
  = let ?clk = clk
        ?rst = rst
    in  r

-- * Basic circuit functions

-- | 'delay' @s@ delays the values in 'Signal' @s@ for once cycle, the value
-- at time 0 is undefined.
--
-- >>> printX (sampleN 3 (delay (fromList [1,2,3,4])))
-- [X,1,2]
delay
  :: (HasClock domain gated, HasCallStack)
  => Signal domain a
  -- ^ Signal to delay
  -> Signal domain a
delay = \i -> withFrozenCallStack (delay# ?clk i)
{-# INLINE delay #-}

-- | 'register' @i s@ delays the values in 'Signal' @s@ for one cycle, and sets
-- the value at time 0 to @i@
--
-- >>> sampleN 3 (register 8 (fromList [1,2,3,4]))
-- [8,1,2]
register
  :: (HasClockReset domain gated synchronous, HasCallStack)
  => a
  -- ^ Reset value
  --
  -- 'register' has an /active-hig/h 'Reset', meaning that 'register' outputs the
  -- reset value when the reset value becomes 'True'
  -> Signal domain a
  -> Signal domain a
register = \i s -> withFrozenCallStack (register# ?clk ?rst i s)
{-# INLINE register #-}
infixr 3 `register`

-- | Version of 'register' that only updates its content when its second
-- argument is a 'Just' value. So given:
--
-- @
-- sometimes1 = s where
--   s = 'register' Nothing (switch '<$>' s)
--
--   switch Nothing = Just 1
--   switch _       = Nothing
--
-- countSometimes = s where
--   s     = 'regMaybe' 0 (plusM ('pure' '<$>' s) sometimes1)
--   plusM = 'liftA2' (liftA2 (+))
-- @
--
-- We get:
--
-- >>> sampleN 8 sometimes1
-- [Nothing,Just 1,Nothing,Just 1,Nothing,Just 1,Nothing,Just 1]
-- >>> sampleN 8 countSometimes
-- [0,0,1,1,2,2,3,3]
regMaybe
  :: (HasClockReset domain gated synchronous, HasCallStack)
  => a
  -- ^ Reset value
  --
  -- 'regMaybe' has an /active-high/ 'Reset', meaning that 'regMaybe' outputs the
  -- reset value when the reset value becomes 'True'
  -> Signal domain (Maybe a)
  -> Signal domain a
regMaybe = \initial iM -> withFrozenCallStack
  (register# (clockGate ?clk (fmap isJust iM)) ?rst initial (fmap fromJust iM))
{-# INLINE regMaybe #-}
infixr 3 `regMaybe`

-- | Version of 'register' that only updates its content when its second argument
-- is asserted. So given:
--
-- @
-- oscillate = 'register' False ('not' '<$>' oscillate)
-- count     = 'regEn' 0 oscillate (count + 1)
-- @
--
-- We get:
--
-- >>> sampleN 8 oscillate
-- [False,True,False,True,False,True,False,True]
-- >>> sampleN 8 count
-- [0,0,1,1,2,2,3,3]
regEn
  :: (HasClockReset domain gated synchronous, HasCallStack)
  => a
  -- ^ Reset value
  --
  -- 'regEn' has an /active-high/ 'Reset', meaning that 'regEn' outputs the
  -- reset value when the reset value becomes 'True'
  -> Signal domain Bool
  -> Signal domain a
  -> Signal domain a
regEn = \initial en i -> withFrozenCallStack
  (register# (clockGate ?clk en) ?rst initial i)
{-# INLINE regEn #-}

-- * Signal -> List conversion

-- | Get an infinite list of samples from a 'CLaSH.Signal.Signal'
--
-- The elements in the list correspond to the values of the 'Signal'
-- at consecutive clock cycles
--
-- > sample s == [s0, s1, s2, s3, ...
--
-- __NB__: This function is not synthesisable
sample
  :: NFData a
  => ((HasClockReset domain 'Source 'Asynchronous) => Signal domain a)
  -- ^ 'Signal' we want to sample, whose source potentially needs an implicitly
  -- routed clock (and reset)
  -> [a]
sample s =
  let ?clk = unsafeCoerce (Clock @System (pure True))
      ?rst = unsafeCoerce (Async @System (True :- pure False))
  in  S.sample s

-- | Get a list of /n/ samples from a 'Signal'
--
-- The elements in the list correspond to the values of the 'Signal'
-- at consecutive clock cycles
--
-- > sampleN 3 s == [s0, s1, s2]
--
-- __NB__: This function is not synthesisable
sampleN
  :: NFData a
  => Int
  -- ^ The number of samples we want to see
  -> ((HasClockReset domain 'Source 'Asynchronous) => Signal domain a)
  -- ^ 'Signal' we want to sample, whose source potentially needs an implicitly
  -- routed clock (and reset)
  -> [a]
sampleN n s =
  let ?clk = unsafeCoerce (Clock @System (pure True))
      ?rst = unsafeCoerce (Async @System (True :- pure False))
  in  S.sampleN n s

-- | /Lazily/ get an infinite list of samples from a 'CLaSH.Signal.Signal'
--
-- The elements in the list correspond to the values of the 'Signal'
-- at consecutive clock cycles
--
-- > sample s == [s0, s1, s2, s3, ...
--
-- __NB__: This function is not synthesisable
sample_lazy
  :: ((HasClockReset domain 'Source 'Asynchronous) => Signal domain a)
  -- ^ 'Signal' we want to sample, whose source potentially needs an implicitly
  -- routed clock (and reset)
  -> [a]
sample_lazy s =
  let ?clk = unsafeCoerce (Clock @System (pure True))
      ?rst = unsafeCoerce (Async @System (True :- pure False))
  in  S.sample_lazy s


-- | Lazily get a list of /n/ samples from a 'Signal'
--
-- The elements in the list correspond to the values of the 'Signal'
-- at consecutive clock cycles
--
-- > sampleN 3 s == [s0, s1, s2]
--
-- __NB__: This function is not synthesisable
sampleN_lazy
  :: Int
  -> ((HasClockReset domain 'Source 'Asynchronous) => Signal domain a)
  -- ^ 'Signal' we want to sample, whose source potentially needs an implicitly
  -- routed clock (and reset)
  -> [a]
sampleN_lazy n s =
  let ?clk = unsafeCoerce (Clock @System (pure True))
      ?rst = unsafeCoerce (Async @System (True :- pure False))
  in  S.sampleN_lazy n s

-- * Simulation functions

-- | Simulate a (@'Signal' a -> 'Signal' b@) function given a list of samples
-- of type /a/
--
-- >>> simulate (register 8) [1, 2, 3]
-- [8,1,2,3...
-- ...
--
-- __NB__: This function is not synthesisable
simulate
  :: (NFData a, NFData b)
  => ((HasClockReset domain 'Source 'Asynchronous) =>
      Signal domain a -> Signal domain b)
  -- ^ Function we want to simulate, whose components potentially needs an
  -- implicitly routed clock (and reset)
  -> [a]
  -> [b]
simulate f =
  let ?clk = unsafeCoerce (Clock @System (pure True))
      ?rst = unsafeCoerce (Async @System (True :- pure False))
  in  S.simulate f

-- | /Lazily/ simulate a (@'Signal' a -> 'Signal' b@) function given a list of
-- samples of type /a/
--
-- >>> simulate (register 8) [1, 2, 3]
-- [8,1,2,3...
-- ...
--
-- __NB__: This function is not synthesisable
simulate_lazy
  :: ((HasClockReset domain 'Source 'Asynchronous) =>
      Signal domain a -> Signal domain b)
  -- ^ Function we want to simulate, whose components potentially needs an
  -- implicitly routed clock (and reset)
  -> [a]
  -> [b]
simulate_lazy f =
  let ?clk = unsafeCoerce (Clock @System (pure True))
      ?rst = unsafeCoerce (Async @System (True :- pure False))
  in  S.simulate_lazy f

-- | Simulate a (@'Unbundled' a -> 'Unbundled' b@) function given a list of
-- samples of type @a@
--
-- >>> simulateB (unbundle . register (8,8) . bundle) [(1,1), (2,2), (3,3)] :: [(Int,Int)]
-- [(8,8),(1,1),(2,2),(3,3)...
-- ...
--
-- __NB__: This function is not synthesisable
simulateB
  :: (Bundle a, Bundle b, NFData a, NFData b)
  => ((HasClockReset domain 'Source 'Asynchronous) =>
      Unbundled domain a -> Unbundled domain b)
  -- ^ Function we want to simulate, whose components potentially needs an
  -- implicitly routed clock (and reset)
  -> [a]
  -> [b]
simulateB f =
  let ?clk = unsafeCoerce (Clock @System (pure True))
      ?rst = unsafeCoerce (Async @System (True :- pure False))
  in  S.simulateB f

-- | /Lazily/ simulate a (@'Unbundled' a -> 'Unbundled' b@) function given a
-- list of samples of type @a@
--
-- >>> simulateB (unbundle . register (8,8) . bundle) [(1,1), (2,2), (3,3)] :: [(Int,Int)]
-- [(8,8),(1,1),(2,2),(3,3)...
-- ...
--
-- __NB__: This function is not synthesisable
simulateB_lazy
  :: (Bundle a, Bundle b)
  => ((HasClockReset domain 'Source 'Asynchronous) =>
      Unbundled domain a -> Unbundled domain b)
  -- ^ Function we want to simulate, whose components potentially needs an
  -- implicitly routed clock (and reset)
  -> [a]
  -> [b]
simulateB_lazy f =
  let ?clk = unsafeCoerce (Clock @System (pure True))
      ?rst = unsafeCoerce (Async @System (True :- pure False))
  in  S.simulateB_lazy f

-- * QuickCheck combinators

-- |  @testFor n s@ tests the signal /s/ for /n/ cycles.
testFor
  :: Int
  -- ^ The number of cycles we want to test for
  -> ((HasClockReset domain 'Source 'Asynchronous) => Signal domain Bool)
  -- ^ 'Signal' we want to evaluate, whose source potentially needs an
  -- implicitly routed clock (and reset)
  -> Property
testFor n s = property (and (CLaSH.Signal.sampleN n s))
