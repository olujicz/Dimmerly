#!/usr/bin/env python3
"""Read-only localization checks for Xcode, Godot CSV and gettext PO."""

import argparse
import ast
from collections import Counter
import csv
import gettext
import json
from pathlib import Path
import re
import sys
import unicodedata


# CLDR 49 cardinal categories for the supported language families.
CARDINALS = {
    "en": "one other", "de": "one other", "es": "one many other",
    "fr": "one many other", "it": "one many other", "ja": "other",
    "ko": "other", "nl": "one other", "pt": "one many other",
    "sr": "one few other", "zh": "other", "ru": "one few many other",
}
# Gettext uses integer indices. Million forms can get a separate index.
PO_COUNTS = {"es": {2, 3}, "fr": {2, 3}, "it": {2, 3}, "pt": {2, 3}, "ru": {3}}
PLACEHOLDER = re.compile(
    r"%%|%#@[A-Za-z_][\w.-]*@|"
    r"%(?:[1-9]\d*\$)?[-+#0 ']*(?:\d+|\*(?:\d+\$)?)?"
    r"(?:\.(?:\d+|\*(?:\d+\$)?))?(?:hh|ll|[hlLjztq])?[diouxXeEfFgGaAcCsSpn@v]|"
    r"(?<!\{)\{(?:[A-Za-z_][\w.]*|\d+)?(?:![rsa])?(?::[^{}\n]+)?\}(?!\})"
)
ARG_POSITION = re.compile(r"^%([1-9]\d*)\$")
STAR_POSITION = re.compile(r"\*(?:([1-9]\d*)\$)?")
NAMED_BRACE = re.compile(r"^\{(?:[A-Za-z_]|\d)")
MARKUP = re.compile(
    r"</?[A-Za-z][\w:-]*(?:\s+(?:[^<>\"']|\"[^\"]*\"|'[^']*')*)?\s*/?>|"
    r"\[/?(?:b|i|u|s|code|color|url|img|font|font_size|center|left|right|"
    r"fill|indent|list|ol|ul|table|cell|p|br|lb|rb|kbd|outline_size|"
    r"outline_color|bgcolor|fgcolor|wave|tornado|shake|fade|rainbow|pulse|hint|"
    r"dropcap|lang|opentype_features)(?:[=\s][^\]\n]+)?\]",
    re.IGNORECASE,
)
WORD = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)*")
ENGLISH_PHRASE = re.compile(
    r"\b(?:click here|try again|learn more|are you sure|you can|your settings|"
    r"please wait|by default|to continue|if you|this feature)\b"
)
STATES = {"new", "needs_review", "stale", "machine_translated"}
SEVERITIES = ("error", "warning", "info")
EXCEPTION_FIELDS = ("key", "source", "before", "after")


def tag(value):
    return value.strip().replace("_", "-").lower()


def language(locale):
    return locale.split("-")[0]


def placeholders(text):
    for match in PLACEHOLDER.finditer(text):
        token = match[0]
        start = match.start()
        # In ordinary prose, "25% set" contains a literal percent sign.
        if token.startswith("% ") and text[:start].rstrip()[-1:].isdigit():
            continue
        yield match


def visible(text):
    text = MARKUP.sub(" ", text)
    for match in reversed(list(placeholders(text))):
        text = text[:match.start()] + " " + text[match.end():]
    return " ".join(text.split())


def placeholder_signature(text):
    arguments, fixed = Counter(), []
    implicit, saw_explicit, saw_implicit = 0, False, False

    def position(explicit):
        nonlocal implicit, saw_explicit, saw_implicit
        if explicit:
            saw_explicit = True
            return int(explicit)
        saw_implicit = True
        implicit += 1
        return implicit

    for match in placeholders(text):
        token = match[0]
        if token == "%%" or token.startswith("%#@") or NAMED_BRACE.match(token):
            arguments[token] += 1
        elif token.startswith("{"):
            fixed.append(token)
        else:
            main = ARG_POSITION.match(token)
            for star in STAR_POSITION.finditer(token):
                role = "precision" if token[star.start() - 1] == "." else "width"
                arguments[(position(star[1]), role)] += 1
            specifier = STAR_POSITION.sub("*", ARG_POSITION.sub("%", token))
            arguments[(position(main[1] if main else None), specifier)] += 1
    return arguments, fixed, saw_explicit and saw_implicit


