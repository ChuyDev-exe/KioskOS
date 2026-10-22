/**
 * KioskOS setup wizard.
 *
 * Minimal client for the manager service. No framework, no CDN, no emoji:
 * every icon is an inline SVG symbol and every value is written with
 * textContent (never innerHTML).
 */
(function () {
  "use strict";

  var POLL_INTERVAL_MS = 5000;
  /* The service gives up (and rolls back) after 30 s: poll a bit longer. */
  var CONNECT_ATTEMPTS = 25;
  var CONNECT_POLL_MS = 2000;
  /* Polls after "associated" while waiting for internet access. */
  var INTERNET_GRACE_ATTEMPTS = 8;

  function el(id) {
    return document.getElementById(id);
  }

  var dom = {
    dotConnection: el("dot-connection"),
    labelConnection: el("label-connection"),
    labelKiosk: el("label-kiosk"),
    labelUptime: el("label-uptime"),
    labelVersion: el("label-version"),
    labelClock: el("label-clock"),
    cardConnection: el("card-connection"),
    cardConnectionNote: el("card-connection-note"),
    cardKiosk: el("card-kiosk"),
    cardKioskDetail: el("card-kiosk-detail"),
    cardUptime: el("card-uptime"),
    cardVersion: el("card-version"),
    btnRefresh: el("btn-refresh"),
    btnScan: el("btn-scan"),
    btnHidden: el("btn-hidden"),
    wifiList: el("wifi-list"),
    wifiStatus: el("wifi-status"),
    modalWifi: el("modal-wifi"),
    modalRestart: el("modal-restart"),
    wifiSsid: el("wifi-ssid"),
    wifiPassword: el("wifi-password"),
    wifiPasswordField: el("wifi-password-field"),
    wifiShowPassword: el("wifi-show-password"),
    wifiForm: el("wifi-form"),
    wifiError: el("wifi-error"),
    wifiModalSsid: el("wifi-modal-ssid"),
    wifiConnect: el("wifi-connect"),
    restartConfirm: el("restart-confirm"),
    dotToast: el("dot-toast"),
    footerMessage: el("footer-message"),
  };

  /* ── Helpers ───────────────────────────────────────────────────────── */

  /* Full class names kept literal so the Tailwind scanner picks them up. */
  var TONES = {
    ok: "bg-ok",
    danger: "bg-danger",
    warn: "bg-warn",
    muted: "bg-muted",
  };

  function setDot(node, tone) {
    node.className = "dot " + (TONES[tone] || TONES.muted);
  }

  function notify(message, tone) {
    dom.footerMessage.textContent = message || "";
    setDot(dom.dotToast, tone || "muted");
  }

  function formatUptime(seconds) {
    var raw = String(seconds == null ? "" : seconds).trim();
    if (raw === "") {
      return "—";
    }
    var total = Number(raw);
    if (!isFinite(total) || total < 0) {
      return "—";
    }
    var days = Math.floor(total / 86400);
    var hours = Math.floor((total % 86400) / 3600);
    var minutes = Math.floor((total % 3600) / 60);
    if (days > 0) {
      return days + " d " + hours + " h";
    }
    if (hours > 0) {
      return hours + " h " + minutes + " min";
    }
    return minutes + " min";
  }

  function fetchJson(path, options) {
    return fetch(path, options || {})
      .then(function (response) {
        return response
          .json()
          .catch(function () {
            return null;
          })
          .then(function (data) {
            return { ok: response.ok, status: response.status, data: data };
          });
      })
      .catch(function () {
        return { ok: false, status: 0, data: null };
      });
  }

  /* ── Navigation ────────────────────────────────────────────────────── */

  var VIEWS = ["estado", "red", "kiosco"];

  function currentView() {
    var hash = (window.location.hash || "").replace("#", "");
    return VIEWS.indexOf(hash) > -1 ? hash : "estado";
  }

  function setView(name, updateHash) {
    var views = document.querySelectorAll("[data-view]");
    for (var i = 0; i < views.length; i++) {
      views[i].hidden = views[i].getAttribute("data-view") !== name;
    }

    var items = document.querySelectorAll("[data-nav]");
    for (var j = 0; j < items.length; j++) {
      if (items[j].getAttribute("data-nav") === name) {
        items[j].setAttribute("aria-current", "page");
      } else {
        items[j].removeAttribute("aria-current");
      }
    }

    if (updateHash !== false && window.location.hash !== "#" + name) {
      window.location.hash = name;
    }
  }

  function bindNavigation() {
    var items = document.querySelectorAll("[data-nav]");
    for (var i = 0; i < items.length; i++) {
      items[i].addEventListener("click", function (event) {
        setView(event.currentTarget.getAttribute("data-nav"));
      });
    }

    window.addEventListener("hashchange", function () {
      setView(currentView(), false);
    });
  }

  /* ── Health ────────────────────────────────────────────────────────── */

  function renderHealth(health) {
    var linkUp = !!(health && health.wlan_connected);
    /* "internet" is the real connectivity check; older builds only had the
       interface state. */
    var connected =
      health && typeof health.internet === "boolean" ? health.internet : linkUp;
    var kioskActive = !!(health && health.kiosk_service_active);
    var uptime = formatUptime(health && health.uptime_secs);
    var version = (health && health.version) || "—";

    var label = connected
      ? "Conectado"
      : linkUp
        ? "Sin internet"
        : "Sin conexión";
    setDot(dom.dotConnection, connected ? "ok" : linkUp ? "warn" : "danger");
    dom.labelConnection.textContent = label;
    dom.cardConnection.textContent = label;
    dom.cardConnectionNote.textContent = connected
      ? "Acceso a internet verificado"
      : linkUp
        ? "La red Wi‑Fi no tiene acceso a internet"
        : "Configura una red para continuar";

    dom.labelKiosk.textContent =
      "kiosco " + (kioskActive ? "activo" : "inactivo");
    dom.cardKiosk.textContent = kioskActive ? "Activo" : "Inactivo";
    dom.cardKioskDetail.textContent = kioskActive ? "Activo" : "Inactivo";

    dom.labelUptime.textContent = "uptime " + uptime;
    dom.cardUptime.textContent = uptime;
    dom.labelVersion.textContent = "v" + version;
    dom.cardVersion.textContent = version;
  }

  function refreshHealth() {
    if (document.hidden) {
      return Promise.resolve();
    }
    return fetchJson("/health").then(function (result) {
      if (result.ok && result.data) {
        renderHealth(result.data);
      } else {
        setDot(dom.dotConnection, "danger");
        dom.labelConnection.textContent = "Servicio sin respuesta";
      }
    });
  }

  function startClock() {
    function tick() {
      var now = new Date();
      var hours = String(now.getHours()).padStart(2, "0");
      var minutes = String(now.getMinutes()).padStart(2, "0");
      dom.labelClock.textContent = hours + ":" + minutes;
    }
    tick();
    setInterval(tick, 1000);
  }

  /* ── Wi-Fi ─────────────────────────────────────────────────────────── */

  function normalizeNetwork(entry) {
    /* Older services returned plain SSID strings. */
    if (typeof entry === "string") {
      return { ssid: entry, signal_dbm: null, secure: true };
    }
    return {
      ssid: String(entry.ssid || ""),
      signal_dbm:
        typeof entry.signal_dbm === "number" ? entry.signal_dbm : null,
      secure: entry.secure !== false,
    };
  }

  function signalLabel(dbm) {
    if (dbm == null) {
      return "";
    }
    var quality = dbm >= -55 ? "Excelente" : dbm >= -70 ? "Buena" : "Débil";
    return quality + " · " + dbm + " dBm";
  }

  function svgIcon(name) {
    var icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    var use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    icon.setAttribute("class", "icon");
    icon.setAttribute("aria-hidden", "true");
    use.setAttribute("href", "#" + name);
    icon.appendChild(use);
    return icon;
  }

  function renderNetworks(networks) {
    dom.wifiList.textContent = "";

    if (!networks || networks.length === 0) {
      dom.wifiList.classList.add("hidden");
      dom.wifiStatus.textContent =
        "No se han encontrado redes. Si la red es oculta, usa «Red oculta».";
      return;
    }

    networks.map(normalizeNetwork).forEach(function (network) {
      var item = document.createElement("li");
      var button = document.createElement("button");
      var text = document.createElement("span");
      var name = document.createElement("span");
      var meta = document.createElement("span");
      var trailing = document.createElement("span");

      button.type = "button";
      button.className =
        "flex w-full items-center justify-between gap-3 py-4 text-left text-sm transition-colors hover:text-accent";
      text.className = "flex flex-col gap-1";
      name.textContent = network.ssid;
      meta.className = "text-xs text-muted";
      meta.textContent =
        (network.secure ? "Protegida" : "Abierta") +
        (network.signal_dbm != null
          ? " · " + signalLabel(network.signal_dbm)
          : "");
      trailing.className = "flex items-center gap-2 text-muted";

      text.appendChild(name);
      text.appendChild(meta);
      if (network.secure) {
        trailing.appendChild(svgIcon("i-lock"));
      }
      trailing.appendChild(svgIcon("i-chevron"));
      button.appendChild(text);
      button.appendChild(trailing);
      button.addEventListener("click", function () {
        openWifiModal(network);
      });

      item.appendChild(button);
      dom.wifiList.appendChild(item);
    });

    dom.wifiList.classList.remove("hidden");
    dom.wifiStatus.textContent =
      networks.length === 1
        ? "1 red encontrada"
        : networks.length + " redes encontradas";
  }

  function scanNetworks() {
    dom.btnScan.disabled = true;
    dom.wifiStatus.textContent = "Buscando redes…";

    return fetchJson("/scan_wifi")
      .then(function (result) {
        if (result.ok && result.data && result.data.success) {
          renderNetworks(result.data.networks || []);
        } else {
          dom.wifiStatus.textContent =
            (result.data && result.data.error) ||
            "No se pudo completar el escaneo.";
        }
      })
      .finally(function () {
        dom.btnScan.disabled = false;
      });
  }

  /* The network being configured: { ssid, secure, hidden }. */
  var pending = null;

  function showWifiError(message) {
    dom.wifiError.textContent = message;
    dom.wifiError.classList.remove("hidden");
  }

  function openWifiModal(network) {
    pending = network
      ? { ssid: network.ssid, secure: network.secure, hidden: false }
      : { ssid: "", secure: true, hidden: true };

    dom.wifiError.classList.add("hidden");
    dom.wifiError.textContent = "";
    dom.wifiPassword.value = "";
    dom.wifiPassword.type = "password";
    dom.wifiShowPassword.checked = false;
    dom.wifiSsid.value = pending.ssid;
    dom.wifiSsid.readOnly = !pending.hidden;
    /* A class, not the hidden attribute: .field sets display:flex. */
    dom.wifiPasswordField.classList.toggle("hidden", !pending.secure);
    dom.wifiModalSsid.textContent = pending.hidden
      ? "Escribe el nombre exacto de la red oculta. Deja la contraseña vacía si es abierta."
      : pending.secure
        ? "Red: " + pending.ssid
        : "Red abierta: " + pending.ssid + " (no requiere contraseña)";

    if (typeof dom.modalWifi.showModal === "function") {
      dom.modalWifi.showModal();
    }
    if (pending.hidden) {
      dom.wifiSsid.focus();
    } else if (pending.secure) {
      dom.wifiPassword.focus();
    } else {
      dom.wifiConnect.focus();
    }
  }

  function closeWifiModal() {
    if (dom.modalWifi.open) {
      dom.modalWifi.close();
    }
  }

  /* Mirrors the server-side validation so mistakes show up instantly. */
  function validateWifi(ssid, password) {
    if (!ssid) {
      return "Escribe el nombre de la red.";
    }
    if (new TextEncoder().encode(ssid).length > 32) {
      return "El nombre de la red no puede superar 32 bytes.";
    }
    if (password === "") {
      return pending && pending.secure && !pending.hidden
        ? "Esta red está protegida: escribe la contraseña."
        : null;
    }
    if (/^[0-9a-fA-F]{64}$/.test(password)) {
      return null;
    }
    if (!/^[\x20-\x7e]{8,63}$/.test(password)) {
      return "La contraseña debe tener entre 8 y 63 caracteres.";
    }
    return null;
  }

  function connectWifi(event) {
    if (event) {
      event.preventDefault();
    }
    var ssid = dom.wifiSsid.value.trim();
    var password = pending && !pending.secure ? "" : dom.wifiPassword.value;

    var problem = validateWifi(ssid, password);
    if (problem) {
      showWifiError(problem);
      return;
    }

    dom.wifiConnect.disabled = true;
    dom.wifiConnect.textContent = "Conectando…";
    dom.wifiError.classList.add("hidden");

    var body = new URLSearchParams();
    body.set("ssid", ssid);
    body.set("password", password);

    fetchJson("/set_wifi", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    })
      .then(function (result) {
        if (!result.ok) {
          throw new Error(
            (result.data && result.data.error) ||
              (result.status ? "HTTP " + result.status : "sin respuesta"),
          );
        }
        closeWifiModal();
        notify("Conectando a " + ssid + "…", "warn");
        dom.wifiStatus.textContent = "Conectando a " + ssid + "…";
        return waitForConnection(ssid);
      })
      .catch(function (error) {
        showWifiError("No se pudo iniciar la conexión: " + error.message);
      })
      .finally(function () {
        dom.wifiConnect.disabled = false;
        dom.wifiConnect.textContent = "Conectar";
      });
  }

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  function waitForConnection(ssid) {
    var attempts = 0;
    var graceLeft = INTERNET_GRACE_ATTEMPTS;

    function fail(message) {
      notify(message, "danger");
      dom.wifiStatus.textContent = message;
      return null;
    }

    function attempt() {
      attempts += 1;
      return fetchJson("/check_wifi").then(function (result) {
        var data = (result.ok && result.data) || {};

        if (data.phase === "failed") {
          return fail(data.error || "No se pudo conectar a " + ssid + ".");
        }
        if (data.phase === "connected") {
          if (data.connected) {
            notify("Conectado a " + ssid + ". Abriendo el kiosco…", "ok");
            dom.wifiStatus.textContent = "Conectado a " + ssid + ".";
            /* "/" redirects to the configured homepage once online. */
            setTimeout(function () {
              window.location.href = "/";
            }, 1500);
            return refreshHealth();
          }
          graceLeft -= 1;
          if (graceLeft <= 0) {
            refreshHealth();
            return fail(
              "Conectado a " +
                ssid +
                ", pero la red no tiene acceso a internet.",
            );
          }
        } else if (attempts >= CONNECT_ATTEMPTS) {
          return fail("No se pudo conectar. Revisa la contraseña.");
        }
        return sleep(CONNECT_POLL_MS).then(attempt);
      });
    }

    return attempt();
  }

  /* ── Kiosk ─────────────────────────────────────────────────────────── */

  function openRestartModal() {
    if (typeof dom.modalRestart.showModal === "function") {
      dom.modalRestart.showModal();
    }
  }

  function restartKiosk() {
    dom.modalRestart.close();
    notify("Reiniciando el kiosco…", "warn");
    fetchJson("/start_kiosk", { method: "POST" }).then(function (result) {
      if (result.ok) {
        /* The browser is normally killed by the restart; if it survives
           (local development), show the restart page. */
        window.location.href = "/restarting";
      } else {
        notify(
          (result.data && result.data.error) ||
            "No se pudo reiniciar el kiosco.",
          "danger",
        );
      }
    });
  }

  /* Keep the focused field visible above the on-screen keyboard. */
  function keepFieldVisible(input) {
    input.addEventListener("focus", function () {
      setTimeout(function () {
        input.scrollIntoView({ block: "center" });
      }, 300);
    });
  }

  /* ── Boot ──────────────────────────────────────────────────────────── */

  document.addEventListener("DOMContentLoaded", function () {
    bindNavigation();
    startClock();
    setView(currentView(), false);

    dom.btnRefresh.addEventListener("click", function () {
      refreshHealth();
    });
    dom.btnScan.addEventListener("click", scanNetworks);
    dom.btnHidden.addEventListener("click", function () {
      openWifiModal(null);
    });
    dom.wifiForm.addEventListener("submit", connectWifi);
    el("wifi-close").addEventListener("click", closeWifiModal);
    el("wifi-cancel").addEventListener("click", closeWifiModal);
    dom.wifiShowPassword.addEventListener("change", function () {
      dom.wifiPassword.type = dom.wifiShowPassword.checked
        ? "text"
        : "password";
    });
    keepFieldVisible(dom.wifiSsid);
    keepFieldVisible(dom.wifiPassword);
    dom.restartConfirm.addEventListener("click", restartKiosk);
    el("btn-restart").addEventListener("click", openRestartModal);
    el("btn-restart-2").addEventListener("click", openRestartModal);

    refreshHealth();
    setInterval(refreshHealth, POLL_INTERVAL_MS);
    document.addEventListener("visibilitychange", function () {
      if (!document.hidden) {
        refreshHealth();
      }
    });
  });
})();
