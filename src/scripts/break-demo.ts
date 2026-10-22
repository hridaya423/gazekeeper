const LENGTH = 20;
const SKIP_AFTER = 3;

export function mountBreakDemo(): void {
  const trigger =
    document.querySelector<HTMLButtonElement>("[data-break-demo]");
  if (!trigger) return;
  trigger.addEventListener("click", () => run(trigger));
}

function run(trigger: HTMLButtonElement): void {
  const dialog = document.createElement("dialog");
  dialog.className = "break-demo";
  dialog.setAttribute("aria-label", "Eye break");
  dialog.innerHTML = `
    <p class="mono demo-top"><span>Eye break</span><span>Demo</span></p>
    <div class="demo-center">
      <div class="tick-dial" style="--n:${LENGTH}" aria-hidden="true">
        ${Array.from({ length: LENGTH }, (_, k) => `<i style="--k:${k}"></i>`).join("")}
        <span class="chart dial-count">${LENGTH}</span>
        <span class="mono dial-unit">Seconds</span>
      </div>
      <h2>Find something at least six metres away.</h2>
      <p>Let your focus rest on it. Blink slowly a few times.</p>
    </div>
    <button type="button" class="demo-skip" hidden>Skip <span class="mono">esc</span></button>`;
  document.body.append(dialog);

  const count = dialog.querySelector<HTMLElement>(".dial-count")!;
  const ticks = dialog.querySelectorAll<HTMLElement>(".tick-dial i");
  const skip = dialog.querySelector<HTMLButtonElement>(".demo-skip")!;
  const start = performance.now();
  let frame = 0;
  let shown = LENGTH;

  const close = () => {
    cancelAnimationFrame(frame);
    dialog.close();
    dialog.remove();
    trigger.focus();
  };

  const tick = (now: number) => {
    const elapsed = (now - start) / 1000;
    const left = Math.max(0, LENGTH - elapsed);
    const whole = Math.ceil(left);
    if (whole !== shown) {
      shown = whole;
      count.textContent = String(whole);
      ticks.forEach((tick, k) => tick.classList.toggle("off", k >= whole));
    }
    if (elapsed >= SKIP_AFTER) skip.hidden = false;
    if (left <= 0) return close();
    frame = requestAnimationFrame(tick);
  };

  skip.addEventListener("click", close);
  dialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    if (!skip.hidden) close();
  });
  dialog.showModal();
  frame = requestAnimationFrame(tick);
}
