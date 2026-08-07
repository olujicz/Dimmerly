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
