// The watch page of a live stream: the player beside a chat. The LiveView
// renders the stream's status into the player element and the chat's
// messages; the hooks below add what needs the browser.
import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { mountLivePlayer } from "./live_playback";

const RESYNC_MS = 4000;

const LivePlayerHook = {
  mounted() {
    this.player = mountLivePlayer(this.el);
    this.sync();
    // A failed load is retried, and the recording replaces the live edge once
    // a viewer has watched the broadcast end.
    this.timer = setInterval(() => this.sync(), RESYNC_MS);
  },

  updated() {
    this.sync();
  },

  destroyed() {
    clearInterval(this.timer);
    this.player.destroy();
  },

  sync() {
    const { status, broadcast, playable } = this.el.dataset;
    this.player.update({ status, broadcast, playable: playable === "true" });
  },
};

// Remembers the chosen name for this tab, so a reload only asks to confirm it.
const ChatNameHook = {
  mounted() {
    this.key = `live-chat-name:${this.el.dataset.stream}`;
    this.handleEvent("chat_name_saved", ({ name }) => this.store(name));
    this.restore();
  },

  updated() {
    this.restore();
  },

  store(name) {
    try {
      sessionStorage.setItem(this.key, name);
    } catch (_error) {
      // Storage can be unavailable; the name then lasts until a reload.
    }
  },

  restore() {
    const input = this.el.querySelector("[data-chat-name]");
    if (!input || input.value) return;

    try {
      input.value = sessionStorage.getItem(this.key) || "";
    } catch (_error) {
      // See `store`.
    }
  },
};

const ChatComposerHook = {
  mounted() {
    this.text = this.el.querySelector("textarea");

    this.handleEvent("chat_message_sent", () => {
      this.el.reset();
      this.text.focus();
    });

    // Enter sends, Shift+Enter starts a new line.
    this.onKey = (event) => {
      if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
      event.preventDefault();
      this.el.requestSubmit();
    };

    this.text.addEventListener("keydown", this.onKey);
  },

  destroyed() {
    this.text.removeEventListener("keydown", this.onKey);
  },
};

const clock = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" });

// Keeps the newest message in view unless the viewer scrolled up, and shows
// message times in the viewer's time zone.
const ChatScrollHook = {
  mounted() {
    this.atBottom = true;

    this.onScroll = () => {
      this.atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 64;
    };

    this.el.addEventListener("scroll", this.onScroll);

    this.observer = new MutationObserver(() => this.refresh());
    this.observer.observe(this.el, { childList: true, subtree: true });
    this.refresh();
  },

  destroyed() {
    this.observer.disconnect();
    this.el.removeEventListener("scroll", this.onScroll);
  },

  refresh() {
    for (const time of this.el.querySelectorAll("time[datetime]")) {
      const local = clock.format(new Date(time.dateTime));
      if (time.textContent !== local) time.textContent = local;
    }

    if (this.atBottom) this.el.scrollTop = this.el.scrollHeight;
  },
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: {
    live_player: LivePlayerHook,
    chat_name: ChatNameHook,
    chat_composer: ChatComposerHook,
    chat_scroll: ChatScrollHook,
  },
});

liveSocket.connect();
