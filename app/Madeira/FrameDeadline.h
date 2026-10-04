#ifndef MADEIRA_FRAME_DEADLINE_H
#define MADEIRA_FRAME_DEADLINE_H
#include <stdint.h>

typedef struct { uint64_t next, period; } MadeiraFrameDeadline;

/* Absolute monotonic deadlines: no relative-sleep drift, busy wait or
 * catch-up burst after a stall. Caller supplies its own producer-local state. */
static inline uint64_t madeira_frame_deadline(MadeiraFrameDeadline *state,
                                              uint64_t now, uint64_t period) {
    if (!period) { state->next = state->period = 0; return now; }
    if (state->period != period || !state->next ||
        (now > state->next && now - state->next >= period)) {
        state->period = period;
        state->next = now + period;
        return now;
    }
    uint64_t target = state->next > now ? state->next : now;
    state->next += period;
    return target;
}
#endif
