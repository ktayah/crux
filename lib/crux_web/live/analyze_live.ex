defmodule CruxWeb.AnalyzeLive do
  use CruxWeb, :live_view

  alias Crux.Analysis

  @defaults %{"weight_kg" => "70", "height_cm" => "175", "wall_angle_deg" => "0"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(form: to_form(@defaults), status: :idle, progress: nil, summary: nil, error: nil)
     |> allow_upload(:video,
       accept: ~w(.mp4 .mov .webm),
       #  accept: ~w(.mp4 .mov .m4v .webm),
       max_entries: 1,
       max_file_size: 200_000_000
     )}
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, form: to_form(Map.take(params, Map.keys(@defaults))))}
  end

  def handle_event("analyze", params, socket) do
    with {:ok, analysis_params} <- parse_params(params),
         [src] <- consume_video(socket) do
      lv = self()

      socket =
        socket
        |> assign(status: :running, progress: "Preparing video…", error: nil, summary: nil)
        |> start_async(:analysis, fn ->
          try do
            Analysis.run(src, analysis_params, &send(lv, &1))
          after
            File.rm(src)
          end
        end)

      {:noreply, socket}
    else
      [] -> {:noreply, assign(socket, error: "Choose a video first.")}
      {:error, msg} -> {:noreply, assign(socket, error: msg)}
    end
  end

  @impl true
  def handle_info({:progress, :transcoding, _, _}, socket),
    do: {:noreply, assign(socket, progress: "Preparing video…")}

  def handle_info({:progress, :pose, done, total}, socket),
    do: {:noreply, assign(socket, progress: "Estimating pose: frame #{done} of #{total}")}

  @impl true
  def handle_async(:analysis, {:ok, {:ok, result}}, socket) do
    {:noreply,
     socket
     |> assign(status: :done, progress: nil, summary: result.summary)
     |> push_event("analysis", result)}
  end

  def handle_async(:analysis, {:ok, {:error, msg}}, socket),
    do: {:noreply, assign(socket, status: :idle, progress: nil, error: msg)}

  def handle_async(:analysis, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, status: :idle, progress: nil, error: "Analysis crashed: #{inspect(reason)}")}

  defp consume_video(socket) do
    consume_uploaded_entries(socket, :video, fn %{path: path}, entry ->
      dest = Path.join(System.tmp_dir!(), "crux-#{entry.uuid}#{Path.extname(entry.client_name)}")
      File.cp!(path, dest)
      {:ok, dest}
    end)
  end

  defp parse_params(params) do
    with {:ok, weight} <- number(params, "weight_kg", 25, 200),
         {:ok, height} <- number(params, "height_cm", 100, 230),
         {:ok, angle} <- number(params, "wall_angle_deg", -20, 90) do
      {:ok, %{weight_kg: weight, height_m: height / 100, wall_angle_deg: angle}}
    end
  end

  defp number(params, key, min, max) do
    case Float.parse(to_string(params[key])) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _ -> {:error, "#{key} must be a number between #{min} and #{max}."}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <.header>
          Crux
          <:subtitle>
            Upload a climbing clip (camera square to the wall, ≤ 20 s) to see centre of mass
            and total force through the holds.
          </:subtitle>
        </.header>

        <.form
          for={@form}
          id="analyze-form"
          phx-change="validate"
          phx-submit="analyze"
          class="space-y-3"
        >
          <div
            class="rounded-box border border-dashed border-base-300 p-4 text-sm"
            phx-drop-target={@uploads.video.ref}
          >
            <.live_file_input upload={@uploads.video} />
            <p :for={entry <- @uploads.video.entries} class="mt-2 opacity-70">
              {entry.client_name} ({entry.progress}%)
              <span :for={err <- upload_errors(@uploads.video, entry)} class="text-error">
                {upload_error(err)}
              </span>
            </p>
          </div>

          <div class="grid grid-cols-3 gap-3">
            <.input field={@form[:weight_kg]} type="number" step="0.1" label="Weight (kg)" />
            <.input field={@form[:height_cm]} type="number" step="1" label="Height (cm)" />
            <.input
              field={@form[:wall_angle_deg]}
              type="number"
              step="1"
              label="Overhang (° past vertical)"
            />
          </div>

          <.button phx-disable-with="Uploading…" disabled={@status == :running}>Analyze</.button>
          <p :if={@progress} class="text-sm opacity-70">{@progress}</p>
          <p :if={@error} class="text-sm text-error">{@error}</p>
        </.form>

        <div :if={@summary} class="stats stats-vertical sm:stats-horizontal w-full shadow-sm">
          <div class="stat">
            <div class="stat-title">Peak force</div>
            <div class="stat-value">{@summary.peak_bw || "–"}×</div>
            <div class="stat-desc">bodyweight, all holds combined</div>
          </div>
          <div class="stat">
            <div class="stat-title">Mean force</div>
            <div class="stat-value">{@summary.mean_bw || "–"}×</div>
            <div class="stat-desc">bodyweight</div>
          </div>
          <div class="stat">
            <div class="stat-title">Climber detected</div>
            <div class="stat-value">{@summary.detected}/{@summary.frames}</div>
            <div class="stat-desc">frames over {@summary.duration} s</div>
          </div>
        </div>

        <div class={["space-y-2", @status != :done && "hidden"]}>
          <div id="viewer" phx-hook=".Overlay" phx-update="ignore" class="space-y-2">
            <div data-stage class="relative w-full bg-black rounded-box overflow-hidden">
              <video controls playsinline muted class="absolute inset-0 w-full h-full object-contain"></video>
              <svg data-overlay class="absolute inset-0 w-full h-full pointer-events-none"></svg>
            </div>
            <svg
              data-chart
              viewBox="0 0 1000 200"
              preserveAspectRatio="none"
              class="w-full h-32 bg-base-200 rounded-box cursor-pointer"
            ></svg>
            <p class="text-xs opacity-60">
              Total contact force in bodyweights (dashed line = 1×). Click the chart to seek.
            </p>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Overlay">
        // [proximal, distal, thickness in metres] for the body "silhouette"
        const LIMBS = [
          [5, 7, 0.10], [7, 9, 0.08], [6, 8, 0.10], [8, 10, 0.08],
          [11, 13, 0.16], [13, 15, 0.11], [12, 14, 0.16], [14, 16, 0.11],
        ]
        const TORSO = [5, 6, 12, 11]
        const MIN_CONF = 0.4
        const TRAIL = 30
        const BODY = 'fill="rgba(56,189,248,0.35)" stroke="rgba(56,189,248,0.35)" stroke-linecap="round" stroke-linejoin="round"'

        export default {
          mounted() {
            this.video = this.el.querySelector("video")
            this.stage = this.el.querySelector("[data-stage]")
            this.overlay = this.el.querySelector("[data-overlay]")
            this.chart = this.el.querySelector("[data-chart]")

            this.chart.addEventListener("click", (e) => {
              if (!this.data) return
              const rect = this.chart.getBoundingClientRect()
              const frac = (e.clientX - rect.left) / rect.width
              this.video.currentTime = (frac * this.data.frames.length) / this.data.fps
            })

            this.handleEvent("analysis", (data) => this.load(data))
            const tick = () => { this.render(); this.raf = requestAnimationFrame(tick) }
            this.raf = requestAnimationFrame(tick)
          },

          destroyed() {
            cancelAnimationFrame(this.raf)
            if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
          },

          async load(data) {
            this.data = null
            // Load as a Blob so seeking works without HTTP Range support.
            const blob = await (await fetch(data.video_url)).blob()
            if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
            this.objectUrl = URL.createObjectURL(blob)
            this.video.src = this.objectUrl
            this.stage.style.aspectRatio = `${data.width} / ${data.height}`
            this.overlay.setAttribute("viewBox", `0 0 ${data.width} ${data.height}`)
            this.data = data
            this.lastIndex = -1
            this.drawChart()
          },

          render() {
            const d = this.data
            if (!d) return
            const i = Math.min(d.frames.length - 1, Math.floor(this.video.currentTime * d.fps))
            if (i === this.lastIndex) return
            this.lastIndex = i

            const f = d.frames[i]
            const s = d.px_per_m
            const out = []

            if (f.k) {
              const ok = (j) => f.k[j][2] >= MIN_CONF
              const xy = (j) => `${f.k[j][0]},${f.k[j][1]}`
              if (TORSO.every(ok)) {
                out.push(`<polygon points="${TORSO.map(xy).join(" ")}" stroke-width="${0.12 * s}" ${BODY}/>`)
              }
              for (const [a, b, w] of LIMBS) {
                if (ok(a) && ok(b)) {
                  out.push(`<line x1="${f.k[a][0]}" y1="${f.k[a][1]}" x2="${f.k[b][0]}" y2="${f.k[b][1]}" stroke-width="${w * s}" ${BODY}/>`)
                }
              }
              const head = ok(3) && ok(4)
                ? [(f.k[3][0] + f.k[4][0]) / 2, (f.k[3][1] + f.k[4][1]) / 2]
                : ok(0) ? f.k[0] : null
              if (head) out.push(`<circle cx="${head[0]}" cy="${head[1]}" r="${0.11 * s}" ${BODY}/>`)
            }

            const trail = d.frames.slice(Math.max(0, i - TRAIL), i + 1).filter((t) => t.c).map((t) => t.c.join(","))
            if (trail.length > 1) {
              out.push(`<polyline points="${trail.join(" ")}" fill="none" stroke="#fb923c" stroke-opacity="0.6" stroke-width="${0.015 * s}"/>`)
            }

            if (f.c) {
              const [cx, cy] = f.c
              if (f.f) {
                // Arrow: in-plane contact force, 0.5 m per bodyweight.
                const bwNewtons = f.f.n / f.f.bw
                const ex = cx + (f.f.v[0] / bwNewtons) * 0.5 * s
                const ey = cy + (f.f.v[1] / bwNewtons) * 0.5 * s
                const ang = Math.atan2(ey - cy, ex - cx)
                const h = 0.06 * s
                out.push(`<line x1="${cx}" y1="${cy}" x2="${ex}" y2="${ey}" stroke="#ef4444" stroke-width="${0.02 * s}" stroke-linecap="round"/>`)
                out.push(`<polygon points="${ex},${ey} ${ex - h * Math.cos(ang - 0.4)},${ey - h * Math.sin(ang - 0.4)} ${ex - h * Math.cos(ang + 0.4)},${ey - h * Math.sin(ang + 0.4)}" fill="#ef4444"/>`)
                out.push(`<text x="${cx + 0.08 * s}" y="${cy + 0.04 * s}" font-size="${0.1 * s}" font-weight="700" fill="#fff" stroke="#000" stroke-width="${0.01 * s}" paint-order="stroke">${f.f.bw.toFixed(2)}× BW</text>`)
              }
              out.push(`<circle cx="${cx}" cy="${cy}" r="${0.035 * s}" fill="#fb923c" stroke="#fff" stroke-width="${0.01 * s}"/>`)
            }

            this.overlay.innerHTML = out.join("")
            if (this.playhead) {
              const x = (i / Math.max(1, d.frames.length - 1)) * 1000
              this.playhead.setAttribute("x1", x)
              this.playhead.setAttribute("x2", x)
            }
          },

          drawChart() {
            const frames = this.data.frames
            const n = frames.length
            const max = Math.max(2, ...frames.map((f) => (f.f ? f.f.bw : 0)))
            const x = (i) => (i / Math.max(1, n - 1)) * 1000
            const y = (bw) => 200 - (bw / max) * 190

            // Break the line wherever force is unknown.
            const runs = []
            let run = []
            frames.forEach((f, i) => {
              if (f.f) run.push(`${x(i)},${y(f.f.bw)}`)
              else if (run.length) { runs.push(run); run = [] }
            })
            if (run.length) runs.push(run)

            this.chart.innerHTML = [
              `<line x1="0" x2="1000" y1="${y(1)}" y2="${y(1)}" stroke="currentColor" stroke-opacity="0.4" stroke-dasharray="6 6" vector-effect="non-scaling-stroke"/>`,
              ...runs.map((r) => `<polyline points="${r.join(" ")}" fill="none" stroke="#ef4444" stroke-width="2" vector-effect="non-scaling-stroke"/>`),
              `<line data-playhead x1="0" x2="0" y1="0" y2="200" stroke="currentColor" stroke-width="1.5" vector-effect="non-scaling-stroke"/>`,
            ].join("")
            this.playhead = this.chart.querySelector("[data-playhead]")
          },
        }
      </script>
    </Layouts.app>
    """
  end

  defp upload_error(:too_large), do: "File is too large."
  defp upload_error(:not_accepted), do: "Use an mp4, mov, m4v or webm file."
  defp upload_error(:too_many_files), do: "One video at a time."
  defp upload_error(err), do: to_string(err)
end
