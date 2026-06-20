document.addEventListener("DOMContentLoaded", () => {
  const sections = document.querySelectorAll(".Sec-form");
  const resetBtn = document.getElementById("reset-step");
  const pwdBtn = document.getElementById("pwd-btn");
  const pwdInput = document.getElementById("pwd");
  const wifiForm = document.getElementById("wifi-form");
  const loadNetworkBtn = document.getElementById("Load_network");
  const networkSelect = document.getElementById("network-select");
  const connectBtn = document.getElementById("connect-btn");
  const startKioskBtn = document.getElementById("start-kiosk-btn");
  const statusMessage = document.getElementById("status-message");
  let step = parseInt(localStorage.getItem("Steps")) || 1;
  let wifiCheckInterval;

  const showSvg = `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-5"><path stroke-linecap="round" stroke-linejoin="round" d="M3.98 8.223A10.477 10.477 0 0 0 1.934 12C3.226 16.338 7.244 19.5 12 19.5c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.451 10.451 0 0 1 12 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 0 1-4.293 5.774M6.228 6.228 3 3m3.228 3.228 3.65 3.65m7.894 7.894L21 21m-3.228-3.228-3.65-3.65m0 0a3 3 0 1 0-4.243-4.243m4.242 4.242L9.88 9.88"/></svg>`;
  const hideSvg = `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-5"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/></svg>`;

  function updateConnectionStatus(connected) {
    if (connected) {
      connectBtn.className =
        "w-full bg-green-600 hover:bg-green-700 text-white font-medium py-3 px-4 rounded-lg flex items-center justify-center gap-2 transition-all";
      startKioskBtn.classList.remove("hidden");
      startKioskBtn.classList.add("flex");
    } else {
      connectBtn.className =
        "w-full bg-red-600 hover:bg-red-700 text-white font-medium py-3 px-4 rounded-lg flex items-center justify-center gap-2 transition-all";
      startKioskBtn.classList.add("hidden");
      startKioskBtn.classList.remove("flex");
    }
  }

  async function checkWiFiStatus() {
    try {
      const response = await fetch("/check_wifi");
      const data = await response.json();
      updateConnectionStatus(data.connected);
    } catch (error) {
      console.error("Error checking WiFi:", error);
      updateConnectionStatus(false);
    }
  }

  // Check WiFi status on load and every 3 seconds
  checkWiFiStatus();
  wifiCheckInterval = setInterval(checkWiFiStatus, 3000);

  // Handle WiFi form submission
  if (wifiForm) {
    wifiForm.addEventListener("submit", async (e) => {
      e.preventDefault();

      const formData = new FormData(wifiForm);
      const ssid = formData.get("ssid") || formData.get("network");
      const password = formData.get("password");

      if (!ssid || !password) {
        statusMessage.textContent = "Please enter both SSID and password";
        statusMessage.className = "text-sm text-center text-red-400";
        statusMessage.classList.remove("hidden");
        return;
      }

      connectBtn.disabled = true;
      connectBtn.querySelector("span").textContent = "Connecting...";
      statusMessage.textContent = "Configuring WiFi...";
      statusMessage.className = "text-sm text-center text-blue-400";
      statusMessage.classList.remove("hidden");

      try {
        const response = await fetch("/set_wifi", {
          method: "POST",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: new URLSearchParams({ ssid, password }).toString(),
        });

        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const result = await response.json();

        if (result.success) {
          statusMessage.textContent =
            "WiFi configured successfully! Checking connection...";
          statusMessage.className = "text-sm text-center text-green-400";

          // Clear existing interval and start checking more frequently
          clearInterval(wifiCheckInterval);

          let checkAttempts = 0;
          const maxAttempts = 20; // 20 attempts x 2 seconds = 40 seconds max

          const quickCheck = setInterval(async () => {
            checkAttempts++;

            try {
              const response = await fetch("/check_wifi");
              const data = await response.json();

              if (data.connected) {
                clearInterval(quickCheck);
                updateConnectionStatus(true);
                statusMessage.textContent =
                  "Connected! You can now start the kiosk.";
                statusMessage.className = "text-sm text-center text-green-400";
                // Resume normal checking interval
                wifiCheckInterval = setInterval(checkWiFiStatus, 3000);
              } else if (checkAttempts >= maxAttempts) {
                clearInterval(quickCheck);
                statusMessage.textContent =
                  "Connection timeout. Please check credentials and try again.";
                statusMessage.className = "text-sm text-center text-orange-400";
                // Resume normal checking interval
                wifiCheckInterval = setInterval(checkWiFiStatus, 3000);
              } else {
                statusMessage.textContent = `Connecting... (${checkAttempts}/${maxAttempts})`;
              }
            } catch (error) {
              console.error("Error during connection check:", error);
            }
          }, 2000); // Check every 2 seconds
        } else {
          statusMessage.textContent = `Error: ${result.error || "Failed to configure WiFi"}`;
          statusMessage.className = "text-sm text-center text-red-400";
        }
      } catch (error) {
        console.error("Fetch error:", error);
        statusMessage.textContent = `Connection error: ${error.message}. Please try again.`;
        statusMessage.className = "text-sm text-center text-red-400";
      } finally {
        connectBtn.disabled = false;
        connectBtn.querySelector("span").textContent = "Connect";
      }
    });
  }

  async function loadNetworks() {
    if (!networkSelect) return;

    const previousValue = networkSelect.value;

    if (loadNetworkBtn) {
      loadNetworkBtn.disabled = true;
    }

    try {
      const response = await fetch("/scan_wifi");
      const data = await response.json();

      if (!response.ok || !data.success) {
        throw new Error(data.error || `HTTP ${response.status}`);
      }

      networkSelect.innerHTML = "";

      const defaultOption = document.createElement("option");
      defaultOption.value = "";
      defaultOption.textContent = "Select Network";
      networkSelect.appendChild(defaultOption);

      (data.networks || []).forEach((ssid) => {
        const option = document.createElement("option");
        option.value = ssid;
        option.textContent = ssid;
        networkSelect.appendChild(option);
      });

      if (previousValue && (data.networks || []).includes(previousValue)) {
        networkSelect.value = previousValue;
      }

      statusMessage.textContent = `Found ${(data.networks || []).length} networks`;
      statusMessage.className = "text-sm text-center text-green-400";
      statusMessage.classList.remove("hidden");
    } catch (error) {
      console.error("Error scanning WiFi networks:", error);
      statusMessage.textContent = `Failed to load networks: ${error.message}`;
      statusMessage.className = "text-sm text-center text-red-400";
      statusMessage.classList.remove("hidden");
    } finally {
      if (loadNetworkBtn) {
        loadNetworkBtn.disabled = false;
      }
    }
  }

  if (loadNetworkBtn) {
    loadNetworkBtn.addEventListener("click", (e) => {
      e.preventDefault();
      loadNetworks();
    });
  }

  // Handle Start Kiosk button
  if (startKioskBtn) {
    startKioskBtn.addEventListener("click", () => {
      // Request fullscreen
      document.documentElement.requestFullscreen().catch((e) => console.log(e));
      // Redirect to kiosk
      window.location.href = "/start_kiosk";
    });
  }

  function showStep(n) {
    sections.forEach((sec, i) => {
      if (i + 1 === n) {
        sec.classList.remove("hidden");
        sec.style.pointerEvents = "auto";
        requestAnimationFrame(() => sec.classList.add("flex"));
      } else {
        sec.classList.remove("flex");
        sec.style.pointerEvents = "none";
        setTimeout(() => sec.classList.add("hidden"), 390);
      }
    });
    if (resetBtn) resetBtn.style.display = n === sections.length ? "" : "none";
    localStorage.setItem("Steps", n);
  }

  showStep(step);

  document.querySelectorAll(".next-step").forEach((btn) => {
    btn.onpointerdown = (e) => {
      e.preventDefault();
      if (step < sections.length) showStep(++step);
    };
  });

  if (resetBtn) resetBtn.onpointerdown = () => showStep((step = 1));

  if (pwdBtn && pwdInput) {
    pwdBtn.onpointerdown = () => {
      const show = pwdInput.type === "password";
      pwdInput.type = show ? "text" : "password";
      pwdBtn.innerHTML = show ? showSvg : hideSvg;
    };
  }
});
