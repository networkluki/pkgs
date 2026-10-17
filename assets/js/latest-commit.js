// Update the footer link to the latest commit on the default branch.
// Keep the verified hardcoded fallback when the API is unavailable.
// Requires CSP: connect-src https://api.github.com (along with any existing sources).
(function () {
  "use strict";

  var el = document.getElementById("latest-diff");
  if (!el || !window.fetch) { return; }

  var OWNER = "networkluki";
  var REPO = "pkgs";
  var api = "https://api.github.com/repos/" + OWNER + "/" + REPO + "/commits?per_page=1";

  fetch(api, {
    headers: { "Accept": "application/vnd.github+json" }
  })
    .then(function (res) {
      return res.ok ? res.json() : Promise.reject(res.status);
    })
    .then(function (data) {
      if (!Array.isArray(data) || data.length === 0) { return; }
      var sha = data[0] && data[0].sha;
      if (typeof sha !== "string" || !/^[0-9a-f]{40}$/.test(sha)) { return; }
      el.textContent = "version#" + sha.slice(0, 7);
      el.setAttribute("href",
        "https://github.com/" + OWNER + "/" + REPO + "/commit/" + sha);
    })
    .catch(function () {
      // Keep the fallback link already in the HTML.
    });
})();
