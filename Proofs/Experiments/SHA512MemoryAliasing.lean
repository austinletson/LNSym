/-
Copyright (c) 2024 Amazon.com, Inc. or its affiliates. All Rights Reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author(s): Shilpi Goel
-/
import Arm.Exec
import Arm.Memory.MemoryProofs
import Specs.SHA512
-- import Tactics.Sym
-- import Proofs.SHA512.Sha512StepLemmas
open BitVec

/- The memory aliasing proof obligations in
`sha512_block_armv8_prelude_sym_ctx_access` and
`sha512_block_armv8_loop_sym_ktbl_access` are similar -- we want to read a
small portion of a larger memory region. Note that we aren't really reasoning
about read-over-writes here --- `write_mem_bytes` doesn't even appear in these
proofs.

Other considerations:

1. Can we come up with a succinct way of stating that some memory regions are
   mutually separate, and have that formulation work with the automation? E.g.,
   the ctx, input, and ktbl regions in this program are all separate from each
   other, and we need 3C2 `mem_separate` terms to convey this information. If we
   also added the stack (which we have elided at this point), then we'd need 4C2
   terms; this number just grows alarmingly with the number of memory regions under
   consideration.

2. Feel free to change the `mem_separate`/`mem_subset`/`mem_legal` API to a more
   convenient one, if needed (e.g., to take a memory region's base address and
   size (as a `Nat`), instead of a region's first and last address). Think about
   the consequences of such a change --- e.g., using closed intervals disallows
   zero-length memory regions, and using a `Nat` size allows them; any pitfalls
   there?
-/

namespace SHA512MemoryAliasing

abbrev ctx_addr   (s : ArmState) : BitVec 64 := r (StateField.GPR 0#5) s
abbrev input_addr (s : ArmState) : BitVec 64 := r (StateField.GPR 1#5) s
abbrev num_blocks (s : ArmState) : BitVec 64 := r (StateField.GPR 2#5) s
-- (FIXME) Programmatically obtain the ktbl address from the ELF binary's
-- .rodata section. This address is computed in the program and stored in
-- register x3 using the following couple of instructions:
-- (0x1264d4#64 , 0xd0000463#32),      --  adrp    x3, 1b4000 <ecp_nistz256_precomputed+0x25000>
-- (0x1264d8#64 , 0x910c0063#32),      --  add     x3, x3, #0x300
abbrev ktbl_addr : BitVec 64 := 0x1b4300#64

/-
Let's automatically figure out what
`read_mem_bytes 16 <addr> s0`
should simplify to, where `<addr>` can be
[ctx_addr, ctx_addr + 16#64, ctx_addr + 32#64, ctx_addr + 48#64]

Let's also check our address normalization implementation, e.g., does the automation
work for `16#64 + ctx_addr`? What about `8#64 + ctx_addr + 8#64`? Other
variations?
-/
theorem sha512_block_armv8_prelude_sym_ctx_access (s0 : ArmState)
  (h_s0_err : read_err s0 = StateError.None)
  (h_s0_sp_aligned : CheckSPAlignment s0)
  (h_s0_pc : read_pc s0 = 0x1264c4#64)
  (h_s0_program : s0.program = sha512_program)
  (h_s0_num_blocks : num_blocks s0 = 1)
  (h_s0_x3 : r (StateField.GPR 3#5) s0 = ktbl_addr)
  (h_s0_ctx : read_mem_bytes 64 (ctx_addr s0) s0 = SHA2.h0_512.toBitVec)
  (h_s0_ktbl : read_mem_bytes (SHA2.k_512.length * 8) ktbl_addr s0 = BitVec.flatten SHA2.k_512)
  -- (FIXME) Add separateness invariants for the stack's memory region.
  -- @bollu: can we assume that `h_s1_ctx_input_separate`
  -- will be given as ((num_blocks s1).toNat * 128)?
  -- This is much more harmonious since we do not need to worry about overflow.
  (h_s0_ctx_input_separate :
    mem_separate' (ctx_addr s0)   64
                 (input_addr s0) ((num_blocks s0).toNat * 128))
  (h_s0_ktbl_ctx_separate :
    mem_separate' (ctx_addr s0) 64
                  ktbl_addr  (SHA2.k_512.length * 8))
  (h_s0_ktbl_input_separate :
    mem_separate' (input_addr s0) ((num_blocks s0).toNat * 128)
                  ktbl_addr      (SHA2.k_512.length * 8))
  -- (h_run : sf = run 4 s0)
  :
  read_mem_bytes 16 (ctx_addr s0 + 48#64) s0 = xxxx := by
  -- Prelude
  -- simp_all only [state_simp_rules, -h_run]
  -- Symbolic Simulation
  -- sym_n 4
  sorry

/-
Let's automatically figure out what
`read_mem_bytes 16 <addr> s0`
should simplify to, where `<addr>` can be
[ktbl_addr, ktbl_addr + 16#64, ktbl_addr + 32#64, ..., ktbl_addr + 624#64].

Let's also check our address normalization implementation, e.g., does the automation
work for `16#64 + ktbl_addr`?
-/
theorem sha512_block_armv8_loop_sym_ktbl_access (s1 : ArmState)
  (h_s1_err : read_err s1 = StateError.None)
  (h_s1_sp_aligned : CheckSPAlignment s1)
  (h_s1_pc : read_pc s1 = 0x126500#64)
  (h_s1_program : s1.program = sha512_program)
  (h_s1_num_blocks : num_blocks s1 = 1)
  (h_s1_x3 : r (StateField.GPR 3#5) s1 = ktbl_addr)
  (h_s1_ctx : read_mem_bytes 64 (ctx_addr s1) s1 = SHA2.h0_512.toBitVec)
  (h_s1_ktbl : read_mem_bytes (SHA2.k_512.length * 8) ktbl_addr s1 = BitVec.flatten SHA2.k_512)
  -- (FIXME) Add separateness invariants for the stack's memory region.
  -- @bollu: can we assume that `h_s1_ctx_input_separate`
  -- will be given as ((num_blocks s1).toNat * 128)?
  -- This is much more harmonious since we do not need to worry about overflow.
  (h_s1_ctx_input_separate :
    mem_separate' (ctx_addr s1)   64
                 (input_addr s1) ((num_blocks s1).toNat * 128))
  (h_s1_ktbl_ctx_separate :
    mem_separate' (ctx_addr s1)   64
                  ktbl_addr      ((SHA2.k_512.length * 8 )))
  (h_s1_ktbl_input_separate :
    mem_separate' (input_addr s1) ((num_blocks s1).toNat * 128)
                  ktbl_addr      (SHA2.k_512.length * 8)) :
  read_mem_bytes 16 ktbl_addr s1 = xxxx := by
  sorry

end SHA512MemoryAliasing
