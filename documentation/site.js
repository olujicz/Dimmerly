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

        // The button's label changes silently, so the result is also spoken
        // through a status region.
        var announcement = document.createElement("span");
        announcement.className = "visually-hidden";
        announcement.setAttribute("role", "status");

        var reset;
        function show(label, message) {
            button.textContent = label;
            announcement.textContent = message;
        }

        button.addEventListener("click", function () {
            navigator.clipboard.writeText(code.textContent.trim()).then(
                function () {
                    show("Copied", "Commands copied to the clipboard.");
                },
                function () {
                    show("Press ⌘C", "Copying failed. Select the commands and press Command-C.");
                }
            );

            window.clearTimeout(reset);
            reset = window.setTimeout(function () {
                show("Copy", "");
            }, 2000);
        });

        block.appendChild(button);
        block.appendChild(announcement);
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

// Sets up the demo loop. The markup alone shows a poster with native controls
// and never plays by itself; here the light or dark version is chosen to match
// the page, the native controls give way to one Pause/Play button (moving
// content longer than five seconds needs a visible way to stop it), and the
// loop plays unless the visitor asks for reduced motion.
(function () {
    "use strict";

    var video = document.querySelector(".demo-video");
    if (!video || !window.matchMedia) {
        return;
    }

    var dark = window.matchMedia("(prefers-color-scheme: dark)");
    var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

    function useVariant() {
        var name = dark.matches ? "dark" : "light";
        var source = video.getAttribute("data-" + name + "-src");
        if (video.getAttribute("src") === source) {
            return;
        }
        var resumeAt = video.currentTime;
        var wasPlaying = !video.paused;
        video.poster = video.getAttribute("data-" + name + "-poster");
        video.src = source;
        if (resumeAt > 0) {
            video.addEventListener("loadedmetadata", function seek() {
                video.removeEventListener("loadedmetadata", seek);
                video.currentTime = resumeAt;
            });
        }
        if (wasPlaying) {
            play();
        }
    }

    var button = document.createElement("button");
    button.type = "button";
    button.className = "demo-toggle";

    function showState() {
        var playing = !video.paused;
        button.textContent = playing ? "Pause" : "Play";
        button.setAttribute("aria-label", playing ? "Pause the demo video" : "Play the demo video");
    }

    // Autoplay can be refused (Low Power Mode, browser policy); the poster and
    // the Play button then stay as they are.
    function play() {
        var started = video.play();
        if (started && started.catch) {
            started.catch(showState);
        }
    }

    button.addEventListener("click", function () {
        if (video.paused) {
            play();
        } else {
            video.pause();
        }
    });
    video.addEventListener("play", showState);
    video.addEventListener("pause", showState);

    // Pick the variant before allowing preload, so a dark page never starts
    // fetching the light video.
    video.controls = false;
    useVariant();
    video.preload = "metadata";
    video.parentNode.appendChild(button);
    showState();

    if (!reducedMotion.matches) {
        play();
    }

    function onChange(query, handler) {
        if (query.addEventListener) {
            query.addEventListener("change", handler);
        } else if (query.addListener) {
            query.addListener(handler);
        }
    }

    onChange(dark, useVariant);
    onChange(reducedMotion, function () {
        if (reducedMotion.matches) {
            video.pause();
        }
    });
})();

// 404 page: the panel's brightness slider dims the illustrated screen, and the
// presets answer to the same Control-Option-number shortcuts as in the app.
// Without JavaScript the slider stays disabled and the links still work.
(function () {
    "use strict";

    var slider = document.querySelector("[data-lost-brightness]");
    if (!slider) {
        return;
    }

    var page = document.querySelector(".lost");
    var value = document.querySelector("[data-lost-value]");
    var status = document.querySelector("[data-lost-status]");
    // Starts from the markup's message, so loading the page announces nothing.
    var lastStatus = status.textContent;

    function update() {
        var level = Number(slider.value);
        page.style.setProperty("--level", String(level / 100));
        value.textContent = level + "%";
        slider.setAttribute("aria-valuetext", level + "%");

        var message = level === 100
            ? "Full brightness, still nothing here. Try a preset."
            : "No reply from this address.";
        // Only touch the live region when the message changes, so screen
        // readers don't repeat it on every step of the slider.
        if (message !== lastStatus) {
            status.textContent = message;
            lastStatus = message;
        }
    }

    slider.disabled = false;
    slider.addEventListener("input", update);
    update();

    var presets = document.querySelectorAll(".mini-presets a");
    document.addEventListener("keydown", function (event) {
        if (!event.ctrlKey || !event.altKey || event.metaKey || event.shiftKey) {
            return;
        }
        // event.code, because Option changes event.key on a Mac keyboard.
        var match = /^Digit([1-9])$/.exec(event.code);
        var preset = match && presets[Number(match[1]) - 1];
        if (preset) {
            event.preventDefault();
            window.location.href = preset.href;
        }
    });
})();

// Home page hero: a working copy of the menu bar panel. Each slider dims its
// own illustrated screen, and the presets set both screens and Auto Warmth at
// once. Without JavaScript the sliders and presets stay disabled.
(function () {
    "use strict";

    var desk = document.querySelector("[data-hero-desk]");
    if (!desk) {
        return;
    }

    var sliders = desk.querySelectorAll("[data-desk-slider]");
    var warmth = desk.querySelector("[data-desk-warmth]");
    var status = desk.querySelector("[data-desk-status]");

    function show(slider) {
        var name = slider.getAttribute("data-desk-slider");
        var level = Number(slider.value);
        desk.style.setProperty("--" + name, String(level / 100));
        slider.style.setProperty("--level", String(level / 100));
        slider.setAttribute("aria-valuetext", level + "%");
        desk.querySelector('[data-desk-value="' + name + '"]').textContent = level + "%";
    }

    Array.prototype.forEach.call(sliders, function (slider) {
        slider.disabled = false;
        slider.addEventListener("input", function () {
            desk.classList.remove("is-gliding");
            show(slider);
        });
        show(slider);
    });

    Array.prototype.forEach.call(desk.querySelectorAll("[data-preset]"), function (button) {
        button.disabled = false;
        button.addEventListener("click", function () {
            // "external builtin warmth", for example "70 60 on".
            var values = button.getAttribute("data-preset").split(" ");
            desk.classList.add("is-gliding");
            Array.prototype.forEach.call(sliders, function (slider, index) {
                slider.value = values[index];
                show(slider);
            });
            warmth.checked = values[2] === "on";
            status.textContent = button.textContent + " applied.";
        });
    });
})();
