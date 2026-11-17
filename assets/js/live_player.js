// The public live stream player page. It follows the stream's status and
// plays it with the shared live player.
import { mountLivePlayer } from "./live_playback";

const root = document.getElementById("live-player");
const player = mountLivePlayer(root);

const POLL_MS = 4000;

async function poll() {
  try {
    const response = await fetch(root.dataset.statusUrl, { cache: "no-store" });
    if (!response.ok) throw new Error(`status ${response.status}`);
    player.update(await response.json());
  } catch (_error) {
    player.fail();
  }

  setTimeout(poll, POLL_MS);
}

poll();
