// Copy installer commands without inline JavaScript (CSP: script-src 'self').
(function () {
  "use strict";

  document.querySelectorAll("[data-copy]").forEach(function (button) {
    button.addEventListener("click", async function () {
      var label = button.querySelector("span");
      if (!label) { return; }

      try {
        if (!navigator.clipboard || !navigator.clipboard.writeText) {
          throw new Error("Clipboard unavailable");
        }
        await navigator.clipboard.writeText(button.getAttribute("data-copy"));
        label.textContent = "Copied!";
        window.setTimeout(function () { label.textContent = "Copy"; }, 1800);
      } catch (_) {
        label.textContent = "Select text";
        window.setTimeout(function () { label.textContent = "Copy"; }, 2200);
      }
    });
  });
})();
