import Chart from "chart.js/auto"

export const ChartHook = {
  mounted() {
    this.draw()
  },

  updated() {
    this.draw()
  },

  destroyed() {
    this.destroyChart()
  },

  destroyChart() {
    if (this.chart) {
      this.chart.destroy()
      this.chart = null
    }
  },

  draw() {
    this.destroyChart()

    const canvas = document.createElement("canvas")
    const ctx = canvas.getContext("2d")
    const views = parseViews(this.el.getAttribute("data-views"))

    if (!views.length || !ctx) {
      this.el.replaceChildren()
      return
    }

    if (views.every((viewCount) => viewCount === 0)) {
      this.el.replaceChildren()
      return
    }

    const gradientFill = ctx.createLinearGradient(0, 0, 0, 100)
    gradientFill.addColorStop(0, "rgba(0, 0, 0, 0.05)")
    gradientFill.addColorStop(1, "rgba(0, 0, 0, 0)")

    canvas.setAttribute("role", "img")
    canvas.setAttribute("aria-label", "Video dropoff chart")
    this.el.replaceChildren(canvas)

    this.chart = new Chart(ctx, {
      type: "line",
      data: {
        labels: views.map(() => ""),
        datasets: [
          {
            borderColor: "rgba(0, 0, 0, 0.15)",
            borderWidth: 1.5,
            fill: true,
            backgroundColor: gradientFill,
            data: views,
            tension: 0.4,
            radius: 0,
          },
        ],
      },
      options: {
        maintainAspectRatio: false,
        responsive: true,
        animation: { duration: 0 },
        layout: { padding: 1 },
        scales: {
          x: {},
          y: {
            display: false,
          },
        },
        plugins: {
          legend: { display: false },
        },
      },
    })

  },
}

const parseViews = (value) => {
  try {
    const parsed = JSON.parse(value || "[]")

    if (!Array.isArray(parsed)) return []

    return parsed
      .map((item) => Number(item))
      .filter((item) => Number.isFinite(item) && item >= 0)
  } catch (_error) {
    return []
  }
}
