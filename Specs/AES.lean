/-
Copyright (c) 2024 Amazon.com, Inc. or its affiliates. All Rights Reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author(s): Yan Peng
-/
import Arm.BitVec
import Arm.Insts.DPSFP.Crypto_aes
import Specs.AESCommon

-- References : https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.197-upd1.pdf
--              https://csrc.nist.gov/csrc/media/projects/cryptographic-standards-and-guidelines/documents/aes-development/rijndael-ammended.pdf
--
--------------------------------------------------
-- The NIST specification has the following rounds:
--
-- AddRoundKey key0
-- for k in key1 to key9
--   SubBytes
--   ShiftRows
--   MixColumns
--   AddRoundKey
-- SubBytes
-- ShiftRows
-- AddRoundKey key10
--
-- The Arm implementation has an optimization that shifts the rounds:
--
-- for k in key0 to key8
--   AddRoundKey + ShiftRows + SubBytes (AESE k)
--   MixColumns (AESMC)
-- AddRoundKey + ShiftRows + SubBytes (AESE key9)
-- AddRoundKey key10
--
-- Note: SubBytes and ShiftRows are commutative because
--       SubBytes is a byte-wise operation
--
--------------------------------------------------

namespace AES

open BitVec

def WordSize := 32
def BlockSize := 128

