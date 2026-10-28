"""REAX engine (dm-all) candidate, vLLM slots (blink, jeffan): the reference's server with the step barrier removed.

The reference (engine/serve.py Scheduler) runs one thread that takes the queued decisions, calls backend.run(batch) and
delivers only when every decision of that batch is answered; VllmReadoutBackend.run maps the batch over its thread pool
(one /v1/completions call per decision, jeffan's read-twice pass chained inside _one). New arrivals wait for the slowest
decision of the step, so vLLM's continuous batching sits idle between steps.

Here every decision goes to the backend's thread pool the moment it is submitted and is delivered on its own. The
per-decision computation is the reference's own: `_one` (optionally, for jeffan, the same two vLLM reads `_one` would
make, sent at the same time, with the reference's rule choosing between them). Both presets run vLLM with VLLM_BATCH_INVARIANT=1, so a read's numbers do not depend on what it is batched
with: answers are unchanged, only the waiting goes away.
Backends that are not vLLM (the native qwen35 engine) keep the reference scheduler unchanged.

Entry point: python3 -m engine.direct_serve (same arguments as engine.serve). Jeffan's two reads are chained as in the
reference by default; REAX_SPEC_REREAD=1 sends both at once (measured slower: jeffan is GPU-bound at concurrency 8).
"""
from __future__ import annotations

import os
import threading

from engine import serve as _serve  # PYTHONPATH=/opt/reax; serve.py puts /opt/reax/engine on sys.path itself

SPEC_REREAD = os.environ.get("REAX_SPEC_REREAD", "0") == "1"  # measured 10-28: 1.07-1.09x vs 1.105x chained (GPU-bound at c8)


class DirectScheduler(_serve.Scheduler):
    """No step: submit() hands the decision to the backend's pool at once; each result is delivered when it is ready."""

    def _loop(self):  # only the warm-up remains on the scheduler thread
        if self._on_ready:
            self._on_ready()

    def submit(self, enc, loop, fut):
        self.decisions += 1
        self.tokens += enc.n_tokens
        be, it = self.backend, enc.payload
        if SPEC_REREAD and getattr(it, "reread_ids", None) is not None and getattr(it, "messages", None) is None:
            self._submit_pair(enc, loop, fut)
            return
        cf = be.pool.submit(be._one, enc)

        def done(f, loop=loop, fut=fut):
            err = f.exception()
            loop.call_soon_threadsafe(_serve._deliver, [(fut, None if err else f.result())], err)

        cf.add_done_callback(done)

    def _submit_pair(self, enc, loop, fut):
        """jeffan: both reads at once; the reference's rule (vllm_readout.VllmReadoutBackend._one) picks the answer."""
        from engine.backends.vllm_readout import softmax_t
        be, it = self.backend, enc.payload
        reads = [be.pool.submit(be.client.option_values, it.ids, it.letter_ids),
                 be.pool.submit(be.client.option_values, it.reread_ids, it.letter_ids)]
        left, lock = [2], threading.Lock()

        def done(_f):
            with lock:
                left[0] -= 1
                if left[0]:
                    return
            try:  # the second read's result (or error) is used only when the rule asks for it, as in _one
                probs = softmax_t(reads[0].result(), it.temperature)
                if max(probs) < it.reread_below:  # the second read replaces the first, as in _one
                    be.rereads += 1
                    be.reread_tokens += len(it.reread_ids)
                    probs = softmax_t(reads[1].result(), it.temperature)
                res, err = probs, None
            except Exception as exc:  # noqa: BLE001
                res, err = None, exc
            loop.call_soon_threadsafe(_serve._deliver, [(fut, res)], err)

        for r in reads:
            r.add_done_callback(done)


def _scheduler(backend, max_wait_ms: float = 0.0, max_items: int = 256):
    if getattr(backend, "kind", "") == "vllm" and hasattr(backend, "_one") and hasattr(backend, "pool"):
        return DirectScheduler(backend, max_wait_ms, max_items)
    return _OriginalScheduler(backend, max_wait_ms, max_items)


_OriginalScheduler = _serve.Scheduler
_serve.Scheduler = _scheduler

if __name__ == "__main__":
    _serve.main()
