# sn92-dm: a REAX engine track v2 (`dm-all`) entry

Source of the image `ghcr.io/tensorworkerr/sn92-dm` (Bittensor subnet 92, REAX engine competition v2).

**What it is.** REAX's own Blink text reference image (`ghcr.io/reaxlabs/reax-engine-ref-blink@sha256:ab02e141…`,
reax-engine @4230e50, vLLM 0.30.0) plus one file, `direct_serve.py`. Declared models: `blink,jeffan`.

**The change.** The reference server (`engine/serve.py`) collects queued decisions into a step, runs them, and delivers only
when every decision of that step is answered, so new arrivals wait for the slowest decision and vLLM's continuous batching
idles between steps. `direct_serve.py` submits each decision to the backend's thread pool the moment it arrives and delivers
it on its own. The per-decision computation is the reference's own `VllmReadoutBackend._one` (for Jeffan, including its
read-twice rule). Both presets run vLLM with `VLLM_BATCH_INVARIANT=1`, so answers do not depend on batch composition.

**Layout of the image.**
- `/opt/reax/engine` — the base image's reax-engine @4230e50 (Blink) + `direct_serve.py`;
- `/opt/reax-j/engine` — reax-engine @6741836 (the code of REAX's ref-jeffan image; @4230e50 has no Jeffan family) +
  `direct_serve.py`;
- both entrypoints are REAX's `docker/vllm-readout/entrypoint.sh` with the server line switched to `engine.direct_serve`;
- `/opt/reax/dispatch.sh` picks the tree from `REAX_MODEL`. No weights, no binaries; user 10002.

`build_image.sh` rebuilds the image from this repository and the reax-engine repository (`crane`, no Docker daemon).

**Licence.** The files in this repository are MIT (LICENSE). The REAX Engine code in the image is under the REAX Engine
License 1.1 and Apache-2.0 as stated in its own repository; third-party notices are in `/licenses` of the image.