def english_overlap(source, target):
    source_words = WORD.findall(source.casefold())
    target_words = WORD.findall(target.casefold())
    common = set(zip(source_words, source_words[1:], source_words[2:]))
    return bool(ENGLISH_PHRASE.search(" ".join(target_words))) or any(
        triple in common for triple in zip(target_words, target_words[1:], target_words[2:])
    )


def contains(text, term):
    if re.search(r"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7a3]", term):
        return term.casefold() in text.casefold()
    return re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text, re.IGNORECASE) is not None


SPACES = str.maketrans({"\u00a0": " ", "\u202f": " ", "\u3000": " "})
CLOSERS = "\"'”’»」』)）]】›"
ENDINGS = {"stop": ".。．｡", "colon": ":：", "exclamation": "!！", "question": "?？"}
# Open and close characters that are unambiguous across the supported locales.
BRACKETS = (("([（［【", ")]）］】"), ("{｛", "}｝"), ("«", "»"), ("「", "」"), ("『", "』"))
NUMBER = re.compile(r"\d+(?:[.,\u00a0\u202f' ]\d+)*")


def ending(text):
    text = text.translate(SPACES).rstrip()
    text = text.rstrip(CLOSERS).rstrip()
    if text.endswith(("…", "...")):
        return "ellipsis"
    for name, chars in ENDINGS.items():
        if text[-1:] and text[-1] in chars:
            return name
    return ""


def edge_space(text):
    text = text.translate(SPACES)
    return text[:len(text) - len(text.lstrip())], text[len(text.rstrip()):]


def unbalanced(text):
    found = [f"{opens}{closes}" for opens, closes in BRACKETS
             if sum(text.count(c) for c in opens) != sum(text.count(c) for c in closes)]
    if text.count('"') % 2:
        found.append('"')
    return set(found)


def numbers(text):
    text = unicodedata.normalize("NFKC", text)
    return Counter(re.sub(r"\D", "", match[0]) for match in NUMBER.finditer(text))


def exception_applies(exception, key, source, target, start, end):
    """True when every context field given in the exception matches."""
    subjects = {
        "key": (key, lambda p, t: re.search(p, t)),
        "source": (source, lambda p, t: re.search(p, t)),
        # Text immediately before or after the match, anchored to it.
        "before": (target[:start], lambda p, t: re.search(f"(?:{p})$", t)),
        "after": (target[end:], lambda p, t: re.match(p, t)),
    }
    return all(subjects[field][1](exception[field], subjects[field][0])
               for field in EXCEPTION_FIELDS if field in exception)


def term_excepted(exceptions, key, source):
    return any(exception_applies(item, key, source, "", 0, 0) for item in exceptions)


