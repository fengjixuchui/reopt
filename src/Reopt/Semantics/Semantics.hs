------------------------------------------------------------------------
-- |
-- Module           : Reopt.Semantics
-- Description      : Defines the semantics of x86 instructions.
-- Copyright        : (c) Galois, Inc 2015
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- This is the top-level module containing the definitions for x86
-- instructions.
------------------------------------------------------------------------
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-} -- for Binop/Unop type synonyms
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Reopt.Semantics.Semantics where

import           Control.Applicative ( (<$>), (<*>) )
import           Data.Type.Equality
import           Data.Int
import           Data.Word
import           Prelude hiding (isNaN)
import           GHC.TypeLits

import           Data.Parameterized.NatRepr

import qualified Reopt.Machine.StateNames as N
import           Reopt.Semantics.Monad

-- * Preliminaries

type Binop = IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
type Unop  = IsLocationBV m n => MLocation m (BVType n) -> m ()
type UnopV = Semantics m => Value m (BVType n) -> m ()

uadd4_overflows :: ( 4 <= n, IsValue v)
                => v (BVType n) -> v (BVType n) -> v BoolType
uadd4_overflows x y = uadd_overflows (least_nibble x) (least_nibble y)

usub4_overflows :: (4 <= n, IsValue v)
                => v (BVType n) -> v (BVType n) -> v BoolType
usub4_overflows x y = usub_overflows (least_nibble x) (least_nibble y)

uadc4_overflows :: ( IsLeq 4 n
                   , IsValue v
                   )
                => v (BVType n) -> v (BVType n) -> v BoolType -> v BoolType
uadc4_overflows x y c = uadc_overflows (least_nibble x) (least_nibble y) c

-- | Update flags with given result value.
set_result_flags :: IsLocationBV m n => Value m (BVType n) -> m ()
set_result_flags res = do
  sf_loc .= msb res
  zf_loc .= is_zero res
  pf_loc .= even_parity (least_byte res)

-- | Assign value to location and update corresponding flags.
set_result_value :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
set_result_value dst res = do
  set_result_flags res
  dst .= res

-- | Set bitwise flags.
set_bitwise_flags :: IsLocationBV m n => Value m (BVType n) -> m ()
set_bitwise_flags res = do
  of_loc .= false
  cf_loc .= false
  set_undefined af_loc
  set_result_flags res

push :: Semantics m => Value m (BVType n) -> m ()
push v = do old_sp <- get rsp
            let delta   = bvLit n64 $ natValue sz `div` 8 -- delta in bytes
                new_sp  = old_sp `bvSub` delta
                sp_addr = mkBVAddr sz new_sp
            sp_addr .= v
            rsp     .= new_sp
     where
       sz = bv_width v

pop :: IsLocationBV m n => NatRepr n -> m (Value m (BVType n))
pop sz = do
  old_sp <- get rsp
  let delta   = bvLit n64 $ natValue sz `div` 8 -- delta in bytes
      new_sp  = old_sp `bvAdd` delta
      sp_addr = mkBVAddr sz old_sp
  v   <- get sp_addr
  rsp .= new_sp
  return v

-- ** Condition codes

cond_a, cond_ae, cond_b, cond_be, cond_g, cond_ge, cond_l, cond_le, cond_o, cond_p, cond_s, cond_z,
  cond_no, cond_np, cond_ns, cond_nz :: Semantics m => m (Value m BoolType)
cond_a = (\c z -> complement c .&. complement z) <$> get cf_loc <*> get zf_loc
cond_ae  = complement <$> get cf_loc
cond_b   = get cf_loc
cond_be  = (.|.) <$> get cf_loc <*> get zf_loc
cond_g   = (\z s o -> complement z .&. (s `bvXor` o)) <$> get zf_loc <*> get sf_loc <*> get of_loc
cond_ge  = (\s o   -> s `bvXor` o) <$> get sf_loc <*> get of_loc
cond_l   = complement <$> cond_ge
cond_le  = complement <$> cond_g
cond_o   = get of_loc
cond_p   = get pf_loc
cond_s   = get sf_loc
cond_z   = get zf_loc
cond_no  = complement <$> cond_o
cond_np  = complement <$> cond_p
cond_ns  = complement <$> cond_s
cond_nz  = complement <$> cond_z

-- * General Purpose Instructions
-- ** Data Transfer Instructions

-- FIXME: has the side effect of reading r, but this should be safe because r can only be a register.
exec_cmovcc :: Semantics m => m (Value m BoolType) -> MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_cmovcc cc r y = do
  c <- cc
  r_v <- get r
  r .= mux c y r_v
  -- when_ a (r .= y)

-- | Run bswap instruction.
exec_bswap :: IsLocationBV m n => MLocation m (BVType n) -> m ()
exec_bswap = modify reverse_bytes

-- | Sign extend al -> ax, ax -> eax, eax -> rax, resp.
exec_cbw, exec_cwde, exec_cdqe :: Semantics m => m ()
exec_cbw = do v <- get (reg_low8 N.rax)
              reg_low16 N.rax .= sext n16 v

exec_cwde = do v <- get (reg_low16 N.rax)
               reg_low32 N.rax .= sext n32 v

exec_cdqe = do v <- get (reg_low32 N.rax)
               rax .= sext n64 v

-- FIXME: special segment stuff?
-- FIXME: CR and debug regs?
exec_mov :: Semantics m =>  MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_mov l v = l .= v

