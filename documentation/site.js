// Cloudflare Web Analytics currently reports page views and performance, but
// does not support custom events. The data-analytics-event attributes in the
// markup stay reserved for a future event-capable analytics integration.
//
// How far along its track a range input's thumb sits, from 0 to 1. The panel
// copies stop at 10% like the app, so this isn't the value divided by 100.
function sliderFill(slider) {
    var min = Number(slider.min);
    return (Number(slider.value) - min) / (Number(slider.max) - min);
}

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
// A click opens the email app and also shows the address, because without a
// mail account set up the mailto link does nothing visible.
(function () {
    "use strict";

    document.querySelectorAll("[data-email-support]").forEach(function (container) {
        var button = document.createElement("button");
        button.type = "button";
        button.className = "text-link email-support-button";
        button.textContent = "Email support";
        button.title = "Opens your email app";
        var shown = document.createElement("span");
        shown.setAttribute("role", "status");
        button.addEventListener("click", function () {
            var address = String.fromCharCode(
                115, 117, 112, 112, 111, 114, 116, 64, 111, 108, 117, 106,
                105, 99, 46, 105, 110, 46, 114, 115
            );
            shown.textContent = " (" + address + ")";
            window.location.href = "mailto:" + address;
        });
        container.appendChild(button);
        container.appendChild(shown);
    });
})();