-- Maybe consider Lists vs Vectors?
-- https://github.com/joehendrix/lean-crypto/blob/323ee9b1323deed5240762f4029700a246ecd9d5/lib/Crypto/Vector.lean#L96
def Rcon : List (BitVec WordSize) :=
[ 0x00000001#32,
  0x00000002#32,
  0x00000004#32,
  0x00000008#32,
  0x00000010#32,
  0x00000020#32,
  0x00000040#32,
  0x00000080#32,
  0x0000001b#32,
  0x00000036#32 ]

-------------------------------------------------------
-- types

-- Key-Block-Round Combinations
structure KBR where
  key_len : Nat
  block_size : Nat
  Nk := key_len / 32
  Nb := block_size / 32
  Nr : Nat
  h : block_size = BlockSize
deriving DecidableEq, Repr

def AES128KBR : KBR :=
  {key_len := 128, block_size := BlockSize, Nr := 10, h := by decide}
def AES192KBR : KBR :=
  {key_len := 192, block_size := BlockSize, Nr := 12, h := by decide}
def AES256KBR : KBR :=
  {key_len := 256, block_size := BlockSize, Nr := 14, h := by decide}

def KeySchedule : Type := List (BitVec WordSize)

-- Declare KeySchedule to be an instance HAppend
-- so we can apply `++` to KeySchedules propertly
instance : HAppend KeySchedule KeySchedule KeySchedule where
  hAppend := List.append

-------------------------------------------------------

def sbox (ind : BitVec 8) : BitVec 8 :=
  match_bv ind with
  | [x:4, y:4] =>
    have h : (x.toNat * 128 + y.toNat * 8 + 7) - (x.toNat * 128 + y.toNat * 8) + 1 = 8 :=
      by omega
    h ▸ extractLsb
      (x.toNat * 128 + y.toNat * 8 + 7)
      (x.toNat * 128 + y.toNat * 8) $ BitVec.flatten AESCommon.SBOX
  | _ => ind -- unreachable case

-- Little endian
def RotWord (w : BitVec WordSize) : BitVec WordSize :=
  match_bv w with
  | [a3:8, a2:8, a1:8, a0:8] => a0 ++ a3 ++ a2 ++ a1
  | _ => w -- unreachable case

def SubWord (w : BitVec WordSize) : BitVec WordSize :=
  match_bv w with
  | [a3:8, a2:8, a1:8, a0:8] => (sbox a3) ++ (sbox a2) ++ (sbox a1) ++ (sbox a0)
  | _ => w -- unreachable case

protected def InitKey {Param : KBR} (i : Nat) (key : BitVec Param.key_len)
  (acc : KeySchedule) : KeySchedule :=
  if h₀ : Param.Nk ≤ i then acc
  else
    have h₁ : i * 32 + 32 - 1 - i * 32 + 1 = WordSize := by
      simp only [WordSize]; omega
    let wd := h₁ ▸ extractLsb (i * 32 + 32 - 1) (i * 32) key
    let (x:KeySchedule) := [wd]
    have _ : Param.Nk - (i + 1) < Param.Nk - i := by omega
    AES.InitKey (Param := Param) (i + 1) key (acc ++ x)
  termination_by (Param.Nk - i)

protected def KeyExpansion_helper {Param : KBR} (i : Nat) (ks : KeySchedule)
  : KeySchedule :=
  if h : 4 * Param.Nr + 4 ≤ i then
    ks
  else
    let tmp := List.get! ks (i - 1)
    let tmp :=
      if i % Param.Nk == 0 then
        (SubWord (RotWord tmp)) ^^^ (List.get! Rcon $ (i / Param.Nk) - 1)
      else if Param.Nk > 6 && i % Param.Nk == 4 then
        SubWord tmp
      else
        tmp
    let res := (List.get! ks (i - Param.Nk)) ^^^ tmp
    let ks := List.append ks [ res ]
    have _ : 4 * Param.Nr + 4 - (i + 1) < 4 * Param.Nr + 4 - i := by omega
    AES.KeyExpansion_helper (Param := Param) (i + 1) ks
  termination_by (4 * Param.Nr + 4 - i)

def KeyExpansion {Param : KBR} (key : BitVec Param.key_len)
  : KeySchedule :=
  let seeded := AES.InitKey (Param := Param) 0 key []
  AES.KeyExpansion_helper (Param := Param) Param.Nk seeded

def SubBytes {Param : KBR} (state : BitVec Param.block_size)
  : BitVec Param.block_size :=
  have h : Param.block_size = 128 := by simp only [Param.h, BlockSize]
  h ▸ AESCommon.SubBytes (h ▸ state)

def ShiftRows {Param : KBR} (state : BitVec Param.block_size)
  : BitVec Param.block_size :=
  have h : Param.block_size = 128 := by simp only [Param.h, BlockSize]
  h ▸ AESCommon.ShiftRows (h ▸ state)

def XTimes (bv : BitVec 8) : BitVec 8 :=
  let res := extractLsb 6 0 bv ++ 0b0#1
  if extractLsb 7 7 bv == 0b0#1 then res else res ^^^ 0b00011011#8

def MixColumns {Param : KBR} (state : BitVec Param.block_size)
  : BitVec Param.block_size :=
  have h : Param.block_size = 128 := by simp only [Param.h, BlockSize]
  let FFmul02 := fun (x : BitVec 8) => XTimes x
  let FFmul03 := fun (x : BitVec 8) => x ^^^ XTimes x
  h ▸ AESCommon.MixColumns (h ▸ state) FFmul02 FFmul03

-- TODO : Prove the following lemma
theorem MixColumns_table_lookup_equiv {Param : KBR}
  (state : BitVec Param.block_size):
  have h : Param.block_size = 128 := by simp only [Param.h, BlockSize]
  MixColumns (Param := Param) state = h ▸ DPSFP.AESMixColumns (h ▸ state) := by
    simp only [MixColumns, DPSFP.AESMixColumns]
    have h₀ : (fun x => XTimes x) = DPSFP.FFmul02 := by
      funext x
      simp only [XTimes, DPSFP.FFmul02]
      simp only [Nat.reduceSub, Nat.reduceAdd, beq_iff_eq, Nat.sub_zero, List.length_cons, List.length_nil,
      Nat.reduceSucc, Nat.reduceMul]
      sorry -- looks like a sat problem
    have h₁ : (fun x => x ^^^ XTimes x) = DPSFP.FFmul03 := by
      funext x
      simp only [XTimes, DPSFP.FFmul03]
      simp only [Nat.reduceSub, Nat.reduceAdd, beq_iff_eq, Nat.sub_zero, List.length_cons, List.length_nil,
      Nat.reduceSucc, Nat.reduceMul]
      sorry -- looks like a sat problem
    rw [h₀, h₁]

def AddRoundKey {Param : KBR} (state : BitVec Param.block_size)
  (roundKey : BitVec Param.block_size) : BitVec Param.block_size :=
  state ^^^ roundKey

protected def getKey {Param : KBR} (n : Nat) (w : KeySchedule) : BitVec Param.block_size :=
  let ind := 4 * n
  have h : WordSize + WordSize + WordSize + WordSize = Param.block_size := by
    simp only [WordSize, BlockSize, Param.h]
  h ▸ ((List.get! w (ind + 3)) ++ (List.get! w (ind + 2)) ++
       (List.get! w (ind + 1)) ++ (List.get! w ind))

protected def AES_encrypt_with_ks_loop {Param : KBR} (round : Nat)
  (state : BitVec Param.block_size) (w : KeySchedule)
  : BitVec Param.block_size :=
  if Param.Nr ≤ round then
    state
  else
    let state := SubBytes state
    let state := ShiftRows state
    let state := MixColumns state
    let state := AddRoundKey state $ AES.getKey round w
    AES.AES_encrypt_with_ks_loop (Param := Param) (round + 1) state w
  termination_by (Param.Nr - round)

def AES_encrypt_with_ks {Param : KBR} (input : BitVec Param.block_size)
  (w : KeySchedule) : BitVec Param.block_size :=
  have h₀ : WordSize + WordSize + WordSize + WordSize = Param.block_size := by
    simp only [WordSize, BlockSize, Param.h]
  let state := AddRoundKey input $ (h₀ ▸ AES.getKey 0 w)
  let state := AES.AES_encrypt_with_ks_loop (Param := Param) 1 state w
  let state := SubBytes (Param := Param) state
  let state := ShiftRows (Param := Param) state
  AddRoundKey state $ h₀ ▸ AES.getKey Param.Nr w

def AES_encrypt {Param : KBR} (input : BitVec Param.block_size)
  (key : BitVec Param.key_len) : BitVec Param.block_size :=
  let ks := KeyExpansion (Param := Param) key
  AES_encrypt_with_ks (Param := Param) input ks

end AES
