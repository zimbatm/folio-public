.import "markdown.js" as Markdown

// Folio's open network requests. When the app closes, AppLoad destroys its
// QML while a request can still be running; its callback then runs against
// freed objects and xochitl crashes. unloading() calls closeAll().
// File writes are not tracked: the last save must finish.
var open = [];

function xhr() {
    open = open.filter(function (x) { return x.readyState !== XMLHttpRequest.DONE; });
    var x = new XMLHttpRequest();
    open.push(x);
    return x;
}

function closeAll() {
    for (var i = 0; i < open.length; i++) {
        try {
            open[i].onreadystatechange = null;
            open[i].abort();
        } catch (e) {}
    }
    open = [];
    stops = [];
    greyQueue = [];
}

// ---- live access: the web, for the assistant's tools and the page views
//
// QML's XMLHttpRequest has no timeout, and abort() from inside its own
// callback frees the reply that Qt goes on reading (a crash). So requests
// that must end get a deadline here, and the app's timer calls expire()
// every second, outside any callback.
var stops = [];     // { x, at, why }

function expire() {
    var now = Date.now();
    stops = stops.filter(function (s) { return s.x.readyState !== XMLHttpRequest.DONE; });
    stops.slice().forEach(function (s) {
        if (s.at > now) return;
        s.fired = s.why;
        try { s.x.abort(); } catch (e) {}
    });
}

var UA = "Mozilla/5.0 (Linux; reMarkable Paper Pro Move) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36 Folio/1";

// GET `url`. opts: timeout (ms), max (bytes), binary (an ArrayBuffer, not
// text). done(error, { status, type, text, data }): error is "" or why it
// failed, in words for the user.
function get(url, opts, done) {
    var x = xhr(), ended = false, secs = Math.round((opts.timeout || 15000) / 1000);
    var stop = { x: x, at: Date.now() + (opts.timeout || 15000), why: "no answer within " + secs + " s" };
    stops.push(stop);
    if (opts.binary) x.responseType = "arraybuffer";
    x.onreadystatechange = function () {
        if (x.readyState === XMLHttpRequest.HEADERS_RECEIVED && opts.max) {
            var len = parseInt(x.getResponseHeader("content-length")) || 0;
            if (len > opts.max) {
                stop.at = 0;
                stop.why = "the file is too large (" + Math.round(len / 1e6 * 10) / 10 + " MB)";
            }
        }
        if (x.readyState !== XMLHttpRequest.DONE || ended) return;
        ended = true;
        if (stop.fired) { done(stop.fired, null); return; }
        if (x.status === 0) { done("no connection to " + hostOf(url), null); return; }
        if (x.status >= 400) { done(hostOf(url) + " answered HTTP " + x.status, null); return; }
        var type = String(x.getResponseHeader("content-type") || "").toLowerCase();
        done("", { status: x.status, type: type, text: opts.binary ? "" : x.responseText, data: opts.binary ? x.response : null });
    };
    try {
        x.open("GET", url);
        x.setRequestHeader("User-Agent", UA);
        x.setRequestHeader("Accept-Language", "en;q=0.9, *;q=0.5");
        x.send();
    } catch (e) {
        ended = true;
        done("cannot open " + url, null);
    }
}

