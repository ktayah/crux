# Crux

Climbing technique analysis from a single video. Upload a clip, enter the
climber's weight, height and the wall angle, and Crux shows a body overlay,
the centre-of-mass path, and the **total force through the holds** over time,
in bodyweights.

Elixir does everything at runtime (video I/O, ONNX inference, physics, UI).
Python is used only to export the model.

## Pipeline

```
upload ─► ffmpeg normalise (H.264, 30 fps, ≤20 s)
       ─► frames (letterboxed float32, streamed through a Port)
       ─► pose: YOLO11n-pose in ONNX Runtime via Ortex          Crux.Pose
       ─► centre of mass: de Leva segment model                  Crux.Body
       ─► scale: metres/pixel from height + limb-length ratios   Crux.Body
       ─► Savitzky-Golay smoothing → velocity, acceleration     Crux.Physics
       ─► F = m (a − g), split in-plane / out-of-plane by wall angle
       ─► LiveView overlay + force chart
```

## Run it

Requires Elixir 1.18, Rust (for the Ortex NIF), ffmpeg, and [uv](https://docs.astral.sh/uv/).

```sh
uv run python/export_pose.py   # writes priv/models/pose.onnx
mix setup
mix phx.server                 # http://localhost:4000
mix test
```

## Assumptions and limits (MVP)

- Camera roughly square to the wall, image "down" along the wall's fall line.
- 2D only. Out-of-plane acceleration is unobservable and assumed zero.
- Reports **total** contact force. Splitting force across individual holds is
  statically indeterminate and is the next milestone.
- Segment tables are de Leva (1996) male values.
- The "silhouette" is a body model drawn from keypoints, not segmentation.
- Not validated against force measurements yet. Treat the numbers as estimates.

## License note

The YOLO11 weights are AGPL-3.0 (Ultralytics). Swap in an Apache-licensed pose
model (e.g. RTMPose) if that matters for your use.
