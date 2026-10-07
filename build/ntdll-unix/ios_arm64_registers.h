/* Darwin's __x array ends at x28. The remaining registers are members,
 * not additional array elements, even when their storage is adjacent. */
#ifndef MADEIRA_IOS_ARM64_REGISTERS_H
#define MADEIRA_IOS_ARM64_REGISTERS_H

static inline __uint64_t *ios_arm64_register_slot( _STRUCT_ARM_THREAD_STATE64 *state,
                                                  unsigned int reg )
{
    if (reg < 29) return &state->__x[reg];
    switch (reg)
    {
    case 29: return &state->__fp;
    case 30: return &state->__lr;
    case 31: return &state->__sp;
    default: return NULL;
    }
}

/* Register 31 means SP for address calculation and writeback. Instruction
 * data operands must separately handle XZR/WZR (read zero, discard writes). */
#define IOS_ARM64_REG(state, reg) (*ios_arm64_register_slot( &(state), (reg) ))

#endif