function hostOf(url) {
    return (String(url).match(/^[a-z]+:\/\/(?:www\.)?([^\/?#:]+)/i) || [])[1] || String(url);
}

// A short form of an address, for citing: host and a bit of the path
function shortUrl(url) {
    var m = String(url).match(/^[a-z]+:\/\/(?:www\.)?([^\/?#]+)([^?#]*)/i);
    if (!m) return String(url);
    var path = m[2].replace(/\/$/, "");
    return m[1] + (path.length > 28 ? path.slice(0, 26) + "…" : path);
}

// an address the user or the assistant gave: http(s) only
function normalUrl(u) {
    u = String(u || "").trim();
    if (!u) return "";
    if (!/^[a-z][a-z0-9+.-]*:/i.test(u)) u = "https://" + u.replace(/^\/+/, "");
    return /^https?:\/\/[^\s\/?#]+\.[^\s\/?#]+/i.test(u) || /^https?:\/\/localhost/i.test(u) ? u.replace(/\s/g, "%20") : "";
}

// an email address, also inside an address (%40 for @)
var EMAIL = /[A-Za-z0-9._%+-]+(@|%40)[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/;

// personal data that must not leave in a query or an address: "" or what it is
function personal(s) {
    return EMAIL.test(String(s || "")) ? "an email address" : "";
}

var B64 ="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function base64(buf) {
    var b = new Uint8Array(buf), n = b.length, out = [], i;
    for (i = 0; i + 2 < n; i += 3) {
        var v = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
        out.push(B64[v >> 18] + B64[(v >> 12) & 63] + B64[(v >> 6) & 63] + B64[v & 63]);
    }
    if (i < n) {
        var w = (b[i] << 16) | (i + 1 < n ? b[i + 1] << 8 : 0);
        out.push(B64[w >> 18] + B64[(w >> 12) & 63] + (i + 1 < n ? B64[(w >> 6) & 63] : "=") + "=");
    }
    return out.join("");
}

// a short name for a file per address (FNV-1a)
function hash(s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
        h ^= s.charCodeAt(i);
        h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
    }
    return ("0000000" + h.toString(16)).slice(-8);
}

// pages read this session: address -> fromHtml's result
var pages = {};
// greyscale images: address -> { data (a data URL), w, h, blank }; and
// those asked for
var images = {};
var wanted = {};
// pictures waiting to be made grey: { src, opts, done }
var greyQueue = [];

function strip(html) {
    return Markdown.decode(String(html).replace(/<[^>]*>/g, "")).replace(/\s+/g, " ").trim();
}

// ---- web_search

// DuckDuckGo's HTML pages (html. and lite.): [{ title, url, snippet }]
function searchResults(html) {
    var out = [], m, re = /<a\s([^>]*)>([\s\S]*?)<\/a>|<td[^>]*class=["'][^"']*result-snippet[^"']*["'][^>]*>([\s\S]*?)<\/td>/gi;
    while ((m = re.exec(html)) && out.length < 12) {
        if (m[3] !== undefined) {
            if (out.length && !out[out.length - 1].snippet) out[out.length - 1].snippet = strip(m[3]);
            continue;
        }
        var a = Markdown.attrsOf(m[1]), cls = a["class"] || "";
        if (/result__snippet/.test(cls)) {
            if (out.length && !out[out.length - 1].snippet) out[out.length - 1].snippet = strip(m[2]);
            continue;
        }
        if (!/result__a|result-link/.test(cls)) continue;
        var href = a.href || "", u = href.match(/[?&]uddg=([^&]+)/);
        href = u ? decodeURIComponent(u[1]) : href.indexOf("//") === 0 ? "https:" + href : href;
        // ads go through duckduckgo.com/y.js
        if (!/^https?:/.test(href) || /duckduckgo\.com\/y\.js|[?&]ad_domain=/.test(href)) continue;
        if (out.some(function (r) { return r.url === href; })) continue;
        out.push({ title: strip(m[2]), url: href, snippet: "" });
    }
    return out;
}

// the JSON of a SearXNG-like search (FOLIO_SEARCH_URL)
function jsonResults(text) {
    try {
        var r = JSON.parse(text);
        return (r.results || []).map(function (x) {
            return { title: strip(x.title || ""), url: x.url || x.link || "", snippet: strip(x.content || x.snippet || "") };
        }).filter(function (x) { return /^https?:/.test(x.url); });
    } catch (e) {
        return [];
    }
}

function wikiResults(text) {
    try {
        return JSON.parse(text).query.search.map(function (s) {
            return { title: s.title, url: "https://en.wikipedia.org/wiki/" + encodeURIComponent(s.title.replace(/ /g, "_")),
                     snippet: strip(s.snippet || "") };
        });
    } catch (e) {
        return [];
    }
}

function resultsText(query, list, from) {
    if (!list.length) return "No results for \"" + query + "\".";
    return "Results for \"" + query + "\"" + (from ? " (from " + from + ")" : "") + ":\n\n" + list.slice(0, 6).map(function (r, k) {
        return (k + 1) + ". " + r.title + "\n   " + r.url + (r.snippet ? "\n   " + r.snippet.slice(0, 300) : "");
    }).join("\n");
}

// done(error, text). fetch is get() or a stand-in (the tests').
function search(query, template, fetch, done) {
    query = String(query || "").replace(/\s+/g, " ").trim().slice(0, 300);
    if (!query) { done("the search had no query", ""); return; }
    var q = encodeURIComponent(query);
    if (template) {
        fetch(template.replace("{q}", q), { timeout: 12000 }, function (err, r) {
            if (err) { done("the search failed: " + err, ""); return; }
            var list = /json/.test(r.type) || /^\s*[{\[]/.test(r.text) ? jsonResults(r.text) : searchResults(r.text);
            done("", resultsText(query, list, hostOf(template)));
        });
        return;
    }
    var tries = [
        { url: "https://html.duckduckgo.com/html/?q=" + q, parse: searchResults, from: "" },
        { url: "https://lite.duckduckgo.com/lite/?q=" + q, parse: searchResults, from: "" },
        { url: "https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&utf8=1&srlimit=6&srsearch=" + q,
          parse: wikiResults, from: "Wikipedia only: the web search gave nothing" }
    ];
    var errors = [];
    function next(k) {
        if (k >= tries.length) {
            done(errors.length === tries.length ? "the search failed: " + errors[0] : "", errors.length === tries.length ? "" : resultsText(query, [], ""));
            return;
        }
        fetch(tries[k].url, { timeout: 10000 }, function (err, r) {
            if (err) { errors.push(err); next(k + 1); return; }
            var list = tries[k].parse(r.text);
            if (!list.length) { next(k + 1); return; }
            done("", resultsText(query, list, tries[k].from));
        });
    }
    next(0);
}

// ---- fetch_url

// done(error, page): page is fromHtml's { title, site, markdown, images, links, url }
function page(url, fetch, done) {
    url = normalUrl(url);
    if (!url) { done("that is not a web address", null); return; }
    if (pages[url]) { done("", pages[url]); return; }
    fetch(url, { timeout: 15000, max: 4e6 }, function (err, r) {
        if (err) { done(err, null); return; }
        var p;
        if (/html|xml/.test(r.type) || (!r.type && /<html|<body|<p[\s>]/i.test(r.text.slice(0, 5000)))) {
            p = Markdown.fromHtml(r.text.slice(0, 2e6), url);
        } else if (/^text\/|json|javascript/.test(r.type) || !r.type) {
            var t = r.text.slice(0, 60000);
            p = { title: hostOf(url), site: hostOf(url), markdown: /json/.test(r.type) ? "```\n" + t + "\n```" : t, images: [], links: [] };
        } else {
            done("the page is not text (" + r.type.split(";")[0] + ")", null);
            return;
        }
        if (!p.markdown.trim()) { done("the page has no readable text (it may need a browser: try a screenshot)", null); return; }
        p.url = url;
        pages[url] = p;
        done("", p);
    });
}

function pageText(p, limit) {
    var body = Markdown.plain(p.markdown);
    var cut = body.length > limit;
    return "Title: " + p.title + "\nSite: " + p.site + "\nURL: " + p.url + "\n\n" + (cut ? body.slice(0, limit) : body)
        + (cut ? "\n\n[… cut: " + (body.length - limit) + " more characters. Show it as a web item for the user to read it all.]" : "");
}

// ---- weather (open-meteo.com, no key)

var WMO = { 0: "clear sky", 1: "mainly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "freezing fog",
            51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 56: "freezing drizzle", 57: "heavy freezing drizzle",
            61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "heavy freezing rain",
            71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains", 80: "light showers", 81: "showers",
            82: "violent showers", 85: "snow showers", 86: "heavy snow showers", 95: "thunderstorm",
            96: "thunderstorm with hail", 99: "thunderstorm with heavy hail" };

function weather(place, fetch, done) {
    place = String(place || "").trim().slice(0, 120);
    if (!place) { done("no place given", ""); return; }
    var parts = place.split(",").map(function (s) { return s.trim(); });
    fetch("https://geocoding-api.open-meteo.com/v1/search?count=10&format=json&name=" + encodeURIComponent(parts[0]),
          { timeout: 10000 }, function (err, r) {
        if (err) { done("the weather service failed: " + err, ""); return; }
        var list = [];
        try { list = JSON.parse(r.text).results || []; } catch (e) {}
        var want = parts.slice(1).join(" ").toLowerCase();
        var g = list.filter(function (x) {
            return !want || [x.country, x.country_code, x.admin1, x.admin2].some(function (v) {
                return v && want.indexOf(String(v).toLowerCase()) >= 0;
            });
        })[0] || list[0];
        if (!g) { done("", "No place called \"" + place + "\" was found."); return; }
        var q = "https://api.open-meteo.com/v1/forecast?latitude=" + g.latitude + "&longitude=" + g.longitude +
            "&timezone=auto&forecast_days=5&wind_speed_unit=kmh" +
            "&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m" +
            "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max";
        fetch(q, { timeout: 10000 }, function (err2, r2) {
            if (err2) { done("the weather service failed: " + err2, ""); return; }
            try { done("", weatherText(g, JSON.parse(r2.text))); }
            catch (e) { done("the weather service sent something unreadable", ""); }
        });
    });
}

function weatherText(g, w) {
    var c = w.current, d = w.daily, u = w.current_units || {};
    var name = [g.name, g.admin1, g.country].filter(function (x, k, a) { return x && a.indexOf(x) === k; }).join(", ");
    var s = "Weather for " + name + " (open-meteo.com), local time " + String(c.time).replace("T", " ") + ":\n" +
        "Now: " + (WMO[c.weather_code] || "code " + c.weather_code) + ", " + c.temperature_2m + " °C (feels " +
        c.apparent_temperature + " °C), humidity " + c.relative_humidity_2m + " %, wind " + c.wind_speed_10m + " km/h, precipitation " +
        c.precipitation + " mm.\nForecast:";
    for (var k = 0; k < d.time.length; k++)
        s += "\n- " + d.time[k] + ": " + (WMO[d.weather_code[k]] || "code " + d.weather_code[k]) + ", " + d.temperature_2m_min[k] +
             " to " + d.temperature_2m_max[k] + " °C, rain chance " + d.precipitation_probability_max[k] + " %, " +
             d.precipitation_sum[k] + " mm, wind up to " + d.wind_speed_10m_max[k] + " km/h";
    return s;
}

// ---- screenshots: a headless browser renders the page. `part` 0 is the
// first screen, 960 by 1600 px; part n is the page moved up by n screens.
// The template (FOLIO_SCREENSHOT_URL) has {url}, and may have {part} and
// {offset} (px); the default is microlink.io (free, 50 a day, no key).
var SCREEN = 1600;

function shotUrl(url, part, template) {
    var off = part * SCREEN;
    if (template)
        return template.replace("{url}", enc(url)).replace("{part}", part).replace("{offset}", off);
    // the address goes in Markdown and in a page view: no ( )
    var css = enc("html{filter:grayscale(1)" + (off ? ";transform:translateY(-" + off + "px)" : "") + "}");
    return "https://api.microlink.io/?url=" + enc(url) +
        "&screenshot=true&meta=false&embed=screenshot.url&screenshot.type=jpeg&colorScheme=light" +
        "&viewport.width=960&viewport.height=" + SCREEN + "&viewport.deviceScaleFactor=1&styles=" + css;
}

// encodeURIComponent, and ( ) ' ! * too
function enc(s) {
    return encodeURIComponent(s).replace(/[()'!*]/g, function (c) { return "%" + c.charCodeAt(0).toString(16).toUpperCase(); });
}