class Checker:
    def __init__(self, rules, options, exceptions=None):
        self.rules = rules
        self.options = options
        self.exceptions = exceptions or {}
        self.locales = {tag(locale) for locale in options.locale}
        self.counts = Counter()
        self.translations = {}

    def report(self, locale, key, code, detail=""):
        if code in self.rules.get(locale, {}).get("ignore_checks", []):
            return
        # Project extension: per-catalog, per-key exceptions from _catalog_exceptions.
        if key in self.exceptions.get(code, {}).get(locale, []):
            return
        self.counts[code] += 1
        if not self.options.summary:
            print(f"{locale} {key!r}: {code}" + (f" ({detail})" if detail else ""))

    def targets(self, available):
        for locale in sorted(self.locales - available):
            self.report(locale, "", "missing-locale")
        return sorted((self.locales or available) & available)

    def variant(self, locale, key, source, target, state=None, contextual=False):
        # contextual: plural, device or msgctxt variants may legitimately differ,
        # so number and consistency checks skip them.
        if state in STATES:
            self.report(locale, key, f"xcstrings-{state}")
        if not target.strip():
            self.report(locale, key, "empty")
            return
        if MARKUP.findall(source) != MARKUP.findall(target):
            self.report(locale, key, "markup")
        if placeholder_signature(source) != placeholder_signature(target):
            self.report(locale, key, "placeholder")

        rules = self.rules.get(locale, {})
        source_text, target_text = visible(source), visible(target)
        term_exceptions = rules.get("glossary_exceptions", {})
        for term, forms in rules.get("glossary", {}).items():
            if contains(source_text, term) and not any(contains(target_text, form) for form in forms):
                if not term_excepted(term_exceptions.get(term, []), key, source):
                    self.report(locale, key, "glossary", term)
        for pattern in rules.get("address_patterns", []):
            if re.search(pattern, target_text, re.IGNORECASE):
                self.report(locale, key, "address", pattern)
        self.target_patterns(locale, key, source, target, rules.get("target_patterns", []))
        self.hygiene(locale, key, source, target, contextual)
        if not contextual and source.strip():
            self.translations.setdefault((locale, source.strip()), {}).setdefault(
                target.strip(), []).append(key)
        for literal in rules.get("protected_literals", []):
            if literal in source and literal not in target:
                self.report(locale, key, "protected-literal", literal)
        self.max_length(locale, key, target)
        allowed = rules.get("allow_matches", [])
        if source in allowed or key in allowed:
            return
        for literal in rules.get("protected_literals", []):
            source_text = source_text.replace(literal, " ")
            target_text = target_text.replace(literal, " ")
        source_text, target_text = " ".join(source_text.split()), " ".join(target_text.split())
        if WORD.search(source_text) and source_text == target_text:
            self.report(locale, key, "source-identical")
        elif english_overlap(source_text, target_text):
            self.report(locale, key, "possible-english")
        if len(source_text) >= 12:
            ratio = len(target_text) / len(source_text)
            low = self.options.min_ratio
            if language(locale) in {"zh", "ja", "ko"}:
                low = min(low, 0.2)
            if ratio < low or ratio > self.options.max_ratio:
                self.report(locale, key, "length-ratio", f"{ratio:.2f}")

    def max_length(self, locale, key, target):
        # Limits come from the locale's rules and from an optional "*" entry for all locales.
        for scope in ("*", locale):
            for pattern, limit in self.rules.get(scope, {}).get("max_length", {}).items():
                if re.search(pattern, key) and len(target) > limit:
                    self.report(locale, key, "max-length", f"{len(target)} > {limit}")

    def hygiene(self, locale, key, source, target, contextual):
        if not source.strip():
            return
        if edge_space(source) != edge_space(target):
            self.report(locale, key, "edge-whitespace")
        if re.search(r"\S {2,}\S", target) and not re.search(r"\S {2,}\S", source):
            self.report(locale, key, "double-space")
        source_text, target_text = visible(source), visible(target)
        wanted, got = ending(source_text), ending(target_text)
        # Short CJK labels often drop the final full stop.
        dropped_stop = wanted == "stop" and not got and language(locale) in {"zh", "ja", "ko"}
        if wanted != got and not dropped_stop and (wanted or got):
            self.report(locale, key, "end-punctuation", f"source {wanted or 'none'}, target {got or 'none'}")
        broken = unbalanced(target_text) - unbalanced(source_text)
        if broken:
            self.report(locale, key, "unbalanced", " ".join(sorted(broken)))
        if not contextual and numbers(source_text) != numbers(target_text):
            self.report(locale, key, "number-mismatch")

    def finish(self):
        """Cross-entry checks, run once after the whole catalog was read."""
        for (locale, source), targets in sorted(self.translations.items()):
            if len(targets) < 2 or source in self.rules.get(locale, {}).get("inconsistent_ok", []):
                continue
            detail = "; ".join(f"{target!r} in {', '.join(map(repr, keys[:3]))}"
                               for target, keys in sorted(targets.items()))
            self.report(locale, source, "inconsistent-translation", detail)

    def target_patterns(self, locale, key, source, target, patterns):
        # Runs on the raw target so punctuation and spacing stay visible.
        for rule in patterns:
            flags = re.IGNORECASE if rule.get("ignore_case") else 0
            for match in re.finditer(rule["regex"], target, flags):
                if any(exception_applies(item, key, source, target, match.start(), match.end())
                       for item in rule.get("exceptions", [])):
                    continue
                severity = rule.get("severity", "warning")
                self.report(locale, key, f"target-pattern-{severity}",
                            f"{rule['regex']!r}: {rule['hint']}; found {match[0]!r}")

    def plural(self, locale, key, observed):
        required = CARDINALS.get(language(locale), "").split()
        expected = set(self.rules.get(locale, {}).get("plural_categories", required))
        if not expected:
            self.report(locale, key, "plural-locale-unsupported")
        elif expected != observed:
            self.report(locale, key, "plural-categories",
                        f"missing {sorted(expected - observed)}, extra {sorted(observed - expected)}")