-- And exec_movsxd
exec_movsx_d :: (Semantics m, 1 <= n', n' <= n)
             =>  MLocation m (BVType n) -> Value m (BVType n') -> m ()
exec_movsx_d l v = l .= sext (loc_width l) v

exec_movzx :: (Semantics m, 1 <= n', n' <= n)
           =>  MLocation m (BVType n)
           -> Value m (BVType n') -> m ()
exec_movzx l v = l .= uext (loc_width l) v

exec_pop :: Unop
exec_pop l = do v <- pop (loc_width l)
                l .= v

exec_push :: UnopV
exec_push v = push v

exec_xchg :: IsLocationBV m n => MLocation m (BVType n) -> MLocation m (BVType n) -> m ()
exec_xchg l l' = do v  <- get l
                    v' <- get l'
                    l  .= v'
                    l' .= v

-- ** Binary Arithmetic Instructions

exec_adc :: IsLocationBV m n
         => MLocation m (BVType n)
         -> Value m (BVType n)
         -> m ()
exec_adc dst y = do
  -- Get current value stored in destination.
  dst_val <- get dst
  -- Get current value of carry bit
  c <- get cf_loc
  -- Set overflow and arithmetic flags
  of_loc .= sadc_overflows  dst_val y c
  af_loc .= uadc4_overflows dst_val y c
  cf_loc .= uadc_overflows  dst_val y c
  -- Set result value.
  set_result_value dst (dst_val `bvAdd` y `bvAdd` uext (loc_width dst) c)

-- | @add@
exec_add :: IsLocationBV m n
         => MLocation m (BVType n)
         -> Value m (BVType n)
         -> m ()
exec_add dst y = do
  -- Get current value stored in destination.
  dst_val <- get dst
  -- Set overflow and arithmetic flags
  of_loc .= sadd_overflows  dst_val y
  af_loc .= uadd4_overflows dst_val y
  cf_loc .= uadd_overflows  dst_val y
  -- Set result value.
  set_result_value dst (dst_val `bvAdd` y)

-- FIXME: we don't need a location, just a value.
exec_cmp :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_cmp dst y = do dst_val <- get dst
                    -- Set overflow and arithmetic flags
                    of_loc .= ssub_overflows  dst_val y
                    af_loc .= usub4_overflows dst_val y
                    cf_loc .= usub_overflows  dst_val y
                    -- Set result value.
                    set_result_flags (dst_val `bvSub` y)

exec_dec :: IsLocationBV m n => MLocation m (BVType n) -> m ()
exec_dec dst = do dst_val <- get dst
                  let v1 = bvLit (bv_width dst_val) (1 :: Int)
                  -- Set overflow and arithmetic flags
                  of_loc .= ssub_overflows  dst_val v1
                  af_loc .= usub4_overflows dst_val v1
                  -- no carry flag
                  -- Set result value.
                  set_result_value dst (dst_val `bvSub` v1)

-- | div instruction
exec_div :: forall m n. IsLocationBV m n => Value m (BVType n) -> m ()
exec_div v0
    -- 8-bit division.
  | Just Refl <- testEquality (bv_width v0) n8 = do
    w <- get (reg_low16 N.rax)
    go1 (reg_low8 N.rax) (reg_high8 N.rax) w v0
    -- 16-bit division.
  | Just Refl <- testEquality (bv_width v0) n16 =
    go2 (reg_low16 N.rax) (reg_low16 N.rdx) v0
    -- 32-bit division.
  | Just Refl <- testEquality (bv_width v0) n32 =
    go2 (reg_low32 N.rax) (reg_low32 N.rdx) v0
    -- 64-bit division.
  | Just Refl <- testEquality (bv_width v0) n64 =
    go2 rax rdx v0
    -- Unsupported division.
  | otherwise =
    fail "div: Unknown bit width"
  where
    go2 :: (1 <= n + n, n <= n + n)
        => MLocation m (BVType n)
        -> MLocation m (BVType n)
        -> Value m (BVType n) -- The denominator y in the divison x/y
        -> m ()
    go2 ax dx v = do
      axv <- get ax
      dxv <- get dx
      go1 ax dx (bvCat dxv axv) v

    go1 :: (1 <= n + n, n <= n + n) -- Add obvious constraint to help Haskell type-checker.
        => MLocation m (BVType n) -- Location to store quotient
        -> MLocation m (BVType n) -- Location to store remainder.
        -> Value m (BVType (n + n)) -- The numerator x in the division x/y
        -> Value m (BVType n)       -- The denominator y in the divison x/y
        -> m ()
    go1 quotL remL w v = do
      (q,r) <- bvDiv w v
      set_undefined cf_loc
      set_undefined of_loc
      set_undefined sf_loc
      set_undefined af_loc
      set_undefined pf_loc
      set_undefined zf_loc
      quotL .= q
      remL  .= r

exec_idiv :: forall m n
           . (IsLocationBV m n)
          => Value m (BVType n)
          -> m ()
exec_idiv v
  | Just Refl <- testEquality w n8  = do
    dividend <- get (reg_low16 N.rax)
    do_exec_idiv (reg_low8 N.rax) (reg_high8 N.rax) dividend v
  | Just Refl <- testEquality w n16 =
    go2 (reg_low16 N.rax) (reg_low16 N.rdx)
  | Just Refl <- testEquality w n32 =
    go2 (reg_low32 N.rax) (reg_low32 N.rdx)
  | Just Refl <- testEquality w n64 =
    go2 rax rdx
  | otherwise =
    fail "div: Unknown bit width"
  where
    w :: NatRepr n
    w = bv_width v
    go2 :: (n <= n + n) => MLocation m (BVType n) -> MLocation m (BVType n) -> m ()
    go2 ax dx = do
      axv <- get ax
      dxv <- get dx
      do_exec_idiv ax dx (bvCat dxv axv) v

do_exec_idiv :: forall m n
              . (IsLocationBV m n)
             => MLocation m (BVType n)
                -- ^ Location to store quotient
             -> MLocation m (BVType n)
                -- ^ Location to store remainder
             -> Value m (BVType (n + n))
                -- ^ The dividend
             -> Value m (BVType n)
                -- ^ The divisor
             -> m ()
do_exec_idiv quotL remL w v = do
  (q,r) <- bvSignedDiv w v
  quotL .= q
  remL  .= r
  set_undefined cf_loc
  set_undefined of_loc
  set_undefined sf_loc
  set_undefined af_loc
  set_undefined pf_loc
  set_undefined zf_loc

exec_inc :: IsLocationBV m n => MLocation m (BVType n) -> m ()
exec_inc dst = do
  -- Get current value stored in destination.
  dst_val <- get dst
  let y  = bvLit (bv_width dst_val) (1 :: Int)
  -- Set overflow and arithmetic flags
  of_loc .= sadd_overflows  dst_val y
  af_loc .= uadd4_overflows dst_val y
  -- no cf_loc
  -- Set result value.
  set_result_value dst (dst_val `bvAdd` y)

set_reg_pair :: (Semantics m, 1 <= n)
             => MLocation m (BVType n)
             -> MLocation m (BVType n)
             -> Value m (BVType (n + n))
             -> m ()
set_reg_pair upperL lowerL v = do
  let (upper, lower) = bvSplit v
  lowerL .= lower
  upperL .= upper

-- FIXME: is this the right way around?
exec_mul :: forall m n
          . (IsLocationBV m n)
         => Value m (BVType n)
         -> m ()
exec_mul v
  | Just Refl <- testEquality (bv_width v) n8  =
    go (\v' -> reg_low16 N.rax .= v') (reg_low8 N.rax)
  | Just Refl <- testEquality (bv_width v) n16 =
    go (set_reg_pair (reg_low16 N.rdx) (reg_low16 N.rax)) (reg_low16 N.rax)
  | Just Refl <- testEquality (bv_width v) n32 =
    go (set_reg_pair (reg_low32 N.rdx) (reg_low32 N.rax)) (reg_low32 N.rax)
  | Just Refl <- testEquality (bv_width v) n64 =
    go (set_reg_pair rdx rax) rax
  | otherwise =
    fail "mul: Unknown bit width"
  where
    go :: (1 <= n+n, n <= n+n)
       => (Value m (BVType (n + n)) -> m ()) -> MLocation m (BVType n) -> m ()
    go f l = do
      v' <- get l
      let sz = addNat (bv_width v) (bv_width v)
          r  = uext sz v' `bvMul` uext sz v -- FIXME: uext here is OK?
          upper_r = fst (bvSplit r) :: Value m (BVType n)
      set_undefined sf_loc
      set_undefined af_loc
      set_undefined pf_loc
      set_undefined zf_loc
      let does_overflow = complement (is_zero upper_r)
      of_loc .= does_overflow
      cf_loc .= does_overflow
      f r

really_exec_imul :: forall m n
                  . (IsLocationBV m n)
                 => Value m (BVType n)
                 -> Value m (BVType n)
                 -> (Value m (BVType (n + n)) -> m ())
                 -> m ()
really_exec_imul v v' f = do
  let w = bv_width v
  let sz = addNat w w
  let w_is_pos :: LeqProof 1 n
      w_is_pos = LeqProof
  withLeqProof (leqAdd w_is_pos w) $ do
  withLeqProof (addIsLeq w w) $ do
  let r :: Value m (BVType (n + n))
      r  = sext sz v' .* sext sz v
      (_, lower_r :: Value m (BVType n)) = bvSplit r
  set_undefined af_loc
  set_undefined pf_loc
  set_undefined zf_loc
  sf_loc .= msb lower_r
  let does_overflow = (r .=/=. sext sz lower_r)
  of_loc .= does_overflow
  cf_loc .= does_overflow
  f r

exec_imul1 :: forall m n. IsLocationBV m n => Value m (BVType n) -> m ()
exec_imul1 v
  | Just Refl <- testEquality (bv_width v) n8  =
    go (\v' -> reg_low16 N.rax .= v') (reg_low8 N.rax)
  | Just Refl <- testEquality (bv_width v) n16 =
    go (set_reg_pair (reg_low16 N.rdx) (reg_low16 N.rax)) (reg_low16 N.rax)
  | Just Refl <- testEquality (bv_width v) n32 =
    go (set_reg_pair (reg_low32 N.rdx) (reg_low32 N.rax)) (reg_low32 N.rax)
  | Just Refl <- testEquality (bv_width v) n64 =
    go (set_reg_pair rdx rax) rax
  | otherwise =
    fail "imul: Unknown bit width"
  where
    go :: (1 <= n + n, n <= n + n)
       => (Value m (BVType (n + n)) -> m ()) -> MLocation m (BVType n) -> m ()
    go f l = do v' <- get l
                really_exec_imul v v' f

-- FIXME: clag from exec_mul, exec_imul
exec_imul2_3 :: forall m n n'
              . (IsLocationBV m n, 1 <= n', n' <= n)
             => MLocation m (BVType n) -> Value m (BVType n) -> Value m (BVType n') -> m ()
exec_imul2_3 l v v' = do
  withLeqProof (dblPosIsPos (LeqProof :: LeqProof 1 n)) $ do
  really_exec_imul v (sext (bv_width v) v') $ \r -> l .= snd (bvSplit r)

-- | Should be equiv to 0 - *l
exec_neg :: (IsLocationBV m n) =>  MLocation m (BVType n) -> m ()
exec_neg l = do
  v <- get l
  cf_loc .= mux (is_zero v) false true
  let r = bvNeg v
      zero = bvLit (bv_width v) (0 :: Integer)
  of_loc .= ssub_overflows  zero v
  af_loc .= usub4_overflows zero v
  set_result_value l r

exec_sbb :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_sbb l v = do cf <- get cf_loc
                  exec_sub l (v `bvAdd` uext (bv_width v) cf)

-- FIXME: duplicates subtraction term by calling exec_cmp
exec_sub :: Binop
exec_sub l v = do v0 <- get l
                  l .= (v0 `bvSub` v)
                  exec_cmp l v -- set flags

-- ** Decimal Arithmetic Instructions
-- ** Logical Instructions

-- | And two values together.
exec_and :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_and r y = do
  x <- get r
  let z = x .&. y
  set_bitwise_flags z
  r .= z

exec_not :: (Semantics m, 1 <= n) => MLocation m (BVType n) -> m ()
exec_not = modify complement

exec_or :: Binop
exec_or l v = do
  v' <- get l
  set_undefined af_loc
  of_loc .= false
  cf_loc .= false
  set_result_value l (v' .|. v)

exec_xor :: Binop
exec_xor l v = do
  v0 <- get l
  let r = v0 `bvXor` v
  set_bitwise_flags r
  l .= r

-- ** Shift and Rotate Instructions


really_exec_shift :: (1 <= n', n' <= n, IsLocationBV m n)
                  => MLocation m (BVType n)
                  -> Value m (BVType n')
                     -- Operation for performing the shift.
                     -- Takes value as first argument and shift amount as second arg.
                  -> (Value m (BVType n) -> Value m (BVType n) -> Value m (BVType n))
                     -- Operation for constructing new carry flag "cf" value.
                  -> (Value m (BVType n) -> Value m (BVType n')
                                         -> Value m (BVType n')
                                         -> Value m BoolType)
                     -- Operation for constructing new overflow flag "of" value.
                  -> (Value m (BVType n) -> Value m (BVType n)
                                         -> Value m BoolType
                                         -> Value m BoolType)
                  -> m ()
really_exec_shift l count do_shift mk_cf mk_of = do
  v    <- get l
  -- The intel manual says that the count is masked to give an upper
  -- bound on the time the shift takes, with a mask of 63 in the case
  -- of a 64 bit operand, and 31 in the other cases.
  let nbits :: Int
      nbits =
        case testLeq (bv_width v) n32 of
          Just LeqProof -> 32
          _             -> 64
      count_mask = bvLit (bv_width count) (nbits - 1)
      --
      low_count = count .&. count_mask  -- FIXME: prefer mod?
      r = do_shift v (uext (bv_width v) low_count)

  -- When the count is zero, nothing happens, in particular, no flags change
  unless_ (is_zero low_count) $ do
    let dest_width = bvLit (bv_width low_count) (natValue (bv_width v))

    let new_cf = mk_cf v dest_width low_count
    cf_undef <- make_undefined knownType
    cf_loc .= mux (low_count `bvUlt` dest_width) new_cf cf_undef

    let low1 = bvLit (bv_width low_count) (1 :: Int)

    of_undef <- make_undefined knownType
    of_loc .= mux (low_count .=. low1) (mk_of v r new_cf) of_undef

    set_undefined af_loc
    set_result_value l r

-- FIXME: could be 8 instead of n' here ...
exec_shl :: (1 <= n', n' <= n, IsLocationBV m n)
         => MLocation m (BVType n) -> Value m (BVType n') -> m ()
exec_shl l count = really_exec_shift l count bvShl mk_cf mk_of
  where mk_cf v dest_width low_count = bvBit v (dest_width `bvSub` low_count)
        mk_of _ r new_cf = msb r `bvXor` new_cf

exec_shr :: (1 <= n', n' <= n, IsLocationBV m n)
         => MLocation m (BVType n)
         -> Value m (BVType n') -> m ()
exec_shr l count = really_exec_shift l count bvShr mk_cf mk_of
  where mk_cf v _ low_count = bvBit v (low_count `bvSub` bvLit (bv_width low_count) (1 :: Int))
        mk_of v _ _         = msb v

-- FIXME: we can factor this out as above, but we need to check the CF
-- for SAR (intel manual says it is only undefined for shl/shr when
-- the shift is >= the bit width.
exec_sar :: (1 <= n', n' <= n, IsLocationBV m n)
         => MLocation m (BVType n) -> Value m (BVType n') -> m ()
exec_sar l count = do
  v    <- get l
  -- The intel manual says that the count is masked to give an upper
  -- bound on the time the shift takes, with a mask of 63 in the case
  -- of a 64 bit operand, and 31 in the other cases.
  let nbits :: Int = case testLeq (bv_width v) n32 of
                       Just LeqProof -> 32
                       _             -> 64
      countMASK = bvLit (bv_width v) (nbits - 1)
      low_count = uext (bv_width v) count .&. countMASK  -- FIXME: prefer mod?
      r = bvSar v low_count

  -- When the count is zero, nothing happens, in particular, no flags change
  when_ (complement $ is_zero low_count) $ do
    let dest_width = bvLit (bv_width low_count) (natValue (bv_width v))
    let new_cf = bvBit v (low_count `bvSub` bvLit (bv_width low_count) (1 :: Int))

    -- FIXME: correct?  we assume here that we will get the sign bit ...
    cf_loc .= mux (low_count `bvUlt` dest_width) new_cf (msb v)

    ifte_ (low_count .=. bvLit (bv_width low_count) (1 :: Int))
      (of_loc .= false)
      (set_undefined of_loc)

    set_undefined af_loc
    set_result_value l r

-- FIXME: use really_exec_shift above?
exec_rol :: (1 <= n', n' <= n, IsLocationBV m n)
         => MLocation m (BVType n)
         -> Value m (BVType n')
         -> m ()
exec_rol l count = do
  v    <- get l
  -- The intel manual says that the count is masked to give an upper
  -- bound on the time the shift takes, with a mask of 63 in the case
  -- of a 64 bit operand, and 31 in the other cases.
  let nbits :: Int = case testLeq (bv_width v) n32 of
                       Just LeqProof -> 32
                       _             -> 64
      countMASK = bvLit (bv_width v) (nbits - 1)
      low_count = uext (bv_width v) count .&. countMASK
      -- Note: The manual includes a mod, but it seems like the mask is sufficient.
      --                  `bvMod` (bvLit (bv_width v) (natValue (bv_width v)))
      r = bvRol v low_count

  -- When the count is zero, nothing happens, in particular, no flags change
  when_ (complement $ is_zero low_count) $ do
    let new_cf = bvBit r (bvLit (bv_width r) (0 :: Int))

    cf_loc .= new_cf

    ifte_ (low_count .=. bvLit (bv_width low_count) (1 :: Int))
      (of_loc .= (msb r `bvXor` new_cf))
      (set_undefined of_loc)

    l .= r


-- ** Bit and Byte Instructions

exec_bsf :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_bsf r y = do
  zf_loc .= is_zero y
  set_undefined cf_loc
  set_undefined of_loc
  set_undefined sf_loc
  set_undefined af_loc
  set_undefined pf_loc
  r .= bsf y

exec_bsr :: IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_bsr r y = do
  zf_loc .= is_zero y
  set_undefined cf_loc
  set_undefined of_loc
  set_undefined sf_loc
  set_undefined af_loc
  set_undefined pf_loc
  r .= bsr y

exec_test :: Binop
exec_test l v = do
  v' <- get l
  let r = v' .&. v
  set_bitwise_flags r

exec_setcc :: Semantics m => m (Value m BoolType) -> MLocation m (BVType 8) -> m ()
exec_setcc cc l = do
  c <- cc
  l .= mux c (bvKLit 1) (bvKLit 0)

-- ** Control Transfer Instructions

really_exec_call :: IsLocationBV m 64 => Value m (BVType 64) -> m ()
really_exec_call next_pc = do
  old_pc <- get rip
  push old_pc -- push value of next instruction
  rip .= next_pc

exec_call_relative :: IsLocationBV m 64 => Value m (BVType 64) -> m ()
exec_call_relative off = do
  old_pc <- get rip
  let next_pc = old_pc `bvAdd` off
  really_exec_call next_pc

exec_call_absolute :: IsLocationBV m 64 => Value m (BVType 64) -> m ()
exec_call_absolute = really_exec_call

exec_jcc :: Semantics m => m (Value m BoolType) -> Value m (BVType 64) -> m ()
exec_jcc cc off = do
  a <- cc
  when_ a $ jump_off off

jump_off :: Semantics m => Value m (BVType 64) -> m ()
jump_off off = do
  old_pc <- get rip
  let next_pc = old_pc `bvAdd` off
  rip .= next_pc

exec_jmp_absolute :: Semantics m => Value m (BVType 64) -> m ()
exec_jmp_absolute v = rip .= v

exec_ret :: Semantics m => Maybe Word16 -> m ()
exec_ret m_off = do
  next_ip <- pop n64
  case m_off of
    Nothing  -> return ()
    Just off -> modify (bvAdd (bvLit n64 off)) rsp
  rip .= next_ip

-- ** String Instructions

-- | MOVS/MOVSB Move string/Move byte string
-- MOVS/MOVSW Move string/Move word string
-- MOVS/MOVSD Move string/Move doubleword string

-- FIXME: this will conflict on merge, sorry.
regLocation :: NatRepr n -> N.RegisterName N.GP -> Location addr (BVType n)
regLocation sz
  | Just Refl <- testEquality sz n8  = reg_low8
  | Just Refl <- testEquality sz n16 = reg_low16
  | Just Refl <- testEquality sz n32 = reg_low32
  | Just Refl <- testEquality sz n64 = Register
  | otherwise = fail "regLocation: Unknown bit width"

-- FIXME: probably doesn't work for 32 bit address sizes
-- arguments are only for the size, they are fixed at rsi/rdi
exec_movs :: (IsLocationBV m n, n <= 64)
          => Bool -- Flag indicating if RepPrefix appeared before instruction
          -> MLocation m (BVType n)
          -> MLocation m (BVType n)          
          -> m ()
exec_movs False dest_loc _src_loc = do
  -- The direction flag indicates post decrement or post increment.
  df <- get df_loc
  src  <- get rsi
  dest <- get rdi
  v' <- get $ mkBVAddr sz dest
  exec_cmp (mkBVAddr sz src) v' -- FIXME: right way around?
  let szv = bvLit n64 (natValue sz)
  rsi .= mux df (src  .- szv) (src  .+ szv)
  rdi .= mux df (dest .- szv) (dest .+ szv)
  where
    sz = loc_width dest_loc
exec_movs True dest_loc _src_loc = do
  -- The direction flag indicates post decrement or post increment.
  df <- get df_loc
  src  <- get rsi
  dest <- get rdi
  let nbytesv = bvLit n64 (toInteger nbytes)
  count <- uext n64 <$> get count_reg
  let total_bytes = count .* nbytesv
  -- FIXME: we might need direction for overlapping regions
  count_reg .= bvLit (loc_width count_reg) (0::Integer)
  ifte_ df
        (do memmove nbytes count src dest True
            rsi .= src  .- total_bytes
            rdi .= dest .- total_bytes)
        (do memmove nbytes count src dest False
            rsi .= (src  .+ total_bytes)
            rdi .= (dest .+ total_bytes))
  where
    count_reg = regLocation sz N.rcx    
    sz = loc_width dest_loc
    nbytes = fromInteger (natValue sz) `div` 8 
      
-- FIXME: can also take rep prefix
-- FIXME: we ignore the aso here.  
-- | CMPS/CMPSB Compare string/Compare byte string
-- CMPS/CMPSW Compare string/Compare word string
-- CMPS/CMPSD Compare string/Compare doubleword string
exec_cmps :: IsLocationBV m n => Bool
             -> MLocation m (BVType n)
             -> MLocation m (BVType n)
             -> m ()
exec_cmps repz_pfx loc_rsi _loc_rdi = do
  -- The direction flag indicates post decrement or post increment.
  df <- get df_loc
  v_rsi <- get rsi
  v_rdi <- get rdi
  if repz_pfx
    then do count <- get rcx
            ifte_ (count .=. bvKLit 0)
              (return ())
              (do_memcmp df v_rsi v_rdi count)
    else do v' <- get $ mkBVAddr sz v_rdi
            exec_cmp (mkBVAddr sz v_rsi) v' -- FIXME: right way around?
            rsi .= mux df (v_rsi  `bvSub` szv) (v_rsi `bvAdd` szv)
            rdi .= mux df (v_rdi  `bvSub` szv) (v_rdi `bvAdd` szv)
  where
    sz  = loc_width loc_rsi
    szv = bvLit n64 $ natValue sz
    do_memcmp df src dest count = do
      memcmp sz count df src dest
      nsame <- get rax -- FIXME: this should really be returned by memcmp
      let equal = (nsame .=. count)
          nwordsSeen = mux equal count (count `bvSub` (nsame `bvAdd` bvKLit 1))

      -- we need to set the flags as if the last comparison was done, hence this.
      let lastWordBytes = (nwordsSeen `bvSub` bvKLit 1) `bvMul` szv
          lastSrc  = mux df (src  `bvSub` lastWordBytes) (src  `bvAdd` lastWordBytes)
          lastDest = mux df (dest `bvSub` lastWordBytes) (dest `bvAdd` lastWordBytes)

      v' <- get $ mkBVAddr sz lastDest
      exec_cmp (mkBVAddr sz lastSrc) v' -- FIXME: right way around?

      -- we do this to make it obvious so repz cmpsb ; jz ... is clear
      zf_loc .= equal
      let nbytes = nwordsSeen `bvMul` (bvLit n64 $ natValue sz `div` 8)

      rsi .= mux df (src  `bvSub` nbytes) (src  `bvAdd` nbytes)
      rdi .= mux df (dest `bvSub` nbytes) (dest `bvAdd` nbytes)
      rcx .= (count .- nwordsSeen)

-- SCAS/SCASB Scan string/Scan byte string
-- SCAS/SCASW Scan string/Scan word string
-- SCAS/SCASD Scan string/Scan doubleword string
-- LODS/LODSB Load string/Load byte string
-- LODS/LODSW Load string/Load word string
-- LODS/LODSD Load string/Load doubleword string

-- | STOS/STOSB Store string/Store byte string
-- STOS/STOSW Store string/Store word string
-- STOS/STOSD Store string/Store doubleword string
exec_stos :: (IsLocationBV m n, n <= 64)
          => Bool -- Flag indicating if RepPrefix appeared before instruction
          -> MLocation m (BVType n)
          -> MLocation m (BVType n)          
          -> m ()
exec_stos False _dest_loc val_loc = do
  -- The direction flag indicates post decrement or post increment.
  df <- get df_loc
  dest <- get rdi
  v    <- get val_loc
  let szv = bvLit n64 (natValue sz)
  let neg_szv = bvLit n64 (negate (natValue sz))
  mkBVAddr sz dest .= v
  rdi .= dest .+ (mux df neg_szv szv)
  where
    sz = loc_width val_loc
exec_stos True _dest_loc val_loc = do
  -- The direction flag indicates post decrement or post increment.
  df <- get df_loc
  dest <- get rdi
  v    <- get val_loc
  let szv = bvLit n64 (natValue sz)
  count <- uext n64 <$> get count_reg
  let nbytes_off = (count `bvSub` bvKLit 1) `bvMul` szv
      nbytes     = count `bvMul` szv
  ifte_ df
        (do memset count v (dest .- nbytes_off)
            rdi .= dest .- nbytes
            rcx .= bvKLit 0)
        (do memset count v dest
            rdi .= dest .+ nbytes
            rcx .= bvKLit 0)
  where
    sz = loc_width val_loc
    count_reg = regLocation sz N.rcx
    


-- REP        Repeat while ECX not zero
-- REPE/REPZ  Repeat while equal/Repeat while zero
-- REPNE/REPNZ Repeat while not equal/Repeat while not zero

-- ** I/O Instructions
-- ** Enter and Leave Instructions

exec_leave :: Semantics m => m ()
exec_leave = do bp_v <- get rbp
                rsp .= bp_v
                bp_v' <- pop n64
                rbp .= bp_v'

-- ** Flag Control (EFLAG) Instructions

-- | Run clc instruction.
exec_clc :: Semantics m => m ()
exec_clc = cf_loc .= false

-- | Run cld instruction.
exec_cld :: Semantics m => m ()
exec_cld = df_loc .= false

-- ** Segment Register Instructions
-- ** Miscellaneous Instructions

exec_lea :: Semantics m =>  MLocation m (BVType n) -> Value m (BVType n) -> m ()
exec_lea l v = l .= v

-- ** Random Number Generator Instructions
-- ** BMI1, BMI2

-- * X86 FPU instructions

type FPUnop  = Semantics m => FloatInfoRepr flt -> MLocation m (FloatType flt) -> m ()
type FPUnopV = Semantics m => FloatInfoRepr flt -> Value m (FloatType flt) -> m ()
type FPBinop = Semantics m => FloatInfoRepr flt_d -> MLocation m (FloatType flt_d) -> FloatInfoRepr flt_s -> Value m (FloatType flt_s) -> m ()

-- ** Data transfer instructions

-- | FLD Load floating-point value
exec_fld :: FPUnopV
exec_fld fir v = x87Push (fpCvt fir X86_80FloatRepr v)

-- | FST Store floating-point value
exec_fst :: FPUnop
exec_fst fir l = do
  v <- get (X87StackRegister 0)
  set_undefined c0_loc
  set_undefined c2_loc
  set_undefined c3_loc
  c1_loc .= fpCvtRoundsUp X86_80FloatRepr fir v
  l .= fpCvt X86_80FloatRepr fir v

-- | FSTP Store floating-point value
exec_fstp :: FPUnop
exec_fstp fir l = exec_fst fir l >> x87Pop

-- FILD Load integer
-- FIST Store integer
-- FISTP1 Store integer and pop
-- FBLD Load BCD
-- FBSTP Store BCD and pop
-- FXCH Exchange registers
-- FCMOVE Floating-point conditional   move if equal
-- FCMOVNE Floating-point conditional  move if not equal
-- FCMOVB Floating-point conditional   move if below
-- FCMOVBE Floating-point conditional  move if below or equal
-- FCMOVNB Floating-point conditional  move if not below
-- FCMOVNBE Floating-point conditional move if not below or equal
-- FCMOVU Floating-point conditional   move if unordered
-- FCMOVNU Floating-point conditional  move if not unordered

-- ** Basic arithmetic instructions

fparith :: Semantics m =>
           (forall flt
            . FloatInfoRepr flt
            -> Value m (FloatType flt)
            -> Value m (FloatType flt)
            -> Value m (FloatType flt))
           -> (forall flt
               . FloatInfoRepr flt
               -> Value m (FloatType flt)
               -> Value m (FloatType flt)
               -> Value m BoolType)
           -> FloatInfoRepr flt_d
           -> MLocation m (FloatType flt_d)
           -> FloatInfoRepr flt_s
           -> Value m (FloatType flt_s)
           -> m ()
fparith op opRoundedUp fir_d l fir_s v = do
  let up_v = fpCvt fir_s fir_d v
  v' <- get l
  set_undefined c0_loc
  c1_loc .= opRoundedUp fir_d v' up_v
  set_undefined c2_loc
  set_undefined c3_loc
  l .= op fir_d v' up_v

-- | FADD Add floating-point
exec_fadd :: FPBinop
exec_fadd = fparith fpAdd fpAddRoundedUp

-- FADDP Add floating-point and pop
-- FIADD Add integer

-- | FSUB Subtract floating-point
exec_fsub :: FPBinop
exec_fsub = fparith fpSub fpSubRoundedUp

-- | FSUBP Subtract floating-point and pop
exec_fsubp :: FPBinop
exec_fsubp fir_d l fir_s v = exec_fsub fir_d l fir_s v >> x87Pop

-- FISUB Subtract integer

-- | FSUBR Subtract floating-point reverse
exec_fsubr :: FPBinop
exec_fsubr = fparith (reverseOp fpSub) (reverseOp fpSubRoundedUp)
  where
    reverseOp f = \fir x y -> f fir y x

-- | FSUBRP Subtract floating-point reverse and pop
exec_fsubrp :: FPBinop
exec_fsubrp fir_d l fir_s v = exec_fsubr fir_d l fir_s v >> x87Pop

-- FISUBR Subtract integer reverse

-- FIXME: we could factor out commonalities between this and fadd
-- | FMUL Multiply floating-point
exec_fmul :: FPBinop
exec_fmul = fparith fpMul fpMulRoundedUp

-- FMULP Multiply floating-point and pop
-- FIMUL Multiply integer
-- FDIV Divide floating-point
-- FDIVP Divide floating-point and pop
-- FIDIV Divide integer
-- FDIVR Divide floating-point reverse
-- FDIVRP Divide floating-point reverse and pop
-- FIDIVR Divide integer reverse
-- FPREM Partial remainder
-- FPREM1 IEEE Partial remainder
-- FABS Absolute value
-- FCHS Change sign
-- FRNDINT Round to integer
-- FSCALE Scale by power of two
-- FSQRT Square root
-- FXTRACT Extract exponent and significand

-- ** Comparison instructions

-- FCOM Compare floating-point
-- FCOMP Compare floating-point and pop
-- FCOMPP Compare floating-point and pop twice
-- FUCOM Unordered compare floating-point
-- FUCOMP Unordered compare floating-point and pop
-- FUCOMPP Unordered compare floating-point and pop twice
-- FICOM Compare integer
-- FICOMP Compare integer and pop
-- FCOMI Compare floating-point and set EFLAGS
-- FUCOMI Unordered compare floating-point and set EFLAGS
-- FCOMIP Compare floating-point, set EFLAGS, and pop
-- FUCOMIP Unordered compare floating-point, set EFLAGS, and pop
-- FTST Test floating-point (compare with 0.0)
-- FXAM Examine floating-point

-- ** Transcendental instructions

-- FSIN Sine
-- FCOS Cosine
-- FSINCOS Sine and cosine
-- FPTAN Partial tangent
-- FPATAN Partial arctangent
-- F2XM1 2x − 1
-- FYL2X y∗log2x
-- FYL2XP1 y∗log2(x+1)

-- ** Load constant instructions

-- FLD1 Load +1.0
-- FLDZ Load +0.0
-- FLDPI Load π
-- FLDL2E Load log2e
-- FLDLN2 Load loge2
-- FLDL2T Load log210
-- FLDLG2 Load log102


-- ** x87 FPU control instructions

-- FINCSTP Increment FPU register stack pointer
-- FDECSTP Decrement FPU register stack pointer
-- FFREE Free floating-point register
-- FINIT Initialize FPU after checking error conditions
-- FNINIT Initialize FPU without checking error conditions
-- FCLEX Clear floating-point exception flags after checking for error conditions
-- FNCLEX Clear floating-point exception flags without checking for error conditions
-- FSTCW Store FPU control word after checking error conditions

-- | FNSTCW Store FPU control word without checking error conditions
exec_fnstcw :: Semantics m => MLocation m (BVType 16) -> m ()
exec_fnstcw l = do
  v <- packWord N.x87ControlBitPacking
  set_undefined c0_loc
  set_undefined c1_loc
  set_undefined c2_loc
  set_undefined c3_loc
  l .= v

-- FLDCW Load FPU control word
-- FSTENV Store FPU environment after checking error conditions
-- FNSTENV Store FPU environment without checking error conditions
-- FLDENV Load FPU environment
-- FSAVE Save FPU state after checking error conditions
-- FNSAVE Save FPU state without checking error conditions
-- FRSTOR Restore FPU state
-- FSTSW Store FPU status word after checking error conditions
-- FNSTSW Store FPU status word without checking error conditions
-- WAIT/FWAIT Wait for FPU
-- FNOP FPU no operation

-- * X87 FPU and SIMD State Management Instructions

-- FXSAVE Save x87 FPU and SIMD state
-- FXRSTOR Restore x87 FPU and SIMD state

-- * MMX Instructions

-- * SSE Instructions
-- ** SSE SIMD Single-Precision Floating-Point Instructions
-- *** SSE Data Transfer Instructions

-- MOVAPS Move four aligned packed single-precision floating-point values between XMM registers or between and XMM register and memory
exec_movaps :: Semantics m =>  MLocation m (BVType 128) -> Value m (BVType 128) -> m ()
exec_movaps l v = l .= v

-- MOVUPS Move four unaligned packed single-precision floating-point values between XMM registers or between and XMM register and memory
-- MOVHPS Move two packed single-precision floating-point values to an from the high quadword of an XMM register and memory
-- MOVHLPS Move two packed single-precision floating-point values from the high quadword of an XMM register to the low quadword of another XMM register
-- MOVLPS Move two packed single-precision floating-point values to an from the low quadword of an XMM register and memory
-- MOVLHPS Move two packed single-precision floating-point values from the low quadword of an XMM register to the high quadword of another XMM register
-- MOVMSKPS Extract sign mask from four packed single-precision floating-point values
-- | MOVSS Move scalar single-precision floating-point value between XMM registers or between an XMM register and memory
exec_movss :: Semantics m => MLocation m (BVType 32) -> Value m (FloatType SingleFloat) -> m ()
exec_movss l v = l .= v

-- *** SSE Packed Arithmetic Instructions

-- ADDPS Add packed single-precision floating-point values
-- ADDSS Add scalar single-precision floating-point values
-- SUBPS Subtract packed single-precision floating-point values
-- SUBSS Subtract scalar single-precision floating-point values
-- MULPS Multiply packed single-precision floating-point values
-- MULSS Multiply scalar single-precision floating-point values
-- DIVPS Divide packed single-precision floating-point values
-- DIVSS Divide scalar single-precision floating-point values
-- RCPPS Compute reciprocals of packed single-precision floating-point values
-- RCPSS Compute reciprocal of scalar single-precision floating-point values
-- SQRTPS Compute square roots of packed single-precision floating-point values
-- SQRTSS Compute square root of scalar single-precision floating-point values
-- RSQRTPS Compute reciprocals of square roots of packed single-precision floating-point values
-- RSQRTSS Compute reciprocal of square root of scalar single-precision floating-point values
-- MAXPS Return maximum packed single-precision floating-point values
-- MAXSS Return maximum scalar single-precision floating-point values
-- MINPS Return minimum packed single-precision floating-point values
-- MINSS Return minimum scalar single-precision floating-point values

-- *** SSE Comparison Instructions

-- CMPPS Compare packed single-precision floating-point values
-- CMPSS Compare scalar single-precision floating-point values
-- COMISS Perform ordered comparison of scalar single-precision floating-point values and set flags in EFLAGS register
-- UCOMISS Perform unordered comparison of scalar single-precision floating-point values and set flags in EFLAGS register

-- *** SSE Logical Instructions

-- ANDPS Perform bitwise logical AND of packed single-precision floating-point values
-- ANDNPS Perform bitwise logical AND NOT of packed single-precision floating-point values
-- ORPS Perform bitwise logical OR of packed single-precision floating-point values
-- XORPS Perform bitwise logical XOR of packed single-precision floating-point values

-- *** SSE Shuffle and Unpack Instructions

-- SHUFPS Shuffles values in packed single-precision floating-point operands
-- UNPCKHPS Unpacks and interleaves the two high-order values from two single-precision floating-point operands
-- UNPCKLPS Unpacks and interleaves the two low-order values from two single-precision floating-point operands

-- *** SSE Conversion Instructions

-- CVTPI2PS Convert packed doubleword integers to packed single-precision floating-point values
-- CVTSI2SS Convert doubleword integer to scalar single-precision floating-point value
-- CVTPS2PI Convert packed single-precision floating-point values to packed doubleword integers
-- CVTTPS2PI Convert with truncation packed single-precision floating-point values to packed doubleword integers
-- CVTSS2SI Convert a scalar single-precision floating-point value to a doubleword integer
-- CVTTSS2SI Convert with truncation a scalar single-precision floating-point value to a scalar doubleword integer

-- ** SSE MXCSR State Management Instructions

-- LDMXCSR Load MXCSR register
-- STMXCSR Save MXCSR register state

-- ** SSE 64-Bit SIMD Integer Instructions

-- PAVGB Compute average of packed unsigned byte integers
-- PAVGW Compute average of packed unsigned word integers
-- PEXTRW Extract word
-- PINSRW Insert word
-- PMAXUB Maximum of packed unsigned byte integers
-- PMAXSW Maximum of packed signed word integers
-- PMINUB Minimum of packed unsigned byte integers
-- PMINSW Minimum of packed signed word integers
-- PMOVMSKB Move byte mask
-- PMULHUW Multiply packed unsigned integers and store high result
-- PSADBW Compute sum of absolute differences
-- PSHUFW Shuffle packed integer word in MMX register

-- ** SSE Cacheability Control, Prefetch, and Instruction Ordering Instructions

-- MASKMOVQ Non-temporal store of selected bytes from an MMX register into memory
-- MOVNTQ  Non-temporal store of quadword from an MMX register into memory
-- MOVNTPS Non-temporal store of four packed single-precision floating-point
--   values from an XMM register into memory
-- PREFETCHh Load 32 or more of bytes from memory to a selected level of the
--   processor's cache hierarchy
-- SFENCE Serializes store operations

-- * SSE2 Instructions
-- ** SSE2 Packed and Scalar Double-Precision Floating-Point Instructions
-- *** SSE2 Data Movement Instructions

-- | MOVAPD Move two aligned packed double-precision floating-point values
-- between XMM registers or between and XMM register and memory
exec_movapd :: Semantics m =>  MLocation m (BVType 128) -> Value m (BVType 128) -> m ()
exec_movapd l v = l .= v

-- MOVUPD Move two unaligned packed double-precision floating-point values
--   between XMM registers or between and XMM register and memory
-- MOVHPD Move high packed double-precision floating-point value to an from
--   the high quadword of an XMM register and memory
-- MOVLPD Move low packed single-precision floating-point value to an from
--   the low quadword of an XMM register and memory
-- MOVMSKPD Extract sign mask from two packed double-precision floating-point values

-- | MOVSD Move scalar double-precision floating-point value between XMM
-- registers or between an XMM register and memory
exec_movsd :: Semantics m => MLocation m (BVType 64) -> Value m (FloatType DoubleFloat) -> m ()
exec_movsd l v = l .= v

-- *** SSE2 Packed Arithmetic Instructions

-- ADDPD Add packed double-precision floating-point values
-- | ADDSD Add scalar double precision floating-point values
exec_addsd :: Semantics m => MLocation m XMMType -> Value m (FloatType DoubleFloat) -> m ()
-- FIXME: Overflow, Underflow, Invalid, Precision, Denormal.
exec_addsd r y = modify (\x -> fpAdd DoubleFloatRepr x y) (xmm_low64 r)

-- SUBPD Subtract scalar double-precision floating-point values

-- | SUBSD Subtract scalar double-precision floating-point values
exec_subsd :: Semantics m => MLocation m XMMType -> Value m (FloatType DoubleFloat) -> m ()
exec_subsd r y = modify (\x -> fpSub DoubleFloatRepr x y) (xmm_low64 r)

-- MULPD Multiply packed double-precision floating-point values

-- | MULSD Multiply scalar double-precision floating-point values
exec_mulsd :: Semantics m => MLocation m XMMType -> Value m (FloatType 'DoubleFloat) -> m ()
exec_mulsd r y = modify (\x -> fpMul DoubleFloatRepr x y) (xmm_low64 r)

-- DIVPD Divide packed double-precision floating-point values

-- | DIVSD Divide scalar double-precision floating-point values
exec_divsd :: Semantics m => MLocation m XMMType -> Value m (FloatType 'DoubleFloat) -> m ()
exec_divsd r y = modify (\x -> fpDiv DoubleFloatRepr x y) (xmm_low64 r)

-- SQRTPD Compute packed square roots of packed double-precision floating-point values
-- SQRTSD Compute scalar square root of scalar double-precision floating-point values
-- MAXPD Return maximum packed double-precision floating-point values
-- MAXSD Return maximum scalar double-precision floating-point values
-- MINPD Return minimum packed double-precision floating-point values
-- MINSD Return minimum scalar double-precision floating-point values

-- *** SSE2 Logical Instructions

-- ANDPD  Perform bitwise logical AND of packed double-precision floating-point values
-- ANDNPD Perform bitwise logical AND NOT of packed double-precision floating-point values
-- ORPD   Perform bitwise logical OR of packed double-precision floating-point values
-- XORPD  Perform bitwise logical XOR of packed double-precision floating-point values

-- *** SSE2 Compare Instructions

-- CMPPD Compare packed double-precision floating-point values
-- CMPSD Compare scalar double-precision floating-point values
-- COMISD Perform ordered comparison of scalar double-precision floating-point values and set flags in EFLAGS register

-- | UCOMISD Perform unordered comparison of scalar double-precision floating-point values and set flags in EFLAGS register.
exec_ucomisd :: Semantics m => MLocation m XMMType -> Value m (FloatType 'DoubleFloat) -> m ()
-- Invalid (if SNaN operands), Denormal.
exec_ucomisd l v = do v' <- get lower_l
                      let unordered = (isNaN fir v .|. isNaN fir v')
                          lt        = fpLt fir v' v
                          eq        = fpEq fir v' v

                      zf_loc .= (unordered .|. eq)
                      pf_loc .= unordered
                      cf_loc .= (unordered .|. lt)

                      of_loc .= false
                      af_loc .= false
                      sf_loc .= false
  where
  fir = DoubleFloatRepr
  lower_l = xmm_low64 l

-- *** SSE2 Shuffle and Unpack Instructions

-- CMPPD Compare packed double-precision floating-point values
-- CMPSD Compare scalar double-precision floating-point values
-- COMISD Perform ordered comparison of scalar double-precision floating-point values and set flags in EFLAGS register
-- UCOMISD Perform unordered comparison of scalar double-precision floating-point values and set flags in EFLAGS register.

-- *** SSE2 Conversion Instructions

-- CVTPD2PI  Convert packed double-precision floating-point values to packed doubleword integers.
-- CVTTPD2PI Convert with truncation packed double-precision floating-point values to packed doubleword integers
-- CVTPI2PD  Convert packed doubleword integers to packed double-precision floating-point values
-- CVTPD2DQ  Convert packed double-precision floating-point values to packed doubleword integers
-- CVTTPD2DQ Convert with truncation packed double-precision floating-point values to packed doubleword integers
-- CVTDQ2PD  Convert packed doubleword integers to packed double-precision floating-point values
-- CVTPS2PD  Convert packed single-precision floating-point values to packed double-precision floating- point values
-- CVTPD2PS  Convert packed double-precision floating-point values to packed single-precision floating- point values

-- | CVTSS2SD  Convert scalar single-precision floating-point values to
-- scalar double-precision floating-point values
exec_cvtss2sd :: Semantics m => MLocation m (BVType 128) -> Value m (FloatType SingleFloat) -> m ()
exec_cvtss2sd l v = xmm_low64 l .= fpCvt SingleFloatRepr DoubleFloatRepr v

-- CVTSD2SS  Convert scalar double-precision floating-point values to scalar single-precision floating-point values
-- CVTSD2SI  Convert scalar double-precision floating-point values to a doubleword integer

-- | CVTTSD2SI Convert with truncation scalar double-precision floating-point values to scalar doubleword integers
exec_cvttsd2si :: (IsLocationBV m n)
               => MLocation m (BVType n)
               -> Value m (FloatType DoubleFloat)
               -> m ()
-- Invalid, Precision.  Returns 80000000 if exception is masked
exec_cvttsd2si l v =
  -- TODO:
  l .= truncFPToSignedBV (loc_width l) DoubleFloatRepr v

-- | CVTSI2SD  Convert doubleword integer to scalar double-precision floating-point value
exec_cvtsi2sd :: (IsLocationBV m n)
              => MLocation m (BVType 128) -> Value m (BVType n) -> m ()
exec_cvtsi2sd l v = do
  xmm_low64 l .= fpFromBV DoubleFloatRepr v

-- ** SSE2 Packed Single-Precision Floating-Point Instructions

-- CVTDQ2PS  Convert packed doubleword integers to packed single-precision floating-point values
-- CVTPS2DQ  Convert packed single-precision floating-point values to packed doubleword integers
-- CVTTPS2DQ Convert with truncation packed single-precision floating-point values to packed doubleword integers

-- ** SSE2 128-Bit SIMD Integer Instructions

-- MOVDQA Move aligned double quadword.
-- MOVDQU Move unaligned double quadword
-- MOVQ2DQ Move quadword integer from MMX to XMM registers
-- MOVDQ2Q Move quadword integer from XMM to MMX registers
-- PMULUDQ Multiply packed unsigned doubleword integers
-- PADDQ Add packed quadword integers
-- PSUBQ Subtract packed quadword integers
-- PSHUFLW Shuffle packed low words
-- PSHUFHW Shuffle packed high words
-- PSHUFD Shuffle packed doublewords
-- PSLLDQ Shift double quadword left logical
-- PSRLDQ Shift double quadword right logical
-- PUNPCKHQDQ Unpack high quadwords
-- PUNPCKLQDQ Unpack low quadwords

-- ** SSE2 Cacheability Control and Ordering Instructions


-- CLFLUSH Flushes and invalidates a memory operand and its associated cache line from all levels of the processor’s cache hierarchy
-- LFENCE Serializes load operations
-- MFENCE Serializes load and store operations
-- PAUSE      Improves the performance of “spin-wait loops”
-- MASKMOVDQU Non-temporal store of selected bytes from an XMM register into memory
-- MOVNTPD    Non-temporal store of two packed double-precision floating-point values from an XMM register into memory
-- MOVNTDQ    Non-temporal store of double quadword from an XMM register into memory
-- MOVNTI     Non-temporal store of a doubleword from a general-purpose register into memory

-- * SSE3 Instructions
-- ** SSE3 x87-FP Integer Conversion Instruction

-- FISTTP Behaves like the FISTP instruction but uses truncation, irrespective of the rounding mode specified in the floating-point control word (FCW)

-- ** SSE3 Specialized 128-bit Unaligned Data Load Instruction

-- LDDQU Special 128-bit unaligned load designed to avoid cache line splits

-- ** SSE3 SIMD Floating-Point Packed ADD/SUB Instructions

-- ADDSUBPS Performs single-precision addition on the second and fourth pairs of 32-bit data elements within the operands; single-precision subtraction on the first and third pairs
-- ADDSUBPD Performs double-precision addition on the second pair of quadwords, and double-precision subtraction on the first pair

-- ** SSE3 SIMD Floating-Point Horizontal ADD/SUB Instructions

-- HADDPS Performs a single-precision addition on contiguous data elements. The first data element of the result is obtained by adding the first and second elements of the first operand; the second element by adding the third and fourth elements of the first operand; the third by adding the first and second elements of the second operand; and the fourth by adding the third and fourth elements of the second operand.
-- HSUBPS Performs a single-precision subtraction on contiguous data elements. The first data element of the result is obtained by subtracting the second element of the first operand from the first element of the first operand; the second element by subtracting the fourth element of the first operand from the third element of the first operand; the third by subtracting the second element of the second operand from the first element of the second operand; and the fourth by subtracting the fourth element of the second operand from the third element of the second operand.
-- HADDPD Performs a double-precision addition on contiguous data elements. The first data element of the result is obtained by adding the first and second elements of the first operand; the second element by adding the first and second elements of the second operand.
-- HSUBPD Performs a double-precision subtraction on contiguous data elements. The first data element of the result is obtained by subtracting the second element of the first operand from the first element of the first operand; the second element by subtracting the second element of the second operand from the first element of the second operand.


-- ** SSE3 SIMD Floating-Point LOAD/MOVE/DUPLICATE Instructions

-- MOVSHDUP Loads/moves 128 bits; duplicating the second and fourth 32-bit data elements
-- MOVSLDUP Loads/moves 128 bits; duplicating the first and third 32-bit data elements
-- MOVDDUP Loads/moves 64 bits (bits[63:0] if the source is a register) and returns the same 64 bits in both the lower and upper halves of the 128-bit result register; duplicates the 64 bits from the source

-- ** SSE3 Agent Synchronization Instructions

-- MONITOR Sets up an address range used to monitor write-back stores
-- MWAIT Enables a logical processor to enter into an optimized state while waiting for a write-back store to the address range set up by the MONITOR instruction