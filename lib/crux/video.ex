defmodule Crux.Video do
  @moduledoc """
  Video I/O via ffmpeg.

  `normalize/3` re-encodes an upload into a browser-friendly H.264 clip at a
  constant frame rate (rotation applied, audio dropped, trimmed). Everything
  downstream works on that clip, so the overlay timeline matches the analysis.

  `frames/2` streams letterboxed, planar float32 RGB frames ready for the pose
  model, without ever holding the whole video in memory.
  """

  @model_size 640
  # YOLO letterbox pad colour (114, 114, 114)
  @pad_color "0x727272"

  defmodule Letterbox do
    @moduledoc "How a source frame maps into the square model input."
    defstruct [:width, :height, :scaled_w, :scaled_h, :pad_x, :pad_y, :size]

    @doc "Map a point in model-input pixels back to source-video pixels."
    def to_source(%__MODULE__{} = lb, {x, y}) do
      {(x - lb.pad_x) * lb.width / lb.scaled_w, (y - lb.pad_y) * lb.height / lb.scaled_h}
    end
  end

  @doc "Re-encode `src` into a constant-fps H.264 mp4 at `dest`."
  def normalize(src, dest, opts \\ []) do
    fps = Keyword.get(opts, :fps, 30)
    max_seconds = Keyword.get(opts, :max_seconds, 20)
    max_height = Keyword.get(opts, :max_height, 720)

    args = [
      "-v", "error", "-y", "-i", src,
      "-t", to_string(max_seconds),
      "-an",
      "-vf", "scale=-2:'min(#{max_height},ih)',fps=#{fps}",
      "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
      "-pix_fmt", "yuv420p", "-movflags", "+faststart",
      dest
    ]

    case System.cmd(ffmpeg(), args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> {:error, "ffmpeg exited with #{status}: #{String.slice(out, 0, 500)}"}
    end
  end

  @doc "Width, height, fps and duration of the first video stream."
  def probe(path) do
    args = [
      "-v", "error", "-select_streams", "v:0",
      "-show_entries", "stream=width,height,r_frame_rate,nb_frames:format=duration",
      "-of", "json", path
    ]

    with {json, 0} <- System.cmd(ffprobe(), args),
         {:ok, %{"streams" => [stream | _], "format" => format}} <- Jason.decode(json) do
      [num, den] = stream["r_frame_rate"] |> String.split("/") |> Enum.map(&String.to_integer/1)
      fps = num / den
      duration = String.to_float(format["duration"])

      {:ok,
       %{
         width: stream["width"],
         height: stream["height"],
         fps: fps,
         duration: duration,
         frame_count: parse_int(stream["nb_frames"]) || round(duration * fps)
       }}
    else
      _ -> {:error, "could not read video metadata"}
    end
  end

  @doc "Letterbox geometry for a `width` x `height` video."
  def letterbox(width, height, size \\ @model_size) do
    scale = size / max(width, height)
    scaled_w = min(size, round(width * scale))
    scaled_h = min(size, round(height * scale))

    %Letterbox{
      width: width,
      height: height,
      scaled_w: scaled_w,
      scaled_h: scaled_h,
      pad_x: div(size - scaled_w, 2),
      pad_y: div(size - scaled_h, 2),
      size: size
    }
  end

  @doc """
  Stream frames as planar RGB float32 binaries (`3 * size * size * 4` bytes,
  values in 0..1), letterboxed according to `lb`.
  """
  def frames(path, %Letterbox{} = lb) do
    plane = lb.size * lb.size * 4
    frame_bytes = plane * 3

    vf =
      "scale=#{lb.scaled_w}:#{lb.scaled_h}," <>
        "pad=#{lb.size}:#{lb.size}:#{lb.pad_x}:#{lb.pad_y}:color=#{@pad_color}"

    # gbrpf32le = planar float32, plane order G, B, R. ffmpeg does the
    # u8 -> f32 conversion so we never touch pixels element-wise in Elixir.
    args = ["-v", "error", "-i", path, "-vf", vf, "-f", "rawvideo", "-pix_fmt", "gbrpf32le", "-"]

    Stream.resource(
      fn ->
        port = Port.open({:spawn_executable, ffmpeg()}, [:binary, :exit_status, args: args])
        {port, <<>>}
      end,
      fn
        :done ->
          {:halt, :done}

        {port, buffer} ->
          receive do
            {^port, {:data, data}} ->
              {frames, rest} = split_frames(buffer <> data, frame_bytes, [])
              {Enum.map(frames, &gbr_to_rgb(&1, plane)), {port, rest}}

            {^port, {:exit_status, 0}} ->
              {[], :done}

            {^port, {:exit_status, status}} ->
              raise "ffmpeg frame decode exited with status #{status}"
          end
      end,
      fn
        {port, _} -> if Port.info(port), do: Port.close(port)
        :done -> :ok
      end
    )
  end

  defp split_frames(buffer, size, acc) when byte_size(buffer) >= size do
    <<frame::binary-size(^size), rest::binary>> = buffer
    split_frames(rest, size, [frame | acc])
  end

  defp split_frames(buffer, _size, acc), do: {Enum.reverse(acc), buffer}

  defp gbr_to_rgb(frame, plane) do
    <<g::binary-size(^plane), b::binary-size(^plane), r::binary-size(^plane)>> = frame
    r <> g <> b
  end

  defp parse_int(nil), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp ffmpeg, do: System.find_executable("ffmpeg") || raise("ffmpeg not found on PATH")
  defp ffprobe, do: System.find_executable("ffprobe") || raise("ffprobe not found on PATH")
end
