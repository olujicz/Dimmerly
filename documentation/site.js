// Cloudflare Web Analytics currently reports page views and performance, but
// does not support custom events. The data-analytics-event attributes in the
// markup stay reserved for a future event-capable analytics integration.
//
// Adds a copy button to each code block. The button is created here rather
// than in the markup so pages without JavaScript never show a dead control.
(function () {
    "use strict";

    if (!navigator.clipboard) {
        return;
    }

    document.querySelectorAll(".code-block").forEach(function (block) {
        var code = block.querySelector("code");
        if (!code) {
            return;
        }

        var button = document.createElement("button");
        button.type = "button";
        button.className = "copy-button";
        button.textContent = "Copy";
        button.setAttribute("aria-label", "Copy the commands to the clipboard");

        var reset;
        button.addEventListener("click", function () {
            navigator.clipboard.writeText(code.textContent.trim()).then(
                function () {
                    button.textContent = "Copied";
                },
                function () {
                    button.textContent = "Press ⌘C";
                }
            );

            window.clearTimeout(reset);
            reset = window.setTimeout(function () {
                button.textContent = "Copy";
            }, 2000);
        });

        block.appendChild(button);
    });
})();

// Create private contact controls without a plain-text address in the markup.
// This deters basic email crawlers; the address remains recoverable from code.
(function () {
    "use strict";

    document.querySelectorAll("[data-email-support]").forEach(function (container) {
        var button = document.createElement("button");
        button.type = "button";
        button.className = "text-link email-support-button";
        button.textContent = "Email support";
        button.title = "Opens your email app";
        button.addEventListener("click", function () {
            var address = String.fromCharCode(
                115, 117, 112, 112, 111, 114, 116, 64, 111, 108, 117, 106,
                105, 99, 46, 105, 110, 46, 114, 115
            );
            window.location.href = "mailto:" + address;
        });
        container.appendChild(button);
    });
})();
