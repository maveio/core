// Plays a live stream in a player element: the live edge while a broadcast
// runs, the recording after it ended. The element holds the video, a notice
// and a live badge, and carries the playlist address and the notice texts as
// data attributes. Call `update` with each status of the stream.
import Hls from "hls.js/dist/hls.light.mjs";

export function mountLivePlayer(root) {
  const video = root.querySelector("video");
  const notice = root.querySelector("[data-notice]");
  const badge = root.querySelector("[data-badge]");
  const empty = root.querySelector("[data-empty]");

  const notices = {
    idle: root.dataset.offline,
    live: root.dataset.starting,
    ended: root.dataset.ended,
    error: root.dataset.unavailable,
  };

  let hls = null;
  let loaded = null;

  function show(status) {
    root.dataset.state = loaded ? "playing" : status;
    badge.hidden = !(status === "live" && loaded);
    notice.textContent = loaded ? "" : notices[status] || "";
    notice.hidden = notice.textContent === "";
    if (empty) empty.hidden = Boolean(loaded);
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
        // broadcast. Start over on the next update.
        unload();
      });
      hls.loadSource(root.dataset.src);
      hls.attachMedia(video);
    } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
      video.src = root.dataset.src;
    } else {
      loaded = null;
      return false;
    }

    if (stream.status !== "ended") {
      video.muted = true;
      video.play().catch(() => {});
    }

    return true;
  }

  return {
    update(stream) {
      const playable = stream.status !== "idle" && stream.playable;
      const key = `${stream.broadcast}:${stream.status === "ended" ? "recording" : "live"}`;

      // A viewer who watches the broadcast end keeps the player until the last
      // segment has played. After that the complete recording is loaded.
      const watchedEnd =
        loaded === `${stream.broadcast}:live` && stream.status === "ended" && !video.ended;

      if (!playable) unload();
      else if (loaded !== key && !watchedEnd && !load(stream)) return show("error");

      show(stream.status === "disconnected" ? "live" : stream.status);
    },

    // The status could not be fetched. Whatever plays keeps playing.
    fail() {
      if (!loaded) show("error");
    },

    destroy: unload,
  };
}
