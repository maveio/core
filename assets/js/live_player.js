// Player for the public live stream page. It follows the stream's status and
// plays the HLS playlist: the live edge while a broadcast runs, the recording
// after it ended.
import Hls from "hls.js/dist/hls.light.mjs";

const root = document.getElementById("live-player");
const video = root.querySelector("video");
const notice = root.querySelector("[data-notice]");
const badge = root.querySelector("[data-badge]");

const POLL_MS = 4000;
const NOTICES = {
  idle: root.dataset.offline,
  ended: root.dataset.ended,
  error: root.dataset.unavailable,
};

let hls = null;
let loaded = null;

function show(status) {
  root.dataset.status = status;
  badge.hidden = !(status === "live" && loaded);
  notice.textContent = loaded ? "" : NOTICES[status] || "";
  notice.hidden = notice.textContent === "";
  video.hidden = !loaded;
}

function unload() {
  if (hls) hls.destroy();
  hls = null;
  loaded = null;
  video.removeAttribute("src");
  video.load();
}

function load(stream) {
  unload();
  // The key identifies what is loaded: a broadcast, live or as a recording.
  loaded = `${stream.broadcast}:${stream.status === "ended" ? "recording" : "live"}`;

  if (Hls.isSupported()) {
    hls = new Hls({ enableWorker: false, liveSyncDurationCount: 3 });
    hls.on(Hls.Events.ERROR, (_event, data) => {
      if (!data.fatal) return;
      // The playlist can be briefly unavailable around the start of a
      // broadcast. Start over on the next status poll.
      unload();
    });
    hls.loadSource(root.dataset.src);
    hls.attachMedia(video);
  } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
    video.src = root.dataset.src;
  } else {
    loaded = null;
    return show("error");
  }

  if (stream.status !== "ended") {
    video.muted = true;
    video.play().catch(() => {});
  }
}

async function poll() {
  try {
    const response = await fetch(root.dataset.statusUrl, { cache: "no-store" });
    if (!response.ok) throw new Error(`status ${response.status}`);
    const stream = await response.json();
    const playable = stream.status !== "idle" && stream.playable;
    const key = `${stream.broadcast}:${stream.status === "ended" ? "recording" : "live"}`;

    // A viewer who watches the broadcast end keeps the player until the last
    // segment has played. After that the complete recording is loaded.
    const watchedEnd =
      loaded === `${stream.broadcast}:live` && stream.status === "ended" && !video.ended;

    if (!playable) unload();
    else if (loaded !== key && !watchedEnd) load(stream);

    show(stream.status === "disconnected" ? "live" : stream.status);
  } catch (_error) {
    if (!loaded) show("error");
  }

  setTimeout(poll, POLL_MS);
}

poll();
