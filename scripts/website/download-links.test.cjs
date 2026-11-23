const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { runInNewContext } = require("node:vm");

const documentation = join(__dirname, "../../documentation");
const homepage = readFileSync(join(documentation, "index.html"), "utf8");
const script = readFileSync(join(documentation, "site.js"), "utf8");
const downloadGroups = [...homepage.matchAll(/data-download="([^"]+)"[^>]*>[\s\S]*?<a class="button" href="([^"]+)"/g)];

for (const [destination, label] of [
    [null, "Or view the latest release"],
    ["https://github.com/olujicz/Dimmerly/releases/download/v1.5.1/Dimmerly.dmg", "Or download the DMG"],
]) {
    test(label, () => {
        assert.deepEqual(downloadGroups.map((match) => match[1]), ["hero", "install"]);
        const links = downloadGroups.map((match) => ({ href: destination ?? match[2] }));
        const groups = links.map((link) => ({
            querySelector: (selector) => selector === ".button" ? link : null,
            parentNode: { insertBefore() {} },
            insertBefore(button, anchor) {
                assert.equal(button.textContent, "Send to your Mac");
                assert.equal(anchor, link);
            },
        }));
        runInNewContext(script, {
            document: {
                querySelector: () => null,
                querySelectorAll: (selector) => selector === "[data-download]" ? groups : [],
                createElement: () => ({ setAttribute() {}, addEventListener() {} }),
            },
            navigator: { share() {} },
            window: {
                location: { href: "https://dimmerly.olujic.in.rs/" },
                matchMedia: () => ({ matches: true }),
            },
        });
        for (const [index, link] of links.entries()) {
            assert.equal(link.href, destination ?? downloadGroups[index][2]);
            assert.equal(link.textContent, label);
        }
    });
}