def xc_units(node, path=()):
    if "stringUnit" in node:
        yield path, node["stringUnit"]
    for dimension, variants in node.get("variations", {}).items():
        for option, child in variants.items():
            yield from xc_units(child, (*path, (dimension, option)))
    for name, child in node.get("substitutions", {}).items():
        yield from xc_units(child, (*path, ("substitution", name)))


def plural_groups(units):
    groups = {}
    for path in units:
        for index, (dimension, option) in enumerate(path):
            if dimension == "plural":
                groups.setdefault(path[:index], set()).add(option)
    return groups


def xc_source(key, path, source):
    fallback = tuple((kind, "other" if kind == "plural" else name) for kind, name in path)
    unit = source.get(path) or source.get(fallback)
    if unit is not None:
        return unit.get("value", key)
    if any(kind == "substitution" for kind, _ in path):
        return None
    return (source.get(()) or source.get((("plural", "other"),), {})).get("value", key)


def check_xcstrings(handle, checker):
    data = json.load(handle)
    source_language = tag(data["sourceLanguage"])
    entries = data["strings"]
    available = {tag(locale) for entry in entries.values()
                 for locale in entry.get("localizations", {})}
    targets = checker.targets(available - {source_language})
    for key, entry in entries.items():
        if entry.get("shouldTranslate") is False:
            continue
        state = entry.get("extractionState")
        if state in STATES:
            checker.report("*", key, f"xcstrings-{state}")
        translations = {tag(locale): node for locale, node in entry.get("localizations", {}).items()}
        source = dict(xc_units(translations.get(source_language, {})))
        source_groups = plural_groups(source)
        for locale in targets:
            units = dict(xc_units(translations.get(locale, {})))
            if not units:
                checker.report(locale, key, "missing")
                continue
            target_groups = plural_groups(units)
            for group in sorted(source_groups.keys() | target_groups.keys()):
                checker.plural(locale, f"{key} {group}" if group else key,
                               target_groups.get(group, set()))
            for path in sorted(source.keys() - units.keys()):
                if path and path[-1][0] == "device":
                    checker.report(locale, f"{key} {path}", "missing-variant")
            for path, unit in units.items():
                label = f"{key} {path}" if path else key
                original = xc_source(key, path, source)
                if original is None:
                    checker.report(locale, label, "missing-source-variant")
                    original = ""
                checker.variant(locale, label, original, unit.get("value", ""), unit.get("state"),
                                contextual=bool(path))


def check_csv(handle, checker):
    rows = csv.reader(handle, strict=True)
    header = next(rows, [])
    tags = [tag(column) for column in header[1:]]
    if len(set(tags)) != len(tags) or "" in tags:
        raise ValueError("duplicate or empty locale column")
    columns = {locale: index for index, locale in enumerate(tags, 1)}
    if "en" not in columns:
        raise ValueError("missing English source column (en)")
    source = columns["en"]
    targets = checker.targets(set(columns) - {"en"})
    for row in rows:
        if not row or not any(row) or row[0].startswith("#"):
            continue
        key = row[0]
        if len(row) != len(header):
            checker.report("*", key, "csv-width", f"line {rows.line_num}")
        original = row[source] if source < len(row) else ""
        if not original.strip():
            checker.report("en", key, "empty-source")
        for locale in targets:
            index = columns[locale]
            checker.variant(locale, key, original, row[index] if index < len(row) else "")


PO_FIELD = re.compile(r'(msgctxt|msgid_plural|msgid|msgstr(?:\[\d+\])?)\s+(".*")$')


