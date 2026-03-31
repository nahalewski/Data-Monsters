const FACE = document.getElementById('face');
const POLL_MS = 250;
let lastExpression = 'idle';

async function poll() {
  try {
    const res = await fetch('/api/face-state', { cache: 'no-store' });
    if (!res.ok) return;
    const state = await res.json();
    const expr = state.expression || 'idle';
    if (expr !== lastExpression) {
      FACE.src = `/static/assets/faces/${expr}.svg`;
      lastExpression = expr;
    }
  } catch (err) {
    console.error(err);
  }
}

setInterval(poll, POLL_MS);
poll();