// Sets up the demo loop behind its disclosure. The markup alone shows a poster
// with native controls and never plays by itself; here the light or dark
// version is chosen to match the page, the native controls give way to one
// Pause/Play button (moving content longer than five seconds needs a visible
// way to stop it), and opening the disclosure starts the loop unless the
// visitor asks for reduced motion. Closing it pauses the loop.
(function () {
    "use strict";

    var video = document.querySelector(".demo-video");
    var disclosure = video && video.closest("details");
    if (!video || !disclosure || !window.matchMedia) {
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
    video.parentNode.appendChild(button);
    showState();

    // Nothing is fetched until the disclosure opens. At phone width the CSS
    // hides the disclosure, so the recording isn't fetched there at all.
    var narrow = window.matchMedia("(max-width: 700px)");

    function start() {
        video.preload = "metadata";
        if (!reducedMotion.matches) {
            play();
        }
    }

    disclosure.addEventListener("toggle", function () {
        if (disclosure.open && !narrow.matches) {
            start();
        } else {
            video.pause();
        }
    });

    function onChange(query, handler) {
        if (query.addEventListener) {
            query.addEventListener("change", handler);
        } else if (query.addListener) {
            query.addListener(handler);
        }
    }

    onChange(dark, useVariant);
    onChange(narrow, function () {
        if (narrow.matches) {
            video.pause();
        }
    });
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
        slider.style.setProperty("--fill", String(sliderFill(slider)));
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

// Home page hero: a working copy of the menu bar panel over the desk from the
// demo recording. Each slider dims its own screen, and the presets set both
// screens and Auto Warmth at once, gliding the sliders the way the app does.
// The first time the desk comes into view it glides to Evening by itself,
// unless the visitor has already touched the panel or asks for reduced motion.
// Without JavaScript the sliders and presets stay disabled.
(function () {
    "use strict";

    var desk = document.querySelector("[data-hero-desk]");
    if (!desk) {
        return;
    }

    var sliders = desk.querySelectorAll("[data-desk-slider]");
    var presets = desk.querySelectorAll("[data-preset]");
    var warmth = desk.querySelector("[data-desk-warmth]");
    var status = desk.querySelector("[data-desk-status]");
    var reducedMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)");
    var touched = false;
    var frame;

    function show(slider) {
        var name = slider.getAttribute("data-desk-slider");
        var level = Number(slider.value);
        desk.style.setProperty("--" + name, String(level / 100));
        slider.style.setProperty("--fill", String(sliderFill(slider)));
        slider.setAttribute("aria-valuetext", level + "%");
        desk.querySelector('[data-desk-value="' + name + '"]').textContent = level + "%";
    }

    // Marks the applied preset; null clears the mark after a manual change.
    function select(applied) {
        Array.prototype.forEach.call(presets, function (button) {
            button.setAttribute("aria-pressed", String(button === applied));
        });
    }

    function glide(targets, duration) {
        window.cancelAnimationFrame(frame);
        var from = Array.prototype.map.call(sliders, function (slider) {
            return Number(slider.value);
        });
        function set(progress) {
            Array.prototype.forEach.call(sliders, function (slider, index) {
                slider.value = Math.round(from[index] + (targets[index] - from[index]) * progress);
                show(slider);
            });
        }
        if (reducedMotion && reducedMotion.matches) {
            set(1);
            return;
        }
        var start;
        function step(now) {
            start = start || now;
            var t = Math.min((now - start) / duration, 1);
            // Exponential ease-out: quick to respond, slow to settle.
            set(t === 1 ? 1 : 1 - Math.pow(2, -10 * t));
            if (t < 1) {
                frame = window.requestAnimationFrame(step);
            }
        }
        frame = window.requestAnimationFrame(step);
    }

    // data-preset is "external builtin warmth", for example "70 60 on".
    function apply(button, duration) {
        var values = button.getAttribute("data-preset").split(" ");
        glide([Number(values[0]), Number(values[1])], duration);
        warmth.checked = values[2] === "on";
        select(button);
    }

    Array.prototype.forEach.call(sliders, function (slider) {
        slider.disabled = false;
        slider.addEventListener("input", function () {
            touched = true;
            window.cancelAnimationFrame(frame);
            select(null);
            show(slider);
        });
        show(slider);
    });

    warmth.addEventListener("change", function () {
        touched = true;
        select(null);
    });

    // Reaching the panel by keyboard counts as touching it, so the values
    // don't start gliding under the visitor's focus.
    desk.querySelector(".mini-panel").addEventListener("focusin", function () {
        touched = true;
    });

    Array.prototype.forEach.call(presets, function (button) {
        button.disabled = false;
        button.addEventListener("click", function () {
            touched = true;
            apply(button, 700);
            status.textContent = button.textContent + " applied.";
        });
    });

    if ((reducedMotion && reducedMotion.matches) || !("IntersectionObserver" in window)) {
        return;
    }
    var evening = desk.querySelector('[data-preset="70 60 on"]');
    var observer = new IntersectionObserver(function (entries) {
        if (!entries[0].isIntersecting) {
            return;
        }
        observer.disconnect();
        window.setTimeout(function () {
            if (!touched) {
                apply(evening, 1800);
            }
        }, 900);
    }, { threshold: 0.6 });
    observer.observe(desk.querySelector(".stage-desk"));
})();

// Download buttons. A phone or tablet can't run a Mac app, so there the first
// action sends this page to a Mac (the share sheet offers AirDrop, Messages,
// and Mail) and the DMG link steps back to a text link. On a Mac, a click that
// starts the DMG download says what to do next, because the browser's own
// download indicator doesn't.
(function () {
    "use strict";

    var groups = document.querySelectorAll("[data-download]");
    if (!groups.length || !window.matchMedia) {
        return;
    }

    var handheld = window.matchMedia("(hover: none) and (pointer: coarse)").matches;
    var canonical = document.querySelector('link[rel="canonical"]');
    var pageURL = canonical ? canonical.href : window.location.href;

    Array.prototype.forEach.call(groups, function (group) {
        var link = group.querySelector(".button");
        var status = document.createElement("p");
        status.className = "download-status";
        status.setAttribute("role", "status");
        group.parentNode.insertBefore(status, group.nextSibling);

        if (handheld && (navigator.share || navigator.clipboard)) {
            var send = document.createElement("button");
            send.type = "button";
            send.className = "button";
            send.textContent = "Send to your Mac";
            send.addEventListener("click", function () {
                if (navigator.share) {
                    navigator.share({ title: "Dimmerly for macOS", url: pageURL }).catch(function () {});
                    return;
                }
                navigator.clipboard.writeText(pageURL).then(
                    function () {
                        status.textContent = "Link copied. Open it on your Mac to download Dimmerly.";
                    },
                    function () {
                        status.textContent = "Open " + pageURL + " on your Mac to download Dimmerly.";
                    }
                );
            });
            link.className = "text-link";
            link.textContent = "Or download the DMG";
            group.insertBefore(send, link);
            // The hero's "After you download" link gives way; the steps are
            // still below for anyone reading on a phone.
            var after = group.querySelector('a[href="#download-steps"]');
            if (after) {
                after.remove();
            }
            return;
        }

        link.addEventListener("click", function () {
            // Locally and before a release has its DMG, the button opens the
            // release page instead, which needs no follow-up.
            if (!/\.dmg$/.test(link.href)) {
                return;
            }
            status.textContent = "Downloading Dimmerly. Next, open the DMG and drag Dimmerly to Applications. ";
            if (group.getAttribute("data-download") !== "install") {
                var steps = document.createElement("a");
                steps.href = "#download-steps";
                steps.textContent = "All the steps";
                status.appendChild(steps);
            }
        });
    });
})();

// Compare page: the app table is wider than a phone, and the edge shadow alone
// is easy to miss. The hint above it shows only while the table overflows.
(function () {
    "use strict";

    var hint = document.querySelector(".scroll-hint");
    var wrap = hint && hint.nextElementSibling;
    if (!wrap || !wrap.classList.contains("comparison-wrap")) {
        return;
    }

    function update() {
        hint.hidden = wrap.scrollWidth <= wrap.clientWidth + 1;
    }

    update();
    if (window.ResizeObserver) {
        new ResizeObserver(update).observe(wrap);
    } else {
        window.addEventListener("resize", update);
    }
})();
