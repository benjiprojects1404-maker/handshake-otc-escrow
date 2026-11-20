// Rebuilds Handshake_OTC_Escrow/overview.pdf from docs/overview-brief.html (headless Chromium via Playwright).
// Run from the repo root: node docs/build-overview.cjs
const path = require("path");
const { chromium } = require("playwright");
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage();
  await p.goto("file://" + path.resolve(__dirname, "overview-brief.html"));
  await p.pdf({ path: path.resolve(__dirname, "../Handshake_OTC_Escrow/overview.pdf"), format: "A4", printBackground: true, preferCSSPageSize: true });
  await b.close();
  console.log("wrote Handshake_OTC_Escrow/overview.pdf");
})();
