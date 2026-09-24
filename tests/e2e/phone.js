// Plays the phone: opens the Send Book URL in headless Chromium (phone-sized
// viewport), selects files, taps Upload and reports what the page says.
//   node tests/e2e/phone.js <url> <out.png> <file> [file ...]
// Needs `npm install playwright` (uses the pre-installed Chromium).
const { chromium, devices } = require("playwright");

(async () => {
    const [url, shot, ...files] = process.argv.slice(2);
    const browser = await chromium.launch();
    const page = await browser.newPage({ ...devices["Pixel 7"] });
    const t0 = Date.now();
    const resp = await page.goto(url);
    console.log("page:", resp.status(), await page.title(), `${Date.now() - t0} ms`);
    await page.setInputFiles("#file", files);
    console.log("selected:", await page.textContent("#name"));
    const t1 = Date.now();
    await page.click("#send");
    await page.waitForFunction(() => {
        const s = document.getElementById("status").textContent;
        return /You may close|No books were sent|expired|lost/.test(s);
    }, null, { timeout: 120000 });
    console.log("status:", await page.textContent("#status"), `(${Date.now() - t1} ms)`);
    for (const li of await page.$$eval("#list li", els => els.map(e => e.textContent))) {
        console.log("  ", li);
    }
    if (shot) await page.screenshot({ path: shot, fullPage: true });
    await browser.close();
})().catch(e => { console.error("ERROR", e.message); process.exit(1); });