def po_entries(handle):
    entry, fuzzy, current = {}, False, None
    for number, raw in enumerate(handle, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            if entry and (not line or any(field.startswith("msgstr") for field in entry)):
                yield entry, fuzzy
                entry, fuzzy = {}, False
            if line.startswith("#,"):
                fuzzy |= "fuzzy" in {flag.strip() for flag in line[2:].split(",")}
            current = None
            continue
        match = PO_FIELD.fullmatch(line)
        if match:
            current, literal = match.groups()
            if current in {"msgid", "msgctxt"} and "msgid" in entry:
                yield entry, fuzzy
                entry, fuzzy = {}, False
            entry[current] = ast.literal_eval(literal)
        elif line.startswith('"') and current is not None:
            entry[current] += ast.literal_eval(line)
        else:
            raise ValueError(f"unrecognized PO syntax on line {number}")
    if entry:
        yield entry, fuzzy


def integer_category(family, locale, n, count):
    if family in {"zh", "ja", "ko"}:
        return "other"
    if family in {"sr", "ru"}:
        if n % 10 == 1 and n % 100 != 11:
            return "one"
        if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
            return "few"
        return "many" if family == "ru" else "other"
    if count == 3 and family in {"es", "fr", "it", "pt"} and n and n % 1_000_000 == 0:
        return "many"
    zero_is_one = family == "fr" or (family == "pt" and locale != "pt-pt")
    return "one" if n == 1 or (n == 0 and zero_is_one) else "other"


def check_po_formula(checker, locale, count, formula):
    if formula is None:
        checker.report(locale, "", "po-plural-formula", "missing plural expression")
        return
    try:
        select = gettext.c2py(formula)
        samples = [*range(201), 1_000, 1_000_000, 1_000_001, 2_000_000]
        categories = {}
        for n in samples:
            category = integer_category(language(locale), locale, n, count)
            categories.setdefault(category, set()).add(select(n))
        indices = set().union(*categories.values())
    except (ValueError, ArithmeticError) as exc:
        checker.report(locale, "", "po-plural-formula", str(exc))
        return
    if indices != set(range(count)) or len(categories) != count or any(
        len(slots) != 1 for slots in categories.values()
    ):
        checker.report(locale, "", "po-plural-formula", "integer sample categories disagree")


def check_po(handle, checker):
    entries = list(po_entries(handle))
    header = next((entry.get("msgstr", "") for entry, _ in entries
                   if entry.get("msgid") == ""), "")
    locale_match = re.search(r"^Language:[ \t]*([^\s]+)", header, re.MULTILINE)
    if locale_match:
        locale = tag(locale_match[1])
    elif len(checker.locales) == 1:
        locale = next(iter(checker.locales))
    else:
        raise ValueError("missing PO Language header; pass --locale for this file")
    if not checker.targets({locale}):
        return
    declared = re.search(r"^Plural-Forms:[^\n]*\bnplurals\s*=\s*(\d+)", header, re.MULTILINE)
    count = int(declared[1]) if declared else 0
    family = language(locale)
    allowed = PO_COUNTS.get(family, {len(CARDINALS[family].split())} if family in CARDINALS else set())
    if any("msgid_plural" in entry for entry, _ in entries):
        if not count:
            checker.report(locale, "", "po-plural-header")
        elif not allowed:
            checker.report(locale, "", "plural-locale-unsupported")
        elif count not in allowed:
            checker.report(locale, "", "po-plural-count", f"declared {count}, expected {sorted(allowed)}")
        else:
            formula = re.search(r"^Plural-Forms:[^\n]*\bplural\s*=\s*([^;\n]+)", header, re.MULTILINE)
            check_po_formula(checker, locale, count, formula[1] if formula else None)
    for entry, fuzzy in entries:
        original = entry.get("msgid")
        if not original:
            continue
        label = f"{entry['msgctxt']} / {original}" if "msgctxt" in entry else original
        if fuzzy:
            checker.report(locale, label, "po-fuzzy")
        if "msgid_plural" not in entry:
            checker.variant(locale, label, original, entry.get("msgstr", ""),
                            contextual="msgctxt" in entry)
            continue
        slots = {int(field[7:-1]): value for field, value in entry.items() if field.startswith("msgstr[")}
        if count and (len(slots) != count or any(index >= count for index in slots)):
            checker.report(locale, label, "po-plural-indices",
                           f"expected 0–{count - 1}, got {sorted(slots)}")
        if not slots:
            checker.report(locale, label, "empty")
        for index, value in sorted(slots.items()):
            # An indexed slot can correspond to either English form.
            singular_first = (original, entry["msgid_plural"])
            candidates = singular_first if index == 0 else singular_first[::-1]
            signature = placeholder_signature(value)
            best = next((text for text in candidates if placeholder_signature(text) == signature),
                        candidates[0])
            checker.variant(locale, f"{label} [{index}]", best, value, contextual=True)


def validate_exceptions(items):
    if not isinstance(items, list):
        raise ValueError("exceptions must be a list")
    for item in items:
        fields = set(item) if isinstance(item, dict) else set()
        if not fields or not fields <= set(EXCEPTION_FIELDS):
            raise ValueError(f"exception needs one or more of {EXCEPTION_FIELDS}")
        for field in fields:
            if not isinstance(item[field], str):
                raise ValueError(f"exception {field} must be a regex string")
            re.compile(item[field])


def load_rules(path):
    if path is None:
        return {}, {}
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    exceptions = data.pop("_catalog_exceptions", {})
    allowed_codes = {"source-identical", "possible-english", "length-ratio", "xcstrings-stale", "number-mismatch",
                     "xcstrings-needs_review"}
    for catalog, findings in exceptions.items():
        for code, locales in findings.items():
            if code not in allowed_codes:
                raise ValueError(f"unsupported exception for {catalog}: {code}")
            for keys in locales.values():
                if not isinstance(keys, list) or not all(isinstance(key, str) for key in keys):
                    raise ValueError(f"expected a list of keys for {catalog}: {code}")
    rules = {tag(locale): config for locale, config in data.items()}
    for config in rules.values():
        for field in ("address_patterns", "allow_matches", "protected_literals", "plural_categories",
                      "ignore_checks", "inconsistent_ok"):
            items = config.get(field, [])
            if not isinstance(items, list) or not all(isinstance(item, str) and item for item in items):
                raise ValueError(f"expected a list of nonempty strings for {field}")
        for pattern in config.get("address_patterns", []):
            re.compile(pattern)
        limits = config.get("max_length", {})
        if not isinstance(limits, dict):
            raise ValueError("max_length must map key regexes to character limits")
        for pattern, limit in limits.items():
            if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
                raise ValueError(f"max_length for {pattern!r} must be a positive integer")
            re.compile(pattern)
        for rule in config.get("target_patterns", []):
            if not isinstance(rule, dict) or not isinstance(rule.get("regex"), str) or not rule["regex"]:
                raise ValueError("each target_patterns entry needs a nonempty regex")
            if not isinstance(rule.get("hint"), str) or not rule["hint"]:
                raise ValueError(f"target pattern {rule['regex']!r} needs a hint")
            if rule.get("severity", "warning") not in SEVERITIES:
                raise ValueError(f"severity must be one of {SEVERITIES}")
            re.compile(rule["regex"])
            validate_exceptions(rule.get("exceptions", []))
        for term, items in config.get("glossary_exceptions", {}).items():
            validate_exceptions(items)
        for term, forms in config.get("glossary", {}).items():
            if not term or not isinstance(forms, list) or not all(isinstance(form, str) and form for form in forms):
                raise ValueError(f"expected a list of nonempty glossary forms for {term!r}")
    return rules, exceptions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogs", type=Path, nargs="+")
    parser.add_argument("--locale", action="append", default=[], help="limit checks to this locale (repeatable)")
    parser.add_argument("--rules", type=Path, help="per-locale JSON rules")
    parser.add_argument("--summary", action="store_true", help="show totals without listing keys")
    parser.add_argument("--min-ratio", type=float, default=0.45)
    parser.add_argument("--max-ratio", type=float, default=2.25)
    options = parser.parse_args()
    if not 0 < options.min_ratio <= 1 <= options.max_ratio < float("inf"):
        parser.error("expected 0 < min-ratio <= 1 <= max-ratio < infinity")
    readers = {".xcstrings": check_xcstrings, ".csv": check_csv, ".po": check_po}
    try:
        rules, exceptions = load_rules(options.rules)
    except (OSError, ValueError, TypeError, AttributeError, re.error) as exc:
        parser.error(f"invalid rules: {exc}")
    result = 0
    root = Path.cwd()
    for path in options.catalogs:
        catalog = path.resolve()
        if catalog.is_relative_to(root):
            catalog = catalog.relative_to(root)
        checker = Checker(rules, options, exceptions.get(catalog.as_posix(), {}))
        print(path, flush=True)
        try:
            reader = readers.get(path.suffix.lower())
            if reader is None:
                raise ValueError("expected .xcstrings, .csv or .po")
            with path.open(encoding="utf-8-sig", newline="") as handle:
                reader(handle, checker)
            checker.finish()
        except (OSError, ValueError, SyntaxError, KeyError, TypeError, AttributeError, csv.Error) as exc:
            print(f"{path}: {exc}", file=sys.stderr)
            result = 2
            continue
        totals = ", ".join(f"{code}={count}" for code, count in sorted(checker.counts.items()))
        print(totals or "No findings")
        if any(code != "target-pattern-info" for code in checker.counts):
            result = max(result, 1)
    return result


if __name__ == "__main__":
    sys.exit(main())
