// Storybook-specific JavaScript
// Import Lottie player for animated icons
import "@lottiefiles/lottie-player";

// Clipboard copy handler for copyable_field component
window.addEventListener('mave:clipcopy', (event) => {
  if ('clipboard' in navigator) {
    const text = event.target.textContent
    navigator.clipboard.writeText(text)
  } else {
    alert('Sorry, your browser does not support clipboard copy.')
  }
})
